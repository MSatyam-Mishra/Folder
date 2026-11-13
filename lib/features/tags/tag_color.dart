import 'dart:ui' show Color;

/// A tag's colour: Finder's seven, or none. [finderIndex] is how Finder
/// numbers them in its tags attribute.
enum TagColor {
  none(0, 'No colour', null),
  grey(1, 'Grey', Color(0xFF8E8E93)),
  green(2, 'Green', Color(0xFF34C759)),
  purple(3, 'Purple', Color(0xFFAF52DE)),
  blue(4, 'Blue', Color(0xFF0A84FF)),
  yellow(5, 'Yellow', Color(0xFFFFCC00)),
  red(6, 'Red', Color(0xFFFF453A)),
  orange(7, 'Orange', Color(0xFFFF9500));

  const TagColor(this.finderIndex, this.label, this.color);

  final int finderIndex;
  final String label;

  /// Null for [none].
  final Color? color;

  /// The colours in the order Finder lists them.
  static const ordered = [red, orange, yellow, green, blue, purple, grey];

  static TagColor fromFinder(int index) =>
      values.firstWhere((c) => c.finderIndex == index, orElse: () => none);

  static TagColor byName(String? name) =>
      values.firstWhere((c) => c.name == name, orElse: () => none);
}
