import 'package:folders/core/services/image_convert/image_converter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads the encoder names from ffmpeg -encoders', () {
    const output = '''
Encoders:
 V..... = Video
 A..... = Audio
 .F.... = Frame-level multithreading
 ------
 V....D libaom-av1           libaom AV1 (codec av1)
 V..... libsvtav1            SVT-AV1(Scalable Video Technology for AV1) encoder (codec av1)
 V....D libx265              libx265 H.265 / HEVC (codec hevc)
 VF.... hevc_videotoolbox    VideoToolbox H.265 Encoder (codec hevc)
 A....D libmp3lame           libmp3lame MP3 (MPEG audio layer 3) (codec mp3)
''';
    expect(ImageConverter.parseEncoders(output),
        {'libaom-av1', 'libsvtav1', 'libx265', 'hevc_videotoolbox', 'libmp3lame'});
    expect(ImageConverter.parseEncoders(''), isEmpty);
  });

  test('reads the formats sips writes from sips --formats', () {
    const output = '''
Supported Formats:
-------------------------------------------
com.adobe.raw-image          dng   
org.webmproject.webp         webp  
public.avif                  avif  Writable
public.heic                  heic  Writable
public.heif                  heif  
public.png                   png   Writable
''';
    expect(ImageConverter.parseSipsWritable(output), {'avif', 'heic', 'png'});
  });
}
