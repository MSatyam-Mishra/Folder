import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/formats/finder_tags_plist.dart';

Uint8List _hex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

String _toHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Finder's tags attribute: a binary plist of "Name\nColour" strings. The
/// expected bytes were written by Python's plistlib (plistlib.dumps(...,
/// fmt=plistlib.FMT_BINARY)), which reads what Finder writes.
void main() {
  const plistlib = {
    'one': '62706c6973743030a101555265640a36080a0000000000000101000000000000000200000000000000000000000000000010',
    'mixed': '62706c6973743030a401020302555265640a3654576f726b6600430061006600e9000a0034080d13180000000000000101000000000000000400000000000000000000000000000025',
    'empty': '62706c6973743030a0080000000000000101000000000000000100000000000000000000000000000009',
    'long': '62706c6973743030a1015f102b412076657279206c6f6e6720746167206e616d652074686174206973206f766572206669667465656e0a32080a0000000000000101000000000000000200000000000000000000000000000038',
  };

  test('writes what plistlib writes, byte for byte', () {
    expect(_toHex(FinderTagsPlist.encode(const [FinderTag('Red', 6)])), plistlib['one']);
    // A repeated string is stored once; non-ASCII goes in UTF-16.
    expect(
      _toHex(FinderTagsPlist.encodeStrings(['Red\n6', 'Work', 'Café\n4', 'Work'])),
      plistlib['mixed'],
    );
    expect(_toHex(FinderTagsPlist.encode(const [])), plistlib['empty']);
    expect(
      _toHex(FinderTagsPlist.encode(const [FinderTag('A very long tag name that is over fifteen', 2)])),
      plistlib['long'],
      reason: 'a length of 15 or more is written as an int after the marker',
    );
  });

  test("reads plistlib's (and so Finder's) bytes", () {
    expect(FinderTagsPlist.decode(_hex(plistlib['one']!)), const [FinderTag('Red', 6)]);
    expect(FinderTagsPlist.decode(_hex(plistlib['mixed']!)), const [
      FinderTag('Red', 6),
      FinderTag('Work'),
      FinderTag('Café', 4),
      FinderTag('Work'),
    ]);
    expect(FinderTagsPlist.decode(_hex(plistlib['empty']!)), isEmpty);
    expect(FinderTagsPlist.decode(_hex(plistlib['long']!))!.single.color, 2);
  });

  test('round trip, with many tags (two-byte lengths and offsets)', () {
    final tags = [
      for (var i = 0; i < 300; i++) FinderTag('Tag $i ${'x' * (i % 40)}', i % 8),
      const FinderTag('日本語のタグ', 3),
    ];
    final bytes = FinderTagsPlist.encode(tags);
    expect(FinderTagsPlist.decode(bytes), tags);
  });

  test('broken or other data reads as nothing', () {
    expect(FinderTagsPlist.decode(const []), isNull);
    expect(FinderTagsPlist.decode(List.filled(50, 0)), isNull);
    final good = _hex(plistlib['mixed']!);
    expect(FinderTagsPlist.decode(good.sublist(0, good.length - 5)), isNull, reason: 'cut short');
    // A plist holding one string, not an array of them.
    expect(FinderTagsPlist.decodeStrings(_hex('62706c69737430305361626308000000000000010100000000000000010000000000000000000000000000000c')), isNull);
  });

  test('a tag string: name, then its colour after a line break', () {
    expect(FinderTag.decode('Red\n6'), const FinderTag('Red', 6));
    expect(FinderTag.decode('Work'), const FinderTag('Work'));
    expect(FinderTag.decode('Odd\nname'), const FinderTag('Odd name'));
    expect(const FinderTag('Work').encoded, 'Work');
    expect(const FinderTag('Blue', 4).encoded, 'Blue\n4');
  });
}
