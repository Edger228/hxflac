package hxflac.openfl;

import haxe.io.Bytes;
import hxflac.FLAC;
import hxflac.FLACConverter;
import openfl.events.SampleDataEvent;
import openfl.media.Sound;
import openfl.utils.ByteArray;

class FLACStreamedSound extends Sound {
    static inline final TARGET_FRAMES:Int = 2048;
    static inline final OUTPUT_SAMPLE_RATE:Int = 44100;
    static inline final NATIVE_READ_CHUNK:Int = 16384;

    var _sampleRate:Int = 0;
    var _channels:Int = 0;
    var _bitsPerSample:Int = 0;

    var handle:Int = -1;
    var sourceBytes:Bytes;
    var tempBuffer:Bytes;
    var closed:Bool = false;
    var streamEnded:Bool = false;

    var pendingPCM:Bytes;
    var pendingLength:Int = 0;
    var pendingReadOffset:Int = 0;

    var resamplePosition:Float = 0.0;

    public var playbackFrames(default, null):Int = 0;
    public var finished(default, null):Bool = false;
    public var looped:Bool = false;

    public var channels(get, never):Int;
    public var bitsPerSample(get, never):Int;
    public var playbackTime(get, never):Float;

    inline function get_channels():Int return _channels;
    inline function get_bitsPerSample():Int return _bitsPerSample;
    inline function get_playbackTime():Float return playbackFrames / OUTPUT_SAMPLE_RATE;

    public function new(bytes:Bytes, chunkSize:Int = NATIVE_READ_CHUNK) {
        super();

        if (bytes == null || bytes.length == 0) {
            throw "FLACStreamedSound: empty source bytes";
        }

        sourceBytes = bytes;
        tempBuffer = Bytes.alloc(chunkSize);
        pendingPCM = Bytes.alloc(chunkSize * 4);

        openStreamFromSource();
        addEventListener(SampleDataEvent.SAMPLE_DATA, onSampleData);
    }

    function openStreamFromSource():Void {
        final data = sourceBytes.getData();
        final dataPointer:cpp.ConstPointer<cpp.UInt8> = untyped __cpp__('(const unsigned char*){0}->getBase()', data);

        handle = FLAC._streamOpen(dataPointer, cast sourceBytes.length);
        if (handle < 0) {
            throw "FLACStreamedSound: failed to open stream";
        }

        var sr:cpp.UInt32 = cast 0;
        var ch:cpp.UInt32 = cast 0;
        var bps:cpp.UInt32 = cast 0;

        final ok = FLAC._streamGetInfo(
            handle,
            cpp.RawPointer.addressOf(sr),
            cpp.RawPointer.addressOf(ch),
            cpp.RawPointer.addressOf(bps)
        );

        if (!ok) {
            FLAC._streamClose(handle);
            handle = -1;
            throw "FLACStreamedSound: failed to get stream info";
        }

        _sampleRate = FLACConverter.u32ToInt(sr, "sampleRate");
        _channels = FLACConverter.u32ToInt(ch, "channels");
        _bitsPerSample = FLACConverter.u32ToInt(bps, "bitsPerSample");

        if (_sampleRate <= 0 || _channels <= 0 || _bitsPerSample <= 0) {
            FLAC._streamClose(handle);
            handle = -1;
            throw 'FLACStreamedSound: invalid stream info sr=${_sampleRate}, ch=${_channels}, bps=${_bitsPerSample}';
        }
    }

    public function resetStream():Void {
        if (handle >= 0) {
            FLAC._streamClose(handle);
            handle = -1;
        }

        pendingLength = 0;
        pendingReadOffset = 0;
        resamplePosition = 0.0;
        playbackFrames = 0;
        streamEnded = false;
        finished = false;
        closed = false;

        openStreamFromSource();
    }

    function onSampleData(event:SampleDataEvent):Void {
        if (closed || handle < 0) {
            writeSilence(event.data, TARGET_FRAMES);
            return;
        }

        var framesWritten = 0;

        while (framesWritten < TARGET_FRAMES) {
            if (needsMoreInputFrames() && !streamEnded) {
                fillPendingFromNative();
            }

            if (!hasEnoughInputForOutputFrame()) {
                if (streamEnded && pendingAvailableBytes() == 0) {
                    if (looped) {
                        resetStream();
                        continue;
                    } else {
                        finished = true;
                    }
                }

                writeSilence(event.data, TARGET_FRAMES - framesWritten);
                return;
            }

            final produced = writePendingToSampleDataUniversal(
                event.data,
                TARGET_FRAMES - framesWritten
            );

            if (produced <= 0) {
                if (streamEnded && pendingAvailableBytes() == 0) {
                    if (looped) {
                        resetStream();
                        continue;
                    } else {
                        finished = true;
                    }
                }

                writeSilence(event.data, TARGET_FRAMES - framesWritten);
                return;
            }

            playbackFrames += produced;
            framesWritten += produced;
        }
    }

    function fillPendingFromNative():Void {
        if (closed || handle < 0 || streamEnded) {
            return;
        }

        final tempData = tempBuffer.getData();
        final outPointer:cpp.RawPointer<cpp.UInt8> = untyped __cpp__('(unsigned char*){0}->getBase()', tempData);
        final bytesRead = FLAC._streamRead(handle, outPointer, cast tempBuffer.length);
        final readInt = FLACConverter.sizeTToInt(bytesRead, "bytesRead");

        if (readInt <= 0) {
            if (FLAC._streamFailed(handle)) {
                trace("FLACStreamedSound: stream failed");
                close();
            } else if (FLAC._streamFinished(handle)) {
                streamEnded = true;
            }
            return;
        }

        appendPending(tempBuffer, readInt);

        if (FLAC._streamFinished(handle)) {
            streamEnded = true;
        }
    }

    inline function bytesPerSample():Int {
        return FLACConverter.getBytesPerSample(_bitsPerSample);
    }

    inline function bytesPerFrame():Int {
        return bytesPerSample() * _channels;
    }

    function pendingAvailableBytes():Int {
        return pendingLength - pendingReadOffset;
    }

    function pendingAvailableFrames():Int {
        final bpf = bytesPerFrame();
        if (bpf <= 0) return 0;
        return Std.int(pendingAvailableBytes() / bpf);
    }

    function compactPending():Void {
        if (pendingReadOffset == 0) return;

        if (pendingReadOffset >= pendingLength) {
            pendingReadOffset = 0;
            pendingLength = 0;
            return;
        }

        final remaining = pendingLength - pendingReadOffset;
        final src = pendingPCM.getData();
        untyped __cpp__('memmove({0}->getBase(), {0}->getBase() + {1}, {2})', src, pendingReadOffset, remaining);
        pendingLength = remaining;
        pendingReadOffset = 0;
    }

    function ensurePendingCapacity(required:Int):Void {
        if (pendingPCM.length >= required) return;

        var newSize = pendingPCM.length;
        while (newSize < required) {
            newSize *= 2;
        }

        final newBytes = Bytes.alloc(newSize);

        if (pendingAvailableBytes() > 0) {
            final oldData = pendingPCM.getData();
            final newData = newBytes.getData();
            final available = pendingAvailableBytes();
            untyped __cpp__('memcpy({0}->getBase(), {1}->getBase() + {2}, {3})', newData, oldData, pendingReadOffset, available);
            pendingLength = available;
            pendingReadOffset = 0;
        } else {
            pendingLength = 0;
            pendingReadOffset = 0;
        }

        pendingPCM = newBytes;
    }

    function appendPending(srcBytes:Bytes, srcLength:Int):Void {
        compactPending();

        final required = pendingLength + srcLength;
        ensurePendingCapacity(required);

        final pendingData = pendingPCM.getData();
        final srcData = srcBytes.getData();
        untyped __cpp__('memcpy({0}->getBase() + {1}, {2}->getBase(), {3})', pendingData, pendingLength, srcData, srcLength);
        pendingLength += srcLength;
    }

    inline function needsMoreInputFrames():Bool {
        return pendingAvailableFrames() < 4;
    }

    inline function hasEnoughInputForOutputFrame():Bool {
        return pendingAvailableFrames() >= 2;
    }

    inline function clampSample(v:Float):Float {
        if (v > 1.0) return 1.0;
        if (v < -1.0) return -1.0;
        return v;
    }

    inline function readSampleAsFloat(bytes:Bytes, pos:Int, bitsPerSample:Int):Float {
        return switch (bitsPerSample) {
            case 16:
                var lo = bytes.get(pos);
                var hi = bytes.get(pos + 1);
                var v = lo | (hi << 8);
                if ((v & 0x8000) != 0) v |= 0xFFFF0000;
                v / 32768.0;

            case 24:
                var b0 = bytes.get(pos);
                var b1 = bytes.get(pos + 1);
                var b2 = bytes.get(pos + 2);
                var v = b0 | (b1 << 8) | (b2 << 16);
                if ((v & 0x800000) != 0) v |= 0xFF000000;
                v / 8388608.0;

            default:
                0.0;
        }
    }

    function mixFrameToStereo(bytes:Bytes, framePos:Int):{ l:Float, r:Float } {
        final bps = bytesPerSample();

        if (_channels <= 0) {
            return { l: 0.0, r: 0.0 };
        }

        if (_channels == 1) {
            final s = readSampleAsFloat(bytes, framePos, _bitsPerSample);
            return { l: s, r: s };
        }

        if (_channels == 2) {
            return {
                l: readSampleAsFloat(bytes, framePos, _bitsPerSample),
                r: readSampleAsFloat(bytes, framePos + bps, _bitsPerSample)
            };
        }

        var l = 0.0;
        var r = 0.0;
        var countL = 0;
        var countR = 0;

        for (ch in 0..._channels) {
            final s = readSampleAsFloat(bytes, framePos + ch * bps, _bitsPerSample);
            if ((ch & 1) == 0) {
                l += s;
                countL++;
            } else {
                r += s;
                countR++;
            }
        }

        if (countL > 0) l /= countL;
        if (countR > 0) r /= countR;

        return { l: clampSample(l), r: clampSample(r) };
    }

    function writePendingToSampleDataUniversal(target:ByteArray, maxFrames:Int):Int {
        if (maxFrames <= 0) {
            return 0;
        }

        final bpf = bytesPerFrame();
        if (bpf <= 0) {
            return 0;
        }

        var framesWritten = 0;
        final step = _sampleRate / OUTPUT_SAMPLE_RATE;

        while (framesWritten < maxFrames) {
            final availableFrames = pendingAvailableFrames();
            if (availableFrames < 2) break;

            final baseFrame = Std.int(resamplePosition);
            final frac = resamplePosition - baseFrame;

            if (baseFrame + 1 >= availableFrames) break;

            final p0 = pendingReadOffset + baseFrame * bpf;
            final p1 = pendingReadOffset + (baseFrame + 1) * bpf;

            final f0 = mixFrameToStereo(pendingPCM, p0);
            final f1 = mixFrameToStereo(pendingPCM, p1);

            final left = clampSample(f0.l + (f1.l - f0.l) * frac);
            final right = clampSample(f0.r + (f1.r - f0.r) * frac);

            target.writeFloat(left);
            target.writeFloat(right);

            framesWritten++;
            resamplePosition += step;
        }

        final consumedFrames = Std.int(resamplePosition);
        if (consumedFrames > 0) {
            pendingReadOffset += consumedFrames * bpf;
            resamplePosition -= consumedFrames;
            compactPending();
        }

        return framesWritten;
    }

    function writeSilence(target:ByteArray, frames:Int):Void {
        for (i in 0...frames) {
            target.writeFloat(0);
            target.writeFloat(0);
        }
    }

    override public function close():Void {
        if (closed) return;

        closed = true;
        removeEventListener(SampleDataEvent.SAMPLE_DATA, onSampleData);

        if (handle >= 0) {
            FLAC._streamClose(handle);
            handle = -1;
        }

        playbackFrames = 0;
        streamEnded = true;
        finished = true;
    }
}