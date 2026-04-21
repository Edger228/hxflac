package hxflac.openfl;

import haxe.io.Bytes;

import hxflac.FLAC;
import hxflac.FLACConverter;

import openfl.events.SampleDataEvent;
import openfl.media.Sound;
import openfl.utils.ByteArray;

class FLACStreamingSound extends Sound {
    var _sampleRate:Int = 0;
    var _channels:Int = 0;
    var _bitsPerSample:Int = 0;

    var handle:Int = -1;
    var sourceBytes:Bytes;
    var tempBuffer:Bytes;
    var closed:Bool = false;

    public var channels(get, never):Int;
    public var bitsPerSample(get, never):Int;

    function get_channels() return _channels;
    function get_bitsPerSample() return _bitsPerSample;

    public function new(bytes:Bytes, chunkSize:Int = 16384) {
        super();

        if (bytes == null || bytes.length == 0) {
            throw "FLACStreamingSound: empty source bytes";
        }

        sourceBytes = bytes;
        tempBuffer = Bytes.alloc(chunkSize);

        final data = bytes.getData();
        final dataPointer:cpp.ConstPointer<cpp.UInt8> = untyped __cpp__('(const unsigned char*){0}->getBase()', data);

        handle = FLAC._streamOpen(dataPointer, cast bytes.length);
        if (handle < 0) {
            throw "FLACStreamingSound: failed to open stream";
        }

        var sr:cpp.UInt32 = cast 0;
        var ch:cpp.UInt32 = cast 0;
        var bps:cpp.UInt32 = cast 0;

        if (!FLAC._streamGetInfo(
            handle,
            cpp.RawPointer.addressOf(sr),
            cpp.RawPointer.addressOf(ch),
            cpp.RawPointer.addressOf(bps)
        )) {
            FLAC._streamClose(handle);
            handle = -1;
            throw "FLACStreamingSound: failed to get stream info";
        }

        _sampleRate = FLACConverter.u32ToInt(sr, "sampleRate");
        _channels = FLACConverter.u32ToInt(ch, "channels");
        _bitsPerSample = FLACConverter.u32ToInt(bps, "bitsPerSample");

        addEventListener(SampleDataEvent.SAMPLE_DATA, onSampleData);
    }

    function onSampleData(event:SampleDataEvent):Void {
        if (closed || handle < 0) {
            writeSilence(event.data, 2048);
            return;
        }

        final tempData = tempBuffer.getData();
        final outPointer:cpp.RawPointer<cpp.UInt8> = untyped __cpp__('(unsigned char*){0}->getBase()', tempData);
        final bytesRead = FLAC._streamRead(handle, outPointer, cast tempBuffer.length);
        final readInt = FLACConverter.sizeTToInt(bytesRead, "bytesRead");

        if (readInt <= 0) {
            if (FLAC._streamFailed(handle)) {
                trace("FLACStreamingSound: stream failed");
            }

            writeSilence(event.data, 2048);
            return;
        }

        writePCMToSampleData(event.data, tempBuffer, readInt, channels, bitsPerSample);
    }

    function writePCMToSampleData(target:ByteArray, pcm:Bytes, length:Int, channels:Int, bitsPerSample:Int):Void {
        if (bitsPerSample != 16) {
            final converted = FLACConverter.convertTo16Bit(pcm.sub(0, length), bitsPerSample);
            converted.position = 0;

            while (converted.bytesAvailable >= 2) {
                final sample = converted.readShort() / 32768.0;
                target.writeFloat(sample);
                if (channels == 1) {
                    target.writeFloat(sample);
                }
            }
            return;
        }

        var i = 0;
        while (i + 1 < length) {
            final lo = pcm.get(i);
            final hi = pcm.get(i + 1);
            var sample:Int = lo | (hi << 8);
            if ((sample & 0x8000) != 0) sample |= 0xFFFF0000;

            final normalized = sample / 32768.0;
            target.writeFloat(normalized);
            i += 2;

            if (channels == 1) {
                target.writeFloat(normalized);
            }
        }
    }

    function writeSilence(target:ByteArray, samples:Int):Void {
        for (i in 0...samples) {
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

        super.close();
    }
}