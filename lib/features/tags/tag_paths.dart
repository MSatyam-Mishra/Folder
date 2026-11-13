/// The virtual folders of tags: `explorer://tag/<name>` lists everything
/// with that tag.
abstract final class TagPaths {
  static const prefix = 'explorer://tag/';

  static String of(String name) => '$prefix${Uri.encodeComponent(name)}';

  static bool isTag(String path) => path.startsWith(prefix);

  /// The tag a [of] path lists; null for other paths.
  static String? nameOf(String path) {
    if (!isTag(path)) return null;
    try {
      return Uri.decodeComponent(path.substring(prefix.length));
    } on ArgumentError {
      return path.substring(prefix.length);
    }
  }
}
