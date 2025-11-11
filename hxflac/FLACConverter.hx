package hxflac;

import haxe.io.Bytes;

#if openfl
import openfl.utils.ByteArray;
#end

class FLACConverter
{
    public static function getBytesPerSample(bitsPerSample:Int):Int
        return Std.int((bitsPerSample + 7) / 8);
    
    #if openfl
    public static function convertTo16Bit(data:Bytes, bitsPerSample:Int):ByteArray {
        var result = new ByteArray();
        var bytesPerSample = getBytesPerSample(bitsPerSample);
        var sampleCount = Std.int(data.length / bytesPerSample);
        
        for (i in 0...sampleCount) {
            var sampleValue:Int = 0;
            switch(bitsPerSample) {    
                case 24:
                    var pos = i * 3;
                    var b1 = data.get(pos);
                    var b2 = data.get(pos + 1);
                    var b3 = data.get(pos + 2);
                    sampleValue = b1 | (b2 << 8) | (b3 << 16);
                    if (sampleValue & 0x800000 != 0) sampleValue |= 0xFF000000;
                    sampleValue = sampleValue >> 8;
                    
                default:
                    sampleValue = 0;
            }
            
            result.writeShort(sampleValue);
        }
        
        return result;
    }
    #end
}