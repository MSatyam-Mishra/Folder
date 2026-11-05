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
  static const _hardwareKey = 'video_hardware';
  static const _gesturesKey = 'video_gestures';
  static const _resumeKey = 'video_resume';
  static const _subtitleSizeKey = 'video_subtitle_size';
  static const _subtitleColorKey = 'video_subtitle_color';
  static const _subtitleBoxKey = 'video_subtitle_box';
  static const _directOutputKey = 'video_direct_output';

  LeavingVideo leaving = LeavingVideo.pip;
  bool hardwareDecoding = true;
  bool gestures = true;
  bool resume = true;
  double subtitleSize = 28;
  String subtitleColor = 'White';
  bool subtitleBox = true;

  /// This phone's graphics refused libmpv's own output, so the picture goes
  /// straight from Android's decoder to the screen. Found out by trying.
  bool directOutput = false;
  Future<void>? _loading;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    leaving = LeavingVideo.values.asNameMap()[prefs.getString(_leavingKey)] ?? leaving;
    hardwareDecoding = prefs.getBool(_hardwareKey) ?? hardwareDecoding;
    gestures = prefs.getBool(_gesturesKey) ?? gestures;
    resume = prefs.getBool(_resumeKey) ?? resume;
    subtitleSize = prefs.getDouble(_subtitleSizeKey) ?? subtitleSize;
    final color = prefs.getString(_subtitleColorKey);
    if (subtitleColors.containsKey(color)) subtitleColor = color!;
    subtitleBox = prefs.getBool(_subtitleBoxKey) ?? subtitleBox;
    directOutput = prefs.getBool(_directOutputKey) ?? directOutput;
    notifyListeners();
  }

  Future<void> update({
    LeavingVideo? leaving,
    bool? hardwareDecoding,
    bool? gestures,
    bool? resume,
    double? subtitleSize,
    String? subtitleColor,
    bool? subtitleBox,
    bool? directOutput,
  }) async {
    this.leaving = leaving ?? this.leaving;
    this.hardwareDecoding = hardwareDecoding ?? this.hardwareDecoding;
    this.gestures = gestures ?? this.gestures;
    this.resume = resume ?? this.resume;
    this.subtitleSize = subtitleSize ?? this.subtitleSize;
    this.subtitleColor = subtitleColor ?? this.subtitleColor;
    this.subtitleBox = subtitleBox ?? this.subtitleBox;
    this.directOutput = directOutput ?? this.directOutput;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_leavingKey, this.leaving.name);
    await prefs.setBool(_hardwareKey, this.hardwareDecoding);
    await prefs.setBool(_gesturesKey, this.gestures);
    await prefs.setBool(_resumeKey, this.resume);
    await prefs.setDouble(_subtitleSizeKey, this.subtitleSize);
    await prefs.setString(_subtitleColorKey, this.subtitleColor);
    await prefs.setBool(_subtitleBoxKey, this.subtitleBox);
    await prefs.setBool(_directOutputKey, this.directOutput);
  }
}
