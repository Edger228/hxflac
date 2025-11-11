package hxflac;

import haxe.io.Bytes;

#if openfl
import openfl.media.Sound;
import openfl.utils.ByteArray;
import openfl.utils.Assets;
#end

#if flixel
import flixel.sound.FlxSound;
#end

class FLACHelper {
    
    public static function getVersionString():String {
        final result = FLAC._getVersionString();
        return result == null ? "Unknown" : result;
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
        
        try {
            final success = FLAC._getMetadata(
                dataPointer,
                bytes.length,
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
                return null;
            }
            
            final metadata = new FLACMetadata();
            metadata.title = safeConvertString(title);
            metadata.artist = safeConvertString(artist);
            metadata.album = safeConvertString(album);
            metadata.genre = safeConvertString(genre);
            metadata.year = safeConvertString(year);
            metadata.track = safeConvertString(track);
            metadata.comment = safeConvertString(comment);
            
            freeNativeString(title);
            freeNativeString(artist);
            freeNativeString(album);
            freeNativeString(genre);
            freeNativeString(year);
            freeNativeString(track);
            freeNativeString(comment);
            
            return metadata;
            
        } catch (e:Dynamic) {
            trace('FLACHelper: Metadata extraction failed: $e');
            return null;
        }
    }
    
    public static function getMetadataFromFile(file:String):FLACMetadata {
        try {
            final byteArray = Assets.getBytes(file);
            final bytes = Bytes.ofData(byteArray);
            return getMetadata(bytes);
        } catch (e:Dynamic) {
            trace('FLACHelper: Failed to load file for metadata: $e');
            return null;
        }
    }
    
    private static function safeConvertString(nativeString:cpp.ConstCharStar):String {
        return (nativeString == null || untyped __cpp__('!{0}', nativeString)) ? null : nativeString;
    }
    
    private static function freeNativeString(str:cpp.ConstCharStar):Void {
        if (str != null && untyped __cpp__('!!{0}', str)) {
            FLAC._freeString(str);
        }
    }

    private static function decodeFLAC(bytes:Bytes):{data:Bytes, sampleRate:Int, channels:Int, bitsPerSample:Int} {
        final data = bytes.getData();
        final dataPointer:cpp.ConstPointer<cpp.UInt8> = untyped __cpp__('{0}->getBase()', data);
        
        var resultData:cpp.RawPointer<cpp.UInt8> = null;
        var resultLength:Int = 0;
        var sampleRate:Int = 0;
        var channels:Int = 0;
        var bitsPerSample:Int = 0;
        
        try {
            FLAC._toBytes(dataPointer, bytes.length, cpp.RawPointer.addressOf(resultData), cpp.RawPointer.addressOf(resultLength), cpp.RawPointer.addressOf(sampleRate),
                cpp.RawPointer.addressOf(channels),
                cpp.RawPointer.addressOf(bitsPerSample)
            );
        } catch (e:Dynamic) {
            trace('FLACHelper: Native call failed: $e');
            return null;
        }
        
        if (resultData == null || resultLength == 0) {
            trace("FLACHelper: Decoding failed - no data returned");
            return null;
        }
        
        if (sampleRate == 0 || channels == 0) {
            trace('FLACHelper: Invalid audio parameters - sampleRate: $sampleRate, channels: $channels');
            return null;
        }
        
        final resultBytes = Bytes.alloc(resultLength);
        final resultArray = resultBytes.getData();
        
        untyped __cpp__('memcpy({0}->getBase(), {1}, {2})', resultArray, resultData, resultLength);
        untyped __cpp__('free({0})', resultData);
        
        return {
            data: resultBytes,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        };
    }

    #if openfl
    public static function toOpenFL(bytes:Bytes):Sound {
        if (bytes == null || bytes.length == 0) {
            trace("FLACHelper: Empty bytes provided");
            return null;
        }
        
        final decodeResult = decodeFLAC(bytes);
        if (decodeResult == null) return null;
        
        return createSoundFromDecodedData(decodeResult);
    }
    
    public static function toOpenFLFromFile(file:String):Sound {
        try {
            final byteArray = Assets.getBytes(file);
            final bytes = Bytes.ofData(byteArray);
            
            return toOpenFL(bytes);
        } catch (e:Dynamic) {
            trace('FLACHelper: Failed to load file: $e');
            return null;
        }
    }
    
    private static function createSoundFromDecodedData(decodeResult:{data:Bytes, sampleRate:Int, channels:Int, bitsPerSample:Int}):Sound {
        var sound = new Sound();
        var format:String;
        var pcmData:ByteArray;
        var frameCount:Int;

        switch(decodeResult.bitsPerSample) {     
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
            sound.loadPCMFromByteArray(pcmData, frameCount, format, decodeResult.channels == 2, decodeResult.sampleRate);
        } catch (e:Dynamic) {
            trace('Error creating sound: $e');
            trace('Data details: frameCount=$frameCount, format=$format, channels=${decodeResult.channels}, sampleRate=${decodeResult.sampleRate}');
            return null;
        }
        
        return sound;
    }
    #end
    
    #if flixel
    public static function toFlxSound(bytes:Bytes, looped:Bool = false, autoDestroy:Bool = false, ?onComplete:Void->Void ):FlxSound {
        final sound = toOpenFL(bytes);
        return sound != null ? new FlxSound().loadEmbedded(sound, looped, autoDestroy, onComplete) : null;
    }
    
    public static function toFlxSoundFromFile(file:String, looped:Bool = false, autoDestroy:Bool = false, ?onComplete:Void->Void):FlxSound {
        final sound = toOpenFLFromFile(file);
        return sound != null ? new FlxSound().loadEmbedded(sound, looped, autoDestroy, onComplete) : null;
    }
    #end
}