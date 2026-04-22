package hxflac.flixel;

import haxe.io.Bytes;
import hxflac.openfl.FLACStreamedSound;
import openfl.media.SoundChannel;
import openfl.media.SoundTransform;

class FlxStreamedSound {
    public var streamedSound(default, null):FLACStreamedSound;
    public var channel(default, null):SoundChannel;

    public var looped:Bool = false;
    public var volume:Float = 1.0;
    public var pan:Float = 0.0;
    public var playing(default, null):Bool = false;
    public var paused(default, null):Bool = false;
    public var time(default, null):Float = 0.0;

    var sourceBytes:Bytes;
    var pauseTimeMs:Float = 0.0;

    public function new(bytes:Bytes, looped:Bool = false) {
        sourceBytes = bytes;
        this.looped = looped;

        streamedSound = new FLACStreamedSound(bytes);
        streamedSound.looped = looped;
    }

    public function play(?forceRestart:Bool = false, ?startTime:Float = 0.0):Void {
        stopChannelOnly();

        if (forceRestart || startTime > 0) {
            recreateSound();
        }

        channel = streamedSound.play();
        applyTransform();

        playing = channel != null;
        paused = false;
        time = startTime;
    }

    public function pause():Void {
        if (!playing) return;

        time = streamedSound.playbackTime * 1000.0;
        pauseTimeMs = time;
        stopChannelOnly();

        playing = false;
        paused = true;
    }

    public function resume():Void {
        if (!paused) return;

        recreateSound();
        channel = streamedSound.play();
        applyTransform();

        playing = channel != null;
        paused = false;
        time = pauseTimeMs;
    }

    public function stop():Void {
        stopChannelOnly();

        playing = false;
        paused = false;
        pauseTimeMs = 0;
        time = 0;

        if (streamedSound != null) {
            streamedSound.resetStream();
        }
    }

    public function update(elapsed:Float):Void {
        if (channel != null) {
            applyTransform();
        }

        if (playing && streamedSound != null) {
            time = streamedSound.playbackTime * 1000.0;
        }

        if (playing && streamedSound != null && streamedSound.finished) {
            if (looped) {
                streamedSound.resetStream();
                channel = streamedSound.play();
                applyTransform();
            } else {
                playing = false;
                stopChannelOnly();
            }
        }
    }

    public function destroy():Void {
        stopChannelOnly();

        if (streamedSound != null) {
            streamedSound.close();
            streamedSound = null;
        }

        sourceBytes = null;
    }

    inline function applyTransform():Void {
        if (channel == null) return;
        channel.soundTransform = new SoundTransform(volume, pan);
    }

    function recreateSound():Void {
        stopChannelOnly();

        if (streamedSound != null) {
            streamedSound.close();
        }

        streamedSound = new FLACStreamedSound(sourceBytes);
        streamedSound.looped = looped;
    }

    function stopChannelOnly():Void {
        if (channel != null) {
            channel.stop();
            channel = null;
        }
    }
}