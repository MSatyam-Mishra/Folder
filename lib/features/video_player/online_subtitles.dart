import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:explorer/features/video_player/play_queue.dart';
import 'package:explorer/features/video_player/video_library.dart';
import 'package:explorer/features/video_player/video_player_settings.dart';
import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// What a video's file name says it is.
class GuessedTitle {
  const GuessedTitle(this.name, {this.year, this.season, this.episode});

  final String name;
  final int? year;
  final int? season;
  final int? episode;

  bool get isEpisode => season != null;
}

final _separators = RegExp(r'[._]+');
final _brackets = RegExp(r'\[[^\]]*\]|\{[^}]*\}|\([^)]*\)');
final _episodeMark = RegExp(r'\bs(\d{1,2})\s?-?\s?e(\d{1,3})\b|\b(\d{1,2})x(\d{2,3})\b', caseSensitive: false);
final _yearMark = RegExp(r'\b(19\d{2}|20\d{2})\b');
final _releaseTag = RegExp(
  r'\b(2160p|1080p|720p|576p|480p|360p|4k|uhd|hdr|10bit|web[ -]?dl|web[ -]?rip|blu[ -]?ray|brrip|bdrip|dvdrip|dvdscr|'
  r'hdtv|hdrip|hdcam|camrip|x264|x265|h264|h265|hevc|xvid|divx|avc|aac|ac3|dts|ddp?5|proper|repack|extended|'
  r'remastered|unrated|dual audio|multi audio)\b',
  caseSensitive: false,
);

/// "Backstreet_Rookie_S01_E11.1080p.mkv" is Backstreet Rookie, season 1 episode
/// 11; "Inception (2010) [BluRay].mp4" is Inception of 2010.
GuessedTitle guessVideoTitle(String file) {
  final stem = VideoHistory.isStream(file)
      ? p.basenameWithoutExtension(videoTitle(file))
      : p.basenameWithoutExtension(file);
  final spaced = stem.replaceAll(_separators, ' ');
  final year = _yearMark.allMatches(spaced).where((match) => match.start > 0).firstOrNull;
  final episode = _episodeMark.firstMatch(spaced);
  final tag = _releaseTag.firstMatch(spaced);
  var end = spaced.length;
  for (final match in [year, episode, tag]) {
    if (match != null && match.start < end) end = match.start;
  }
  final name = spaced
      .substring(0, end)
      .replaceAll(_brackets, ' ')
      .replaceAll(RegExp(r'[\[\](){}]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s-]+|[\s-]+$'), '');
  return GuessedTitle(
    name.isEmpty ? spaced.trim() : name,
    year: year == null ? null : int.parse(year.group(1)!),
    season: episode == null ? null : int.parse(episode.group(1) ?? episode.group(3)!),
    episode: episode == null ? null : int.parse(episode.group(2) ?? episode.group(4)!),
  );
}

/// A film or a series the subtitles can be for.
class SubtitleTitle {
  const SubtitleTitle({required this.id, required this.name, this.year, required this.isSeries});

  factory SubtitleTitle.fromJson(Map<String, Object?> json, {required bool isSeries}) => SubtitleTitle(
        id: json['id']! as String,
        name: json['name'] as String? ?? '',
        year: json['releaseInfo'] as String?,
        isSeries: isSeries,
      );

  /// Its IMDb id.
  final String id;
  final String name;
  final String? year;
  final bool isSeries;

  String get label => year == null || year!.isEmpty ? name : '$name ($year)';
}

class OnlineSubtitle {
  const OnlineSubtitle({
    required this.url,
    required this.language,
    required this.fileName,
    required this.release,
    this.matchesFile = false,
  });

  factory OnlineSubtitle.fromJson(Map<String, Object?> json) => OnlineSubtitle(
        url: json['url']! as String,
        language: json['lang'] as String? ?? 'und',
        fileName: json['subtitleFileName'] as String? ?? '',
        release: json['movieReleaseName'] as String? ?? '',
        matchesFile: json['m'] == 'h',
      );

  final String url;
  final String language;
  final String fileName;
  final String release;

  /// Found by the video file's own hash: its timing should be right.
  final bool matchesFile;

  String get label => fileName.isNotEmpty ? fileName : release;
}

/// Subtitles from OpenSubtitles, without an account or a key: Stremio's public
/// add-on, which takes an IMDb id, and its Cinemeta to find that id from a
/// title. Nothing is sent until the user asks for a search: the title in the
/// box and, for a local file, the file's size and hash (never its name).
abstract final class SubtitleSearch {
  static const _titles = 'https://v3-cinemeta.strem.io/catalog';
  static const _subtitles = 'https://opensubtitles-v3.strem.io/subtitles';
  static const _hashChunk = 64 * 1024;

  static final _imdbId = RegExp(r'^tt\d{5,}$');

  /// Instead of the network, in tests.
  @visibleForTesting
  static Future<List<int>> Function(Uri uri)? fetchOverride;

  static Future<List<int>> _fetch(Uri uri) async {
    final override = fetchOverride;
    if (override != null) return override(uri);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'Explorer';
    try {
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 20));
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != HttpStatus.ok) throw HttpException('Status ${response.statusCode}', uri: uri);
      return await response.fold<List<int>>(<int>[], (all, part) => all..addAll(part));
    } finally {
      client.close();
    }
  }

  static Future<Map<String, Object?>> _json(Uri uri) async =>
      jsonDecode(utf8.decode(await _fetch(uri))) as Map<String, Object?>;

  /// Titles for [query], the likeliest first. An IMDb id is taken as it is.
  static Future<List<SubtitleTitle>> titles(String query, {GuessedTitle? guess}) async {
    final text = query.trim();
    if (_imdbId.hasMatch(text)) {
      return [SubtitleTitle(id: text, name: text, isSeries: guess?.isEpisode ?? false)];
    }
    Future<List<SubtitleTitle>> search(String type) async {
      final uri = Uri.parse('$_titles/$type/top/search=${Uri.encodeComponent(text)}.json');
      final metas = (await _json(uri))['metas'] as List<Object?>? ?? const [];
      return [
        for (final meta in metas.cast<Map<String, Object?>>())
          if ((meta['id'] as String? ?? '').startsWith('tt'))
            SubtitleTitle.fromJson(meta, isSeries: type == 'series'),
      ];
    }

    final found = await Future.wait([search('movie'), search('series')]);
    return rankTitles([...found[0], ...found[1]], text, guess);
  }

  /// The name as asked for first, in the year asked for, and a series if the
  /// file is an episode.
  @visibleForTesting
  static List<SubtitleTitle> rankTitles(List<SubtitleTitle> titles, String query, GuessedTitle? guess) {
    int score(SubtitleTitle title) {
      var points = 0;
      if (title.name.toLowerCase() == query.toLowerCase()) points += 4;
      if (guess?.year != null && (title.year ?? '').startsWith('${guess!.year}')) points += 2;
      if (guess != null && title.isSeries == guess.isEpisode) points += 1;
      return points;
    }

    final indexed = titles.indexed.toList();
    indexed.sort((a, b) {
      final by = score(b.$2).compareTo(score(a.$2));
      return by != 0 ? by : a.$1.compareTo(b.$1);
    });
    return [for (final (_, title) in indexed) title];
  }

  /// Whether a title is plainly what was asked for, so there's no need to ask.
  static bool isSure(SubtitleTitle title, String query) =>
      _imdbId.hasMatch(query.trim()) || title.name.toLowerCase() == query.trim().toLowerCase();

  /// OpenSubtitles' hash of a file: its size plus the 64-bit words of its first
  /// and last 64 KB. Null for a file too small to have one.
  static Future<String?> fileHash(String path) async {
    final file = File(path);
    final size = await file.length();
    if (size < _hashChunk * 2) return null;
    final open = await file.open();
    final Uint8List head;
    final Uint8List tail;
    try {
      head = await open.read(_hashChunk);
      await open.setPosition(size - _hashChunk);
      tail = await open.read(_hashChunk);
    } finally {
      await open.close();
    }
    var hash = size;
    for (final chunk in [head, tail]) {
      final words = ByteData.sublistView(chunk);
      for (var i = 0; i + 8 <= words.lengthInBytes; i += 8) {
        hash += words.getUint64(i, Endian.little);
      }
    }
    String half(int value) => value.toRadixString(16).padLeft(8, '0');
    return '${half(hash >>> 32)}${half(hash & 0xFFFFFFFF)}';
  }

  /// Subtitles for [title], and for a series its [season] and [episode]. With
  /// [video], those closest to that file come first.
  static Future<List<OnlineSubtitle>> search(
    SubtitleTitle title, {
    int? season,
    int? episode,
    String? video,
  }) async {
    final isFile = video != null && !VideoHistory.isStream(video);
    final hash = isFile ? await fileHash(video).catchError((Object _) => null) : null;
    final size = hash == null ? null : await File(video!).length();
    final id = title.isSeries ? '${title.id}:${season ?? 1}:${episode ?? 1}' : title.id;
    final extras = hash == null ? '' : '/videoHash=$hash&videoSize=$size';
    final uri = Uri.parse('$_subtitles/${title.isSeries ? 'series' : 'movie'}/$id$extras.json');
    final rows = (await _json(uri))['subtitles'] as List<Object?>? ?? const [];
    final found = [
      for (final row in rows.cast<Map<String, Object?>>())
        if (row['url'] is String) OnlineSubtitle.fromJson(row),
    ];
    return video == null ? found : ranked(found, video);
  }

  static Set<String> _words(String text) =>
      text.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((word) => word.length > 1).toSet();

  /// Matches by the file's hash first, then those sharing most of its name's
  /// words ("BluRay", "x265", a release group): those tend to be in time.
  @visibleForTesting
  static List<OnlineSubtitle> ranked(List<OnlineSubtitle> subtitles, String video) {
    final wanted = _words(p.basenameWithoutExtension(video));
    int score(OnlineSubtitle subtitle) =>
        (subtitle.matchesFile ? 1000 : 0) + _words('${subtitle.release} ${subtitle.fileName}').intersection(wanted).length;
    final indexed = subtitles.indexed.toList();
    indexed.sort((a, b) {
      final by = score(b.$2).compareTo(score(a.$2));
      return by != 0 ? by : a.$1.compareTo(b.$1);
    });
    return [for (final (_, subtitle) in indexed) subtitle];
  }

  /// Saves [subtitle] beside [video], where the player will find it next time
  /// ("Movie.eng.srt"), never over a file that's there; for a stream, or a
  /// folder that can't be written, in a temporary one. Returns where it went.
  static Future<String> download(OnlineSubtitle subtitle, {required String video, Directory? temporary}) async {
    final bytes = await _fetch(Uri.parse(subtitle.url));
    final named = p.extension(subtitle.fileName).toLowerCase();
    final extension = subtitleExtensions.contains(named) ? named : '.srt';
    final isFile = !VideoHistory.isStream(video);
    final stem = isFile ? p.basenameWithoutExtension(video) : p.basenameWithoutExtension(videoTitle(video));

    Future<String> saveIn(Directory folder) async {
      await folder.create(recursive: true);
      var path = p.join(folder.path, '$stem.${subtitle.language}$extension');
      for (var copy = 2; File(path).existsSync(); copy++) {
        path = p.join(folder.path, '$stem.${subtitle.language}.$copy$extension');
      }
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    }

    Future<Directory> fallback() async =>
        Directory(p.join((temporary ?? await getTemporaryDirectory()).path, 'subtitles'));
    if (!isFile) return saveIn(await fallback());
    try {
      return await saveIn(Directory(p.dirname(video)));
    } on FileSystemException {
      return saveIn(await fallback());
    }
  }
}

const _languages = {
  'alb': 'Albanian', 'ara': 'Arabic', 'arm': 'Armenian', 'aze': 'Azerbaijani', 'baq': 'Basque', 'ben': 'Bengali',
  'bos': 'Bosnian', 'bul': 'Bulgarian', 'cat': 'Catalan', 'chi': 'Chinese', 'zhe': 'Chinese', 'zht': 'Chinese (Traditional)',
  'hrv': 'Croatian', 'cze': 'Czech', 'dan': 'Danish', 'nld': 'Dutch', 'dut': 'Dutch', 'eng': 'English', 'est': 'Estonian',
  'per': 'Persian', 'fin': 'Finnish', 'fre': 'French', 'glg': 'Galician', 'geo': 'Georgian', 'ger': 'German', 'ell': 'Greek',
  'gre': 'Greek', 'guj': 'Gujarati', 'heb': 'Hebrew', 'hin': 'Hindi', 'hun': 'Hungarian', 'ice': 'Icelandic', 'ind': 'Indonesian',
  'ita': 'Italian', 'jpn': 'Japanese', 'kan': 'Kannada', 'kaz': 'Kazakh', 'kor': 'Korean', 'lav': 'Latvian', 'lit': 'Lithuanian',
  'mac': 'Macedonian', 'may': 'Malay', 'mal': 'Malayalam', 'mar': 'Marathi', 'nep': 'Nepali', 'nor': 'Norwegian', 'pan': 'Punjabi',
  'pol': 'Polish', 'por': 'Portuguese', 'pob': 'Portuguese (Brazil)', 'ron': 'Romanian', 'rum': 'Romanian', 'rus': 'Russian',
  'srp': 'Serbian', 'sin': 'Sinhala', 'slo': 'Slovak', 'slv': 'Slovenian', 'spa': 'Spanish', 'swe': 'Swedish', 'tam': 'Tamil',
  'tel': 'Telugu', 'tha': 'Thai', 'tur': 'Turkish', 'ukr': 'Ukrainian', 'urd': 'Urdu', 'vie': 'Vietnamese',
};

const _fromLocale = {
  'ar': 'ara', 'bn': 'ben', 'cs': 'cze', 'da': 'dan', 'de': 'ger', 'el': 'ell', 'en': 'eng', 'es': 'spa', 'fa': 'per',
  'fi': 'fin', 'fr': 'fre', 'he': 'heb', 'hi': 'hin', 'hu': 'hun', 'id': 'ind', 'it': 'ita', 'ja': 'jpn', 'ko': 'kor',
  'ml': 'mal', 'mr': 'mar', 'nl': 'nld', 'pl': 'pol', 'pt': 'por', 'ro': 'ron', 'ru': 'rus', 'sv': 'swe', 'ta': 'tam',
  'te': 'tel', 'th': 'tha', 'tr': 'tur', 'uk': 'ukr', 'ur': 'urd', 'vi': 'vie', 'zh': 'chi',
};

String subtitleLanguageName(String code) => _languages[code] ?? code.toUpperCase();

/// Which of [available] to show first: the one picked last, the device's
/// language, English, or else the commonest.
@visibleForTesting
String? firstLanguage(Map<String, int> available, {String? saved, String? deviceLanguage}) {
  if (available.isEmpty) return null;
  for (final code in [saved, _fromLocale[deviceLanguage], 'eng']) {
    if (available.containsKey(code)) return code;
  }
  final common = available.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return common.first.key;
}

/// Searches online and pops with the path of the file it saved.
class OnlineSubtitlesSheet extends StatefulWidget {
  const OnlineSubtitlesSheet({super.key, required this.video});

  /// The file or address playing.
  final String video;

  @override
  State<OnlineSubtitlesSheet> createState() => _OnlineSubtitlesSheetState();
}

class _OnlineSubtitlesSheetState extends State<OnlineSubtitlesSheet> {
  late final GuessedTitle _guess = guessVideoTitle(widget.video);
  late final _field = TextEditingController(text: _guess.name);
  late var _season = _guess.season ?? 1;
  late var _episode = _guess.episode ?? 1;
  final _settings = VideoPlayerSettings.instance;

  var _busy = false;
  String? _message;
  List<SubtitleTitle>? _titles;
  SubtitleTitle? _title;
  List<OnlineSubtitle>? _subtitles;
  String? _language;

  /// [_language] when these subtitles came, which stays first in the row.
  String? _firstShown;
  OnlineSubtitle? _saving;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  static const _unreachable = "Couldn't reach the subtitle service. Check the connection and try again.";

  Future<T?> _attempt<T>(Future<T> Function() work) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      return await work();
    } on SocketException {
      _message = _unreachable;
    } on HandshakeException {
      _message = _unreachable;
    } on HttpException {
      _message = _unreachable;
    } on TimeoutException {
      _message = _unreachable;
    } on FormatException {
      _message = _unreachable;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return null;
  }

  Future<void> _search() async {
    final query = _field.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _title = null;
      _subtitles = null;
      _titles = null;
    });
    final titles = await _attempt(() => SubtitleSearch.titles(query, guess: _guess));
    if (!mounted || titles == null) return;
    setState(() {
      _titles = titles;
      if (titles.isEmpty) {
        _message = "No title found. Try a shorter name, or the film's IMDb id, like tt1375666.";
      }
    });
    if (titles.isNotEmpty && SubtitleSearch.isSure(titles.first, query)) await _open(titles.first);
  }

  Future<void> _open(SubtitleTitle title) async {
    setState(() {
      _title = title;
      _subtitles = null;
    });
    final found = await _attempt(
      () => SubtitleSearch.search(title, season: _season, episode: _episode, video: widget.video),
    );
    if (!mounted || found == null) return;
    await _settings.load();
    if (!mounted) return;
    setState(() {
      _subtitles = found;
      _language = firstLanguage(
        _counts(found),
        saved: _settings.subtitleLanguage,
        deviceLanguage: PlatformDispatcher.instance.locale.languageCode,
      );
      _firstShown = _language;
      if (found.isEmpty) _message = 'No subtitles for this one yet.';
    });
  }

  static Map<String, int> _counts(List<OnlineSubtitle> subtitles) {
    final counts = <String, int>{};
    for (final subtitle in subtitles) {
      counts[subtitle.language] = (counts[subtitle.language] ?? 0) + 1;
    }
    return counts;
  }

  Future<void> _pick(OnlineSubtitle subtitle) async {
    setState(() => _saving = subtitle);
    final path = await _attempt(() => SubtitleSearch.download(subtitle, video: widget.video));
    if (!mounted) return;
    setState(() => _saving = null);
    if (path == null) return;
    unawaited(_settings.update(subtitleLanguage: subtitle.language));
    Navigator.pop(context, path);
  }

  Widget _episodeSteppers(BuildContext context) {
    Widget stepper(String label, int value, ValueChanged<int> onChanged) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            IconButton(
              tooltip: 'Less',
              icon: const Icon(LucideIcons.minus, size: 16),
              onPressed: value > 1 ? () => onChanged(value - 1) : null,
            ),
            Text('$value'),
            IconButton(
              tooltip: 'More',
              icon: const Icon(LucideIcons.plus, size: 16),
              onPressed: () => onChanged(value + 1),
            ),
          ],
        );
    return Wrap(
      spacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        stepper('Season', _season, (value) {
          _season = value;
          unawaited(_open(_title!));
        }),
        stepper('Episode', _episode, (value) {
          _episode = value;
          unawaited(_open(_title!));
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final title = _title;
    final titles = _titles;
    final subtitles = _subtitles;
    final counts = subtitles == null ? const <String, int>{} : _counts(subtitles);
    // The one chosen first, so it's in view; there can be dozens.
    final languages = counts.keys.toList()
      ..sort((a, b) {
        if (a == _firstShown) return -1;
        if (b == _firstShown) return 1;
        return subtitleLanguageName(a).compareTo(subtitleLanguageName(b));
      });
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Search online', style: text.titleMedium),
        const SizedBox(height: 2),
        Text(
          "From OpenSubtitles. This sends the title, plus this file's size and a hash of it to find exact "
          'matches, but not its name.',
          style: text.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _field,
          autocorrect: false,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Title, or IMDb id',
            prefixIcon: const Icon(LucideIcons.search, size: 18),
            suffixIcon: IconButton(
              tooltip: 'Search',
              icon: const Icon(LucideIcons.arrowRight, size: 18),
              onPressed: _busy ? null : () => unawaited(_search()),
            ),
          ),
          onSubmitted: (_) => unawaited(_search()),
        ),
        const SizedBox(height: 8),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_message!, style: text.bodySmall?.copyWith(color: colors.mutedForeground)),
          ),
        if (title == null && titles != null)
          for (final option in titles.take(12))
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: Icon(option.isSeries ? LucideIcons.tv : LucideIcons.film, size: 18, color: colors.mutedForeground),
              title: Text(option.label, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(option.isSeries ? 'Series' : 'Film'),
              onTap: _busy ? null : () => unawaited(_open(option)),
            ),
        if (title != null) ...[
          Row(
            children: [
              Icon(title.isSeries ? LucideIcons.tv : LucideIcons.film, size: 18, color: colors.mutedForeground),
              const SizedBox(width: 8),
              Expanded(child: Text(title.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleSmall)),
              if ((titles?.length ?? 0) > 1)
                TextButton(
                  onPressed: () => setState(() {
                    _title = null;
                    _subtitles = null;
                    _message = null;
                  }),
                  child: const Text('Other titles'),
                ),
            ],
          ),
          if (title.isSeries) _episodeSteppers(context),
          if (languages.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final language in languages)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text('${subtitleLanguageName(language)} ${counts[language]}'),
                        selected: _language == language,
                        onSelected: (_) => setState(() => _language = language),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          for (final subtitle in (subtitles ?? const <OnlineSubtitle>[]).where((row) => row.language == _language))
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: _saving == subtitle
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(LucideIcons.download, size: 18, color: colors.mutedForeground),
              title: Text(subtitle.label, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: subtitle.matchesFile ? const Text('Made for this exact file') : null,
              onTap: _busy ? null : () => unawaited(_pick(subtitle)),
            ),
        ],
      ],
    );
  }
}
