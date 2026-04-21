package hxflac;

#if cpp
@:buildXml("<include name='${haxelib:hxflac}/build.xml' />")
@:include("hxflac.hpp")
@:keep
@:allow(hxflac.FLACHelper)
extern class FLAC {
    @:native("hxflac_get_version_string")
    static function _getVersionString():cpp.ConstCharStar;

    @:native("hxflac_to_bytes")
    static function _toBytes(
        data:cpp.ConstPointer<cpp.UInt8>,
        length:cpp.SizeT,
        resultData:cpp.RawPointer<cpp.RawPointer<cpp.UInt8>>,
        resultLength:cpp.RawPointer<cpp.SizeT>,
        sampleRate:cpp.RawPointer<cpp.UInt32>,
        channels:cpp.RawPointer<cpp.UInt32>,
        bitsPerSample:cpp.RawPointer<cpp.UInt32>
    ):Bool;

    @:native("hxflac_get_metadata")
    static function _getMetadata(
        data:cpp.ConstPointer<cpp.UInt8>,
        length:cpp.SizeT,
        title:cpp.RawPointer<cpp.ConstCharStar>,
        artist:cpp.RawPointer<cpp.ConstCharStar>,
        album:cpp.RawPointer<cpp.ConstCharStar>,
        genre:cpp.RawPointer<cpp.ConstCharStar>,
        year:cpp.RawPointer<cpp.ConstCharStar>,
        track:cpp.RawPointer<cpp.ConstCharStar>,
        comment:cpp.RawPointer<cpp.ConstCharStar>
    ):Bool;

    @:native("hxflac_free_result")
    static function _freeResult(data:cpp.RawPointer<cpp.UInt8>):Void;

    @:native("hxflac_free_string")
    static function _freeString(str:cpp.ConstCharStar):Void;

    @:native("hxflac_decode_streaming")
    static function _decodeStreaming(
        data:cpp.ConstPointer<cpp.UInt8>,
        length:cpp.SizeT,
        callback:cpp.Callable<(cpp.ConstPointer<cpp.UInt8>, cpp.SizeT, cpp.RawPointer<cpp.Void>)->Bool>,
        userData:cpp.RawPointer<cpp.Void>,
        sampleRate:cpp.RawPointer<cpp.UInt32>,
        channels:cpp.RawPointer<cpp.UInt32>,
        bitsPerSample:cpp.RawPointer<cpp.UInt32>
    ):Bool;

    @:native("hxflac_stream_open")
    static function _streamOpen(
        data:cpp.ConstPointer<cpp.UInt8>,
        length:cpp.SizeT
    ):Int;

    @:native("hxflac_stream_get_info")
    static function _streamGetInfo(
        handle:Int,
        sampleRate:cpp.RawPointer<cpp.UInt32>,
        channels:cpp.RawPointer<cpp.UInt32>,
        bitsPerSample:cpp.RawPointer<cpp.UInt32>
    ):Bool;

    @:native("hxflac_stream_read")
    static function _streamRead(
        handle:Int,
        output:cpp.RawPointer<cpp.UInt8>,
        outputCapacity:cpp.SizeT
    ):cpp.SizeT;

    @:native("hxflac_stream_finished")
    static function _streamFinished(handle:Int):Bool;

    @:native("hxflac_stream_failed")
    static function _streamFailed(handle:Int):Bool;

    @:native("hxflac_stream_close")
    static function _streamClose(handle:Int):Void;
}
#else
#error "FLAC is only supported on the cpp target."
#end