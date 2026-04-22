package;

import flixel.FlxG;
import flixel.FlxState;
import flixel.sound.FlxSound;
import flixel.text.FlxText;
import flixel.util.FlxColor;
import flixel.group.FlxGroup.FlxTypedGroup;
import flixel.input.keyboard.FlxKey;

import hxflac.FLACHelper;
import hxflac.FLACMetadata;
import hxflac.flixel.FlxStreamedSound;
import sys.io.File;

class PlayState extends FlxState 
{
    var metadataTexts:FlxTypedGroup<FlxText>;
    var metadata:FLACMetadata;
    final songPath:String = "assets/music/waera - harinezumi.flac";

    var normalSound:FlxSound;
    var streamedSound:FlxStreamedSound;
    var isStreamingMode:Bool = false;

    var modeText:FlxText;
    var controlText:FlxText;
    
    override public function create() 
    {
        var time:Float = Sys.time();

        normalSound = FLACHelper.toFlxSoundFromFile(songPath);
        FlxG.sound.list.add(normalSound);

        streamedSound = null;

        metadata = FLACHelper.getMetadataFromFile(songPath);
        trace("Loaded in " + (Sys.time() - time) + " seconds");
        
        metadataTexts = new FlxTypedGroup<FlxText>();
        add(metadataTexts);
        
        displayMetadata();
        displayVersionInfo();

        modeText = new FlxText(10, FlxG.height - 80, 300, "", 12);
        modeText.setFormat(null, 12, FlxColor.YELLOW);
        add(modeText);

        controlText = new FlxText(10, FlxG.height - 45, 400, 
            "[S]witch mode | [P]ause/Resume | [R]estart", 10);
        controlText.setFormat(null, 10, FlxColor.GRAY);
        add(controlText);

        setNormalMode();
        
        super.create();
    }

    override public function update(elapsed:Float) 
    {
        super.update(elapsed);

        #if FLX_KEYBOARD
        if (FlxG.keys.justPressed.S) 
        {
            if (isStreamingMode)
                setNormalMode();
            else
                setStreamingMode();
        }

        if (FlxG.keys.justPressed.P) 
        {
            if (isStreamingMode) 
            {
                if (streamedSound != null) 
                {
                    if (streamedSound.playing)
                        streamedSound.pause();
                    else
                        streamedSound.resume();
                }
            } 
            else 
            {
                if (normalSound != null) 
                {
                    if (normalSound.playing)
                        normalSound.pause();
                    else
                        normalSound.play();
                }
            }
        }

        if (FlxG.keys.justPressed.R) 
        {
            if (isStreamingMode) 
            {
                if (streamedSound != null)
                    streamedSound.restart();
            } 
            else 
            {
                if (normalSound != null)
                    normalSound.play(true);
            }
        }
        #end

        updateModeDisplay();
    }

    function setNormalMode():Void 
    {
        if (streamedSound != null) 
        {
            streamedSound.stop();
            streamedSound.destroy();
            streamedSound = null;
        }

        isStreamingMode = false;

        normalSound.stop();
        normalSound.play();

        updateModeDisplay();
    }

    function setStreamingMode():Void 
    {
        normalSound.stop();

        if (streamedSound == null) 
        {
            var bytes = File.getBytes(songPath);
            streamedSound = new FlxStreamedSound(bytes, false);
            streamedSound.play();
            FlxG.sound.list.add(streamedSound);
        } 
        else 
        {
            streamedSound.stop();
            streamedSound.play(true);
        }

        isStreamingMode = true;
        updateModeDisplay();
    }

    function updateModeDisplay():Void 
    {
        if (isStreamingMode) 
        {
            if (streamedSound != null) 
                modeText.text = "Mode: STREAMED | Playing: " + streamedSound.playing + 
                                " | Time: " + Math.round(streamedSound.time) + "ms";
            else
                modeText.text = "Mode: STREAMED (error)";
        } 
        else 
        {
            if (normalSound != null)
                modeText.text = "Mode: NORMAL (FlxSound) | Playing: " + normalSound.playing +
                                " | Time: " + Math.round(normalSound.time) + "ms";
            else
                modeText.text = "Mode: NORMAL (error)";
        }
    }

    override public function destroy():Void 
    {
        if (normalSound != null) 
        {
            normalSound.stop();
            normalSound.destroy();
        }
        if (streamedSound != null) 
            streamedSound.destroy();
        super.destroy();
    }

    function displayMetadata():Void {
        var startY:Float = 50;
        var lineHeight:Float = 30;
        var maxWidth:Float = 750;
        
        var titleText = new FlxText(0, startY, maxWidth, "FLAC Metadata:", 24);
		titleText.screenCenter(X);
        titleText.setFormat(null, 24, FlxColor.YELLOW, CENTER);
        metadataTexts.add(titleText);
        startY += 40;
        
        var versionText = new FlxText(25, startY, maxWidth, "FLAC Version: " + FLACHelper.getVersionString(), 16);
        versionText.setFormat(null, 16, FlxColor.CYAN);
        metadataTexts.add(versionText);
        startY += lineHeight + 10;
        
        var fields = [
            { name: "Title", value: metadata.title ?? "Unknown", color: FlxColor.WHITE },
            { name: "Artist", value: metadata.artist ?? "Unknown", color: FlxColor.LIME },
            { name: "Album", value: metadata.album ?? "Unknown", color: FlxColor.ORANGE },
            { name: "Genre", value: metadata.genre ?? "Unknown", color: FlxColor.PINK },
            { name: "Year", value: metadata.year ?? "Unknown", color: FlxColor.MAGENTA },
            { name: "Track", value: metadata.track ?? "Unknown", color: FlxColor.GRAY },
            { name: "Comment", value: metadata.comment ?? "Unknown", color: FlxColor.BROWN }
        ];
        
        for (field in fields) {
            var text = new FlxText(50, startY, maxWidth - 50, '${field.name}: ${field.value}', 14);
            text.setFormat(null, 14, field.color);
            metadataTexts.add(text);
            startY += lineHeight;
        }
        
        startY += 10;
        var separator = new FlxText(25, startY, maxWidth, "────────────────────────", 14);
        separator.setFormat(null, 14, FlxColor.GRAY);
        metadataTexts.add(separator);

        startY += lineHeight - 25;
        
        displayFileInfo(startY);
    }
    
    function displayVersionInfo():Void {
        var versionText = new FlxText(10, FlxG.height - 30, 300, "hxflac v" + lime.app.Application.current.meta.get('version'), 12);
        versionText.setFormat(null, 12, FlxColor.GRAY);
        add(versionText);
    }
    
    function displayFileInfo(startY:Float):Void {
        var lineHeight:Float = 20;
        
        try {
            var filePath = songPath;
            var fileInfo = sys.FileSystem.stat(filePath);
            var fileSizeMB = Std.string(Std.int(fileInfo.size / 1024 / 1024 * 100) / 100) + " MB";
            
            var infoFields = [
                'Size: $fileSizeMB',
                'Modified: ${fileInfo.mtime.toString()}'
            ];
            
            for (info in infoFields) {
                var text = new FlxText(50, startY, 700, info, 12);
                text.setFormat(null, 12, FlxColor.PURPLE);
                metadataTexts.add(text);
                startY += lineHeight;
            }
        } catch (e:Dynamic) {
            var errorText = new FlxText(50, startY, 700, "File info unavailable", 12);
            errorText.setFormat(null, 12, FlxColor.RED);
            metadataTexts.add(errorText);
        }
    }
}