import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What happens to a playing video when the app is left.
enum LeavingVideo {
  pip('Keep playing in a small window'),
  background('Keep playing, sound only'),
  pause('Pause');

  const LeavingVideo(this.label);

  final String label;
}

/// What decodes the video.
enum VideoDecoder {
  hw('HW', 'Hardware', 'The video chip does the work. Light on the battery, and right for most videos.'),
  hwPlus(
    'HW+',
    'Hardware, direct',
    "The video chip draws straight to the screen, the lightest of all. Formats it doesn't know won't play, "
        "and frames can't be saved.",
  ),
  sw('SW', 'Software', 'The app does the work. Plays nearly any format, for when the others look wrong. Uses more battery.');

  const VideoDecoder(this.short, this.label, this.description);

  final String short;
  final String label;
  final String description;

  /// HW+ is Android's own way of drawing.
  static List<VideoDecoder> get available => Platform.isAndroid ? values : const [hw, sw];
}

/// How the picture fills the screen.
enum VideoFit {
  fit('Fit', BoxFit.contain, null),
  fill('Fill', BoxFit.cover, null),
  stretch('Stretch', BoxFit.fill, null),
  wide('16:9', BoxFit.contain, 16 / 9),
  classic('4:3', BoxFit.contain, 4 / 3);

  const VideoFit(this.label, this.box, this.aspectRatio);

  final String label;
  final BoxFit box;
  final double? aspectRatio;

  VideoFit get next => values[(index + 1) % values.length];
}

/// The colours subtitles come in.
const subtitleColors = <String, Color>{
  'White': Colors.white,
  'Yellow': Color(0xFFFFEB3B),
  'Cyan': Color(0xFF80DEEA),
  'Green': Color(0xFFA5D6A7),
};

/// The player's settings, the same for every video.
class VideoPlayerSettings extends ChangeNotifier {
  VideoPlayerSettings._();

  static final instance = VideoPlayerSettings._();

  static const _leavingKey = 'video_leaving';
  /// Before there were three decoders, a switch for hardware or software.
  static const _hardwareKey = 'video_hardware';
  static const _decoderKey = 'video_decoder';
  static const _gesturesKey = 'video_gestures';
  static const _resumeKey = 'video_resume';
  static const _subtitleSizeKey = 'video_subtitle_size';
  static const _subtitleColorKey = 'video_subtitle_color';
  static const _subtitleBoxKey = 'video_subtitle_box';
  static const _directOutputKey = 'video_direct_output';
  static const _subtitleLanguageKey = 'video_subtitle_language';

  LeavingVideo leaving = LeavingVideo.pip;
  VideoDecoder decoder = VideoDecoder.hw;
  bool gestures = true;
  bool resume = true;
  double subtitleSize = 28;
  String subtitleColor = 'White';
  bool subtitleBox = true;

  /// This phone's graphics refused libmpv's own output, so only HW+ can show a
  /// picture. Found out by trying.
  bool gpuRefused = false;

  /// The language of the subtitles last fetched online.
  String? subtitleLanguage;
  Future<void>? _loading;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    leaving = LeavingVideo.values.asNameMap()[prefs.getString(_leavingKey)] ?? leaving;
    decoder = VideoDecoder.values.asNameMap()[prefs.getString(_decoderKey)] ??
        (prefs.getBool(_hardwareKey) == false ? VideoDecoder.sw : decoder);
    gestures = prefs.getBool(_gesturesKey) ?? gestures;
    resume = prefs.getBool(_resumeKey) ?? resume;
    subtitleSize = prefs.getDouble(_subtitleSizeKey) ?? subtitleSize;
    final color = prefs.getString(_subtitleColorKey);
    if (subtitleColors.containsKey(color)) subtitleColor = color!;
    subtitleBox = prefs.getBool(_subtitleBoxKey) ?? subtitleBox;
    gpuRefused = prefs.getBool(_directOutputKey) ?? gpuRefused;
    subtitleLanguage = prefs.getString(_subtitleLanguageKey);
    notifyListeners();
  }

  Future<void> update({
    LeavingVideo? leaving,
    VideoDecoder? decoder,
    bool? gestures,
    bool? resume,
    double? subtitleSize,
    String? subtitleColor,
    bool? subtitleBox,
    bool? gpuRefused,
    String? subtitleLanguage,
  }) async {
    this.leaving = leaving ?? this.leaving;
    this.decoder = decoder ?? this.decoder;
    this.gestures = gestures ?? this.gestures;
    this.resume = resume ?? this.resume;
    this.subtitleSize = subtitleSize ?? this.subtitleSize;
    this.subtitleColor = subtitleColor ?? this.subtitleColor;
    this.subtitleBox = subtitleBox ?? this.subtitleBox;
    this.gpuRefused = gpuRefused ?? this.gpuRefused;
    this.subtitleLanguage = subtitleLanguage ?? this.subtitleLanguage;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_leavingKey, this.leaving.name);
    await prefs.setString(_decoderKey, this.decoder.name);
    await prefs.setBool(_gesturesKey, this.gestures);
    await prefs.setBool(_resumeKey, this.resume);
    await prefs.setDouble(_subtitleSizeKey, this.subtitleSize);
    await prefs.setString(_subtitleColorKey, this.subtitleColor);
    await prefs.setBool(_subtitleBoxKey, this.subtitleBox);
    await prefs.setBool(_directOutputKey, this.gpuRefused);
    final language = this.subtitleLanguage;
    if (language != null) await prefs.setString(_subtitleLanguageKey, language);
  }
}
