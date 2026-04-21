package hxflac;

import haxe.io.Bytes;

#if openfl
import openfl.utils.ByteArray;
#end

class FLACConverter
{
    public static inline function getBytesPerSample(bitsPerSample:Int):Int
        return Std.int((bitsPerSample + 7) / 8);

    public static inline function sizeTToInt(value:cpp.SizeT, label:String):Int {
        final intValue:Int = cast value;
        if (intValue < 0) {
            throw 'FLACHelper: $label overflowed Int';
        }
        return intValue;
    }

    public static inline function u32ToInt(value:cpp.UInt32, label:String):Int {
        final intValue:Int = cast value;
        if (intValue < 0) {
            throw 'FLACHelper: $label overflowed Int';
        }
        return intValue;
    }
    
    #if openfl
    public static inline function convertTo16Bit(data:Bytes, bitsPerSample:Int):ByteArray {
        var result = new ByteArray();
        var bytesPerSample = getBytesPerSample(bitsPerSample);
        var sampleCount = Std.int(data.length / bytesPerSample);
        
        for (i in 0...sampleCount) {
            var sampleValue:Int = 0;
            switch(bitsPerSample) {    
                case 24:
                    final pos = i * 3;
                    final b1 = data.get(pos);
                    final b2 = data.get(pos + 1);
                    final b3 = data.get(pos + 2);
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