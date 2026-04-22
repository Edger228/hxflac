package hxflac;

import haxe.io.Bytes;

#if openfl
import openfl.media.Sound;
import openfl.utils.ByteArray;
import openfl.utils.Assets;

import hxflac.openfl.FLACStreamedSound;
#end

#if flixel
import flixel.sound.FlxSound;
#end

typedef FLACDecodeResult = {
    data:Bytes,
    sampleRate:Int,
    channels:Int,
    bitsPerSample:Int
};

class FLACHelper {
    public static function getVersionString():String {
        final result = FLAC._getVersionString();
        return result == null ? "Unknown" : cast result;
    }

    public static function getMetadata(bytes:Bytes):FLACMetadata {
        if (bytes == null || bytes.length == 0) {
            trace("FLACHelper: Empty bytes provided for metadata");
            return null;
        }

        final data = bytes.getData();
        final dataPointer:cpp.ConstPointer<cpp.UInt8> = untyped __cpp__('{0}->getBase()', data);

        var title:cpp.ConstCharStar = null;
        var artist:cpp.ConstCharStar = null;
        var album:cpp.ConstCharStar = null;
        var genre:cpp.ConstCharStar = null;
        var year:cpp.ConstCharStar = null;
        var track:cpp.ConstCharStar = null;
        var comment:cpp.ConstCharStar = null;

        var result:FLACMetadata = null;

        try {
            final success = FLAC._getMetadata(
                dataPointer,
                cast bytes.length,
                cpp.RawPointer.addressOf(title),
                cpp.RawPointer.addressOf(artist),
                cpp.RawPointer.addressOf(album),
                cpp.RawPointer.addressOf(genre),
                cpp.RawPointer.addressOf(year),
                cpp.RawPointer.addressOf(track),
                cpp.RawPointer.addressOf(comment)
            );

            if (!success) {
                trace("FLACHelper: Failed to extract metadata");
            } else {
                result = new FLACMetadata();
                result.title = safeConvertString(title);
                result.artist = safeConvertString(artist);
                result.album = safeConvertString(album);
                result.genre = safeConvertString(genre);
                result.year = safeConvertString(year);
                result.track = safeConvertString(track);
                result.comment = safeConvertString(comment);
            }
        } catch (e:Dynamic) {
            trace('FLACHelper: Metadata extraction failed: $e');
        }

        freeNativeString(title);
        freeNativeString(artist);
        freeNativeString(album);
        freeNativeString(genre);
        freeNativeString(year);
        freeNativeString(track);
        freeNativeString(comment);

        return result;
    }

    public static function getMetadataFromFile(file:String):FLACMetadata {
        try {
            final bytes =
                #if openfl
                Bytes.ofData(Assets.getBytes(file));
                #elseif sys
                sys.io.File.getBytes(file);
                #else
                null;
                #end

            return getMetadata(bytes);
        } catch (e:Dynamic) {
            trace('FLACHelper: Failed to load file for metadata: $e');
            return null;
        }
    }

    private static function safeConvertString(nativeString:cpp.ConstCharStar):String {
        return (nativeString == null || untyped __cpp__('!{0}', nativeString)) ? null : cast nativeString;
    }

    private static function freeNativeString(str:cpp.ConstCharStar):Void {
        if (str != null && untyped __cpp__('!!{0}', str)) {
            FLAC._freeString(str);
        }
    }

    private static function freeNativeResult(data:cpp.RawPointer<cpp.UInt8>):Void {
        if (data != null && untyped __cpp__('!!{0}', data)) {
            FLAC._freeResult(data);
        }
    }

    private static function decodeFLAC(bytes:Bytes):FLACDecodeResult {
        if (bytes == null || bytes.length == 0) {
            trace("FLACHelper: Empty bytes provided for decode");
            return null;
        }

        final data = bytes.getData();
        final dataPointer:cpp.ConstPointer<cpp.UInt8> = untyped __cpp__('{0}->getBase()', data);

        var resultData:cpp.RawPointer<cpp.UInt8> = null;
        var resultLength:cpp.SizeT = cast 0;
        var sampleRate:cpp.UInt32 = cast 0;
        var channels:cpp.UInt32 = cast 0;
        var bitsPerSample:cpp.UInt32 = cast 0;

        var result:FLACDecodeResult = null;

        try {
            final success = FLAC._toBytes(
                dataPointer,
                cast bytes.length,
                cpp.RawPointer.addressOf(resultData),
                cpp.RawPointer.addressOf(resultLength),
                cpp.RawPointer.addressOf(sampleRate),
                cpp.RawPointer.addressOf(channels),
                cpp.RawPointer.addressOf(bitsPerSample)
            );

            if (!success) {
                trace("FLACHelper: Native decode returned false");
            } else if (resultData == null) {
                trace("FLACHelper: Decoding failed - no data returned");
            } else {
                final lengthInt = FLACConverter.sizeTToInt(resultLength, "resultLength");
                final sampleRateInt = FLACConverter.u32ToInt(sampleRate, "sampleRate");
                final channelsInt = FLACConverter.u32ToInt(channels, "channels");
                final bitsPerSampleInt = FLACConverter.u32ToInt(bitsPerSample, "bitsPerSample");

                if (lengthInt <= 0) {
                    trace("FLACHelper: Decoding failed - zero output length");
                } else if (sampleRateInt <= 0 || channelsInt <= 0 || bitsPerSampleInt <= 0) {
                    trace('FLACHelper: Invalid audio parameters - sampleRate: $sampleRateInt, channels: $channelsInt, bitsPerSample: $bitsPerSampleInt');
                } else {
                    final resultBytes = Bytes.alloc(lengthInt);
                    final resultArray = resultBytes.getData();

                    untyped __cpp__('memcpy({0}->getBase(), {1}, {2})', resultArray, resultData, lengthInt);

                    result = {
                        data: resultBytes,
                        sampleRate: sampleRateInt,
                        channels: channelsInt,
                        bitsPerSample: bitsPerSampleInt
                    };
                }
            }
        } catch (e:Dynamic) {
            trace('FLACHelper: Failed to decode FLAC: $e');
        }

        freeNativeResult(resultData);
        return result;
    }

    #if openfl
    public static function toOpenFL(bytes:Bytes, streamed:Bool = false):Sound {
        if (streamed) {
            return toOpenFLStreamed(bytes);
        }

        if (bytes == null || bytes.length == 0) {
            trace("FLACHelper: Empty bytes provided");
            return null;
        }

        final decodeResult = decodeFLAC(bytes);
        if (decodeResult == null) return null;

        return createSoundFromDecodedData(decodeResult);
    }

    public static function toOpenFLStreamed(bytes:Bytes):Sound {
        if (bytes == null || bytes.length == 0) {
            trace("FLACHelper: Empty bytes provided");
            return null;
        }

        try {
            return new FLACStreamedSound(bytes);
        } catch (e:Dynamic) {
            trace('FLACHelper: Failed to create streamed sound: $e');
            return null;
        }
    }

    public static function toOpenFLFromFile(file:String, streamed:Bool = false):Sound {
        try {
            final byteArray = Assets.getBytes(file);
            final bytes = Bytes.ofData(byteArray);
            return toOpenFL(bytes, streamed);
        } catch (e:Dynamic) {
            trace('FLACHelper: Failed to load file: $e');
            return null;
        }
    }

    private static function createSoundFromDecodedData(decodeResult:FLACDecodeResult):Sound {
        var sound = new Sound();
        var format:String;
        var pcmData:ByteArray;
        var frameCount:Int;

        switch (decodeResult.bitsPerSample) {
            case 16:
                format = "short";
                pcmData = ByteArray.fromBytes(decodeResult.data);
                frameCount = Math.floor(decodeResult.data.length / (decodeResult.channels * 2));

            default:
                format = "short";
                pcmData = FLACConverter.convertTo16Bit(decodeResult.data, decodeResult.bitsPerSample);
                frameCount = Math.floor(pcmData.length / (decodeResult.channels * 2));
        }

        try {
            pcmData.position = 0;
            sound.loadPCMFromByteArray(
                pcmData,
                frameCount,
                format,
                decodeResult.channels == 2,
                decodeResult.sampleRate
            );
        } catch (e:Dynamic) {
            trace('FLACHelper: Error creating sound: $e');
            trace('FLACHelper: Data details: frameCount=$frameCount, format=$format, channels=${decodeResult.channels}, sampleRate=${decodeResult.sampleRate}');
            return null;
        }

        return sound;
    }
    #end

    #if flixel
    public static function toFlxSound(bytes:Bytes, looped:Bool = false, autoDestroy:Bool = false, ?onComplete:Void->Void, streamed:Bool = false):FlxSound {
        final sound = streamed ? toOpenFLStreamed(bytes) : toOpenFL(bytes, false);
        return sound != null ? new FlxSound().loadEmbedded(sound, looped, autoDestroy, onComplete) : null;
    }

    public static function toFlxSoundFromFile(file:String, looped:Bool = false, autoDestroy:Bool = false, ?onComplete:Void->Void, streamed:Bool = false):FlxSound {
        final sound = toOpenFLFromFile(file, streamed);
        return sound != null ? new FlxSound().loadEmbedded(sound, looped, autoDestroy, onComplete) : null;
    }
    #end
}