import 'dart:async';
import 'dart:io';

import 'package:explorer/core/files/file_types.dart';
import 'package:explorer/core/platform/desktop.dart';
import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/platform/system_bars.dart';
import 'package:explorer/core/services/file_action_service.dart';
import 'package:explorer/core/services/media_controls.dart';
import 'package:explorer/features/explorer_tabs/explorer_tabs.dart';
import 'package:explorer/features/video_player/online_subtitles.dart';
import 'package:explorer/features/video_player/play_queue.dart';
import 'package:explorer/features/video_player/video_library.dart';
import 'package:explorer/features/video_player/video_player_settings.dart';
import 'package:explorer/shared/ui/app_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:window_manager/window_manager.dart';

/// The video player, for files and network streams: libmpv through media_kit
/// on every system, with what it can read of subtitles and audio tracks (see
/// the sheets below), gestures on phones and keys on computers. It goes on
/// outside the app through [MediaControls]: controls in the notification,
/// picture in picture, and sound only.
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key, required this.playlist, this.index = 0, this.withFolder = false});

  /// Files or addresses.
  final List<String> playlist;
  final int index;

  /// Next and Previous go through the videos in the same folder.
  final bool withFolder;

  /// Plays [playlist] from [index], over the current page.
  static Future<void> open(BuildContext context, List<String> playlist, {int index = 0}) =>
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoPlayerPage(playlist: playlist, index: index),
      ));

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

/// Holds the player, which it starts anew if its output has to change: a
/// controller keeps the one it was made with.
class _VideoPlayerPageState extends State<VideoPlayerPage> {
  var _attempt = 0;
  late var _playlist = widget.playlist;
  late var _index = widget.index;
  Duration? _startAt;

  @override
  Widget build(BuildContext context) => _Player(
        key: ValueKey(_attempt),
        playlist: _playlist,
        index: _index,
        withFolder: widget.withFolder && _attempt == 0,
        startAt: _startAt,
        onRestart: (playlist, index, position) => setState(() {
          _attempt++;
          _playlist = playlist;
          _index = index;
          _startAt = position;
        }),
      );
}

class _Player extends StatefulWidget {
  const _Player({
    super.key,
    required this.playlist,
    required this.index,
    required this.withFolder,
    required this.startAt,
    required this.onRestart,
  });

  final List<String> playlist;
  final int index;
  final bool withFolder;

  /// Where to begin, after a restart.
  final Duration? startAt;
  final void Function(List<String> playlist, int index, Duration position) onRestart;

  @override
  State<_Player> createState() => _PlayerState();
}

/// What a finger drag on the picture has turned out to be.
enum _Drag { seek, level, zoom }

class _PlayerState extends State<_Player> with WidgetsBindingObserver {
  static const _seekStep = Duration(seconds: 10);
  static const _hideAfter = Duration(seconds: 3);
  static const _maxVolume = 200.0;
  static const _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0, 4.0];
  static const _sleepMinutes = [15, 30, 45, 60, 90];

  static bool get _phone => !Desktop.isDesktop;

  final _settings = VideoPlayerSettings.instance;
  final _history = VideoHistory.instance;
  final _player = Player(
    configuration: const PlayerConfiguration(
      title: 'Explorer',
      bufferSize: 64 * 1024 * 1024,
      logLevel: MPVLogLevel.warn,
    ),
  );
  final _subtitleKey = GlobalKey<SubtitleViewState>();
  final _view = ValueNotifier(const VideoView());
  VideoController? _controller;
  final _subs = <StreamSubscription<Object?>>[];
  late final PlayQueue _queue = PlayQueue(widget.playlist, index: widget.index);

  /// Where the first video begins, after a restart.
  late Duration? _restartAt = widget.startAt;

  final _position = ValueNotifier(Duration.zero);
  var _duration = Duration.zero;
  var _playing = false;
  var _buffering = true;
  String? _error;
  var _tracks = const Tracks();
  var _track = const Track();
  var _speed = 1.0;
  var _volume = 100.0;
  double? _brightness;
  (int, int)? _videoSize;

  /// Subtitle files added to the video playing, by hand or found beside it.
  final _subtitleFiles = <String>[];
  var _subtitleDelay = 0.0;
  var _audioDelay = 0.0;

  /// The video whose duration has come in.
  String? _loaded;

  var _controlsShown = true;
  var _locked = false;
  var _fit = VideoFit.fit;
  var _inPip = false;
  var _pipSupported = false;
  var _fullscreen = false;
  Rect? _boundsBeforePip;
  Timer? _hide;
  String? _flash;
  Timer? _flashEnd;
  Duration? _dragTo;
  double? _dragFrom;
  _Drag? _drag;
  var _dragTotal = Offset.zero;
  var _zoomFrom = 1.0;

  /// A finger is still down after a pinch: it shouldn't turn into a seek.
  var _pinched = false;

  /// An error waits to see if the video starts anyway.
  Timer? _errorWait;

  /// Set once the position has moved: for what has no duration, like a live stream.
  Duration? _firstPosition;
  var _moving = false;
  Offset? _doubleTapAt;
  Timer? _save;
  Timer? _sleep;
  DateTime? _sleepAt;
  final _focus = FocusNode();

  bool get _isStream => VideoHistory.isStream(_queue.current);

  NativePlayer? get _native {
    final platform = _player.platform;
    return platform is NativePlayer ? platform : null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Coming from a stream's address, the keyboard would stay over the picture.
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    _subs.addAll([
      _player.stream.position.listen(_onPosition),
      _player.stream.duration.listen(_onDuration),
      _player.stream.playing.listen(_onPlaying),
      _player.stream.buffering.listen((buffering) => _set(() => _buffering = buffering)),
      _player.stream.completed.listen((done) {
        if (done) unawaited(_onFinished());
      }),
      _player.stream.tracks.listen((tracks) => _set(() => _tracks = tracks)),
      _player.stream.track.listen((track) => _set(() => _track = track)),
      _player.stream.error.listen(_onError),
      _player.stream.log.listen(_onLog),
      _player.stream.videoParams.listen(_onVideoParams),
      MediaControls.instance.commands.listen(_onCommand),
      MediaControls.instance.pipChanges.listen(_onPipChanged),
    ]);
    unawaited(_start());
  }

  void _set(VoidCallback change) {
    if (mounted) setState(change);
  }

  Future<void> _start() async {
    await Future.wait([_settings.load(), _history.load()]);
    _pipSupported = await MediaControls.instance.pipSupported;
    if (!mounted) return;
    // Here, as a player restarting gets the last one's goodbye before this.
    if (_phone) unawaited(SystemBars.hide());
    _controller = VideoController(
      _player,
      configuration: _direct
          ? const VideoControllerConfiguration(vo: 'mediacodec_embed', hwdec: 'mediacodec')
          : VideoControllerConfiguration(enableHardwareAcceleration: _settings.decoder != VideoDecoder.sw),
    );
    unawaited(_native?.setProperty('volume-max', '${_maxVolume.toInt()}'));
    // This page finds them, once a video has opened: on its own, mpv would
    // load them twice, and its errors would come before the video has started.
    await _native?.setProperty('sub-auto', 'no');
    if (!mounted) return;
    setState(() {});
    await _openCurrent();
    _save = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());
    _showControls();
    if (widget.withFolder && !_isStream) unawaited(_joinFolder());
  }

  /// The folder's videos, by name: Next and Previous, as in a file manager.
  Future<void> _joinFolder() async {
    final videos = [
      for (final file in await filesIn(p.dirname(_queue.current)))
        if (FileTypes.kindOf(file) == FileKind.video) file,
    ]..sort((a, b) => p.basename(a).toLowerCase().compareTo(p.basename(b).toLowerCase()));
    if (!mounted || videos.length < 2) return;
    setState(() => _queue.replaceAll(videos));
    _updateOutside();
  }

  Future<void> _openCurrent() async {
    final path = _queue.current;
    final progress = _settings.resume ? _history.progressOf(path) : null;
    final restartAt = _restartAt;
    _restartAt = null;
    final resumeAt = restartAt ??
        (progress != null && !progress.finished && progress.position > const Duration(seconds: 5)
            ? progress.position
            : null);
    _errorWait?.cancel();
    _firstPosition = null;
    _moving = false;
    setState(() {
      _error = null;
      _loaded = null;
      _duration = Duration.zero;
      _buffering = true;
      _subtitleFiles.clear();
    });
    _position.value = resumeAt ?? Duration.zero;
    await _player.open(Media(path, start: resumeAt));
    if (_speed != 1) await _player.setRate(_speed);
    if (resumeAt != null) _say('Resumed at ${formatVideoTime(resumeAt)}');
    _updateOutside();
  }

  void _onPosition(Duration position) {
    _position.value = position;
    final first = _firstPosition;
    if (first == null) {
      _firstPosition = position;
    } else if (position != first && !_moving) {
      _moving = true;
      _playingAfterAll();
    }
  }

  /// Whatever mpv complained of, the video is going: no message stays over it.
  void _playingAfterAll() {
    _errorWait?.cancel();
    if (_error != null) _set(() => _error = null);
  }

  void _onDuration(Duration duration) {
    _set(() => _duration = duration);
    if (duration > Duration.zero) _playingAfterAll();
    final path = _queue.current;
    if (duration > Duration.zero && _loaded != path) {
      _loaded = path;
      unawaited(_onLoaded(path));
    }
    _updateOutside();
  }

  /// Once a video has opened: subtitles beside it, and its picture for the notification.
  Future<void> _onLoaded(String path) async {
    if (!_isStream) {
      final beside = subtitlesBeside(path, await filesIn(p.dirname(path)));
      if (beside.isNotEmpty && mounted && _queue.current == path) {
        _subtitleFiles.addAll(beside);
        await _player.setSubtitleTrack(SubtitleTrack.uri(beside.first, title: p.basename(beside.first)));
        _set(() {});
      }
    }
    if (!Platform.isAndroid) return;
    await Future<void>.delayed(const Duration(seconds: 2));
    // With Android's decoder drawing, libmpv has no frame to give.
    if (!mounted || _queue.current != path || _direct) return;
    unawaited(MediaControls.instance.artwork(await _player.screenshot(format: 'image/jpeg')));
  }

  void _onPlaying(bool playing) {
    _set(() => _playing = playing);
    if (playing) {
      _hideLater();
    } else {
      _saveProgress();
      _showControls(stay: true);
    }
    _updateAutoPip();
    _updateOutside();
  }

  void _onError(String message) {
    if (!mounted) return;
    final path = _queue.current;
    if (isSubtitleError(message, path)) {
      _say("That subtitle file can't be read");
      return;
    }
    // After playback started a bad frame doesn't stop it.
    if (_duration > Duration.zero || _moving) return;
    // mpv also reports what it gets past, like a sound device that won't open:
    // only a video that really doesn't start has failed.
    _errorWait?.cancel();
    _errorWait = Timer(const Duration(seconds: 3), () {
      if (!mounted || _queue.current != path || _duration > Duration.zero || _moving) return;
      setState(() {
        _error = message;
        _buffering = false;
      });
    });
  }

  void _onLog(PlayerLog log) {
    if (kDebugMode) debugPrint('[mpv] ${log.level} ${log.prefix}: ${log.text}');
    // No picture, on graphics that refuse libmpv's context (some phones and
    // emulators): once and for all, Android's decoder draws it instead.
    final refused = log.level == 'fatal' && log.prefix.startsWith('vo/gpu');
    if (!refused || !Platform.isAndroid || _direct || !mounted) return;
    unawaited(_settings.update(gpuRefused: true));
    _restart();
  }

  /// Anew, at the same place: a controller keeps the output it was made with.
  void _restart() {
    _saveProgress();
    widget.onRestart(_queue.items, _queue.index, _position.value);
  }

  /// Android's decoder draws: HW+, or all this phone's graphics can do.
  bool get _direct =>
      Platform.isAndroid && (_settings.gpuRefused || _settings.decoder == VideoDecoder.hwPlus);

  String get _decoderLabel => _direct ? VideoDecoder.hwPlus.short : _settings.decoder.short;

  Future<void> _setDecoder(VideoDecoder decoder) async {
    final wasDirect = _direct;
    await _settings.update(decoder: decoder);
    if (!mounted) return;
    if (_direct != wasDirect) return _restart();
    _say('${decoder.short} decoder');
    setState(() {});
    if (!_direct) {
      unawaited(_native?.setProperty('hwdec', decoder == VideoDecoder.sw ? 'no' : 'auto-safe'));
    }
  }

  void _onVideoParams(VideoParams params) {
    final width = params.dw ?? params.w;
    final height = params.dh ?? params.h;
    if (width == null || height == null || width <= 0 || height <= 0) return;
    if (_videoSize == (width, height)) return;
    _videoSize = (width, height);
    _updateAutoPip();
    if (_phone) _fitOrientation(landscape: width > height);
  }

  void _fitOrientation({required bool landscape}) {
    SystemChrome.setPreferredOrientations(landscape
        ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : const [DeviceOrientation.portraitUp]);
  }

  void _rotate() {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    _fitOrientation(landscape: !landscape);
  }

  Future<void> _onFinished() async {
    final path = _queue.current;
    await _history.record(path, _duration, _duration);
    if (!mounted) return;
    final next = _queue.afterFinished();
    if (next == null) {
      _showControls(stay: true);
    } else if (next == path) {
      await _player.seek(Duration.zero);
      await _player.play();
    } else {
      await _openCurrent();
    }
  }

  void _saveProgress() {
    if (_duration <= Duration.zero && !_isStream) return;
    unawaited(_history.record(_queue.current, _position.value, _duration));
  }

  Future<void> _next() async {
    _saveProgress();
    if (_queue.moveNext()) await _openCurrent();
  }

  Future<void> _previous() async {
    _saveProgress();
    // Into a video, as in any player: back to its start first.
    if (_position.value > const Duration(seconds: 5) || !_queue.hasPrevious) {
      await _player.seek(Duration.zero);
      return;
    }
    if (_queue.movePrevious()) await _openCurrent();
  }

  void _onCommand((MediaCommand, Duration?) event) {
    final (command, position) = event;
    switch (command) {
      case MediaCommand.play:
        unawaited(_player.play());
      case MediaCommand.pause:
        unawaited(_player.pause());
      case MediaCommand.next:
        unawaited(_next());
      case MediaCommand.previous:
        unawaited(_previous());
      case MediaCommand.seek:
        if (position != null) unawaited(_seek(position));
      case MediaCommand.stop:
        if (mounted) Navigator.of(context).maybePop();
    }
  }

  Future<void> _seek(Duration to) async {
    await _player.seek(to);
    _updateOutside();
  }

  void _skip(Duration by) {
    final to = _position.value + by;
    final end = _duration;
    final clamped = to < Duration.zero ? Duration.zero : (end > Duration.zero && to > end ? end : to);
    _say('${by.isNegative ? '−' : '+'}${by.inSeconds.abs()} s');
    unawaited(_seek(clamped));
  }

  /// What's outside the app: the notification, the lock screen.
  void _updateOutside() {
    if (!mounted || !Platform.isAndroid) return;
    unawaited(MediaControls.instance.nowPlaying(
      title: videoTitle(_queue.current),
      detail: _isStream ? 'Network stream' : p.basename(p.dirname(_queue.current)),
      playing: _playing,
      position: _position.value,
      duration: _duration,
      hasPrevious: _queue.hasPrevious,
      hasNext: _queue.hasNext,
      speed: _speed,
    ));
  }

  void _updateAutoPip() {
    if (!Platform.isAndroid) return;
    final (width, height) = _videoSize ?? (16, 9);
    unawaited(MediaControls.instance.setAutoPip(
      on: _pipSupported && _playing && _settings.leaving == LeavingVideo.pip,
      width: width,
      height: height,
    ));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused || _inPip) return;
    _saveProgress();
    if (_settings.leaving != LeavingVideo.background) unawaited(_player.pause());
  }

  void _onPipChanged(bool inPip) {
    _set(() => _inPip = inPip);
    if (inPip) return;
    _showControls();
    // Its window's X: the app stays hidden, and so should the sound stop.
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      final state = WidgetsBinding.instance.lifecycleState;
      if (mounted && !_inPip && state != AppLifecycleState.resumed && _settings.leaving == LeavingVideo.pip) {
        unawaited(_player.pause());
      }
    });
  }

  Future<void> _enterPip() async {
    if (Desktop.isDesktop) return _desktopPip();
    final (width, height) = _videoSize ?? (16, 9);
    final entered = await MediaControls.instance.enterPip(width: width, height: height);
    if (!entered) _say("Picture in picture is off for this app in the system's settings");
  }

  /// A computer has no such thing: a small window on top of the others.
  Future<void> _desktopPip() async {
    if (_inPip) {
      await windowManager.setAlwaysOnTop(false);
      final bounds = _boundsBeforePip;
      if (bounds != null) await windowManager.setBounds(bounds);
      ExplorerTabs.instance.setChromeHidden(_fullscreen);
      _set(() => _inPip = false);
      return;
    }
    _boundsBeforePip = await windowManager.getBounds();
    final (width, height) = _videoSize ?? (16, 9);
    const small = 420.0;
    ExplorerTabs.instance.setChromeHidden(true);
    await windowManager.setBounds(null, size: Size(small, small * height / width));
    await windowManager.setAlwaysOnTop(true);
    _set(() => _inPip = true);
  }

  Future<void> _toggleFullscreen() async {
    final on = !_fullscreen;
    await windowManager.setFullScreen(on);
    ExplorerTabs.instance.setChromeHidden(on);
    _set(() => _fullscreen = on);
  }

  void _say(String message) {
    _flashEnd?.cancel();
    _set(() => _flash = message);
    _flashEnd = Timer(const Duration(milliseconds: 1400), () => _set(() => _flash = null));
  }

  void _setControlsShown(bool shown) {
    _set(() => _controlsShown = shown);
    // Subtitles stand clear of the controls.
    _subtitleKey.currentState?.setPadding(
      EdgeInsets.fromLTRB(16, 0, 16, shown && !_inPip ? 132 : 24),
      duration: const Duration(milliseconds: 150),
    );
  }

  void _showControls({bool stay = false}) {
    _setControlsShown(true);
    if (stay) {
      _hide?.cancel();
    } else {
      _hideLater();
    }
  }

  void _hideLater() {
    _hide?.cancel();
    _hide = Timer(_hideAfter, () {
      if (_playing) _setControlsShown(false);
    });
  }

  void _togglePlay() => unawaited(_player.playOrPause());

  void _onDoubleTap() {
    final at = _doubleTapAt;
    if (at == null || _locked) return;
    final width = context.size?.width ?? 0;
    if (at.dx < width / 3) {
      _skip(-_seekStep);
    } else if (at.dx > width * 2 / 3) {
      _skip(_seekStep);
    } else {
      _togglePlay();
    }
  }

  bool get _gesturesOn => _phone && _settings.gestures && !_locked && !_inPip;

  bool get _zoomOn => !_locked && !_inPip && (Desktop.isDesktop || _settings.gestures);

  void _setView({double? zoom, Offset? pan}) {
    final size = context.size;
    if (size == null) return;
    final next = _view.value.adjusted(zoom: zoom, pan: pan, screen: size);
    if (next.zoom != _view.value.zoom) _say('Zoom ${(next.zoom * 100).round()}%');
    _view.value = next;
  }

  void _settleView() {
    final settled = _view.value.settled();
    if (settled.isPlain && !_view.value.isPlain) _say('Zoom 100%');
    _view.value = settled;
  }

  void _onScaleStart(ScaleStartDetails details) {
    _drag = null;
    _dragTotal = Offset.zero;
    _zoomFrom = _view.value.zoom;
    _dragFrom = details.localFocalPoint.dx;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount >= 2) {
      if (!_zoomOn) return;
      if (_dragTo != null) _set(() => _dragTo = null);
      _drag = _Drag.zoom;
      _setView(zoom: _zoomFrom * details.scale, pan: _view.value.pan + details.focalPointDelta);
      return;
    }
    if (!_gesturesOn || _pinched || _drag == _Drag.zoom) return;
    if (_drag == null) {
      _dragTotal += details.focalPointDelta;
      if (_dragTotal.distance < kTouchSlop) return;
      _drag = _dragTotal.dx.abs() > _dragTotal.dy.abs() ? _Drag.seek : _Drag.level;
    }
    if (_drag == _Drag.seek) {
      _onSeekDrag(details.focalPointDelta.dx);
    } else {
      _onLevelDrag(details.focalPointDelta.dy);
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_drag == _Drag.seek) _onSeekDragEnd();
    if (_drag == _Drag.zoom) {
      _settleView();
      _pinched = true;
    }
    if (details.pointerCount == 0) _pinched = false;
    _drag = null;
  }

  void _onSeekDrag(double dx) {
    final width = context.size?.width ?? 1;
    final from = _dragTo ?? _position.value;
    // A whole screen's width is a hundred seconds.
    final by = Duration(milliseconds: (dx / width * 100000).round());
    var to = from + by;
    if (to < Duration.zero) to = Duration.zero;
    if (_duration > Duration.zero && to > _duration) to = _duration;
    _set(() => _dragTo = to);
    _say('${formatVideoTime(to)} / ${formatVideoTime(_duration)}');
  }

  void _onSeekDragEnd() {
    final to = _dragTo;
    _set(() => _dragTo = null);
    if (to != null) unawaited(_seek(to));
  }

  /// Left is brightness, right is volume.
  void _onLevelDrag(double dy) {
    final size = context.size;
    final from = _dragFrom;
    if (size == null || from == null) return;
    final by = -dy / size.height;
    if (from < size.width / 2) {
      final level = ((_brightness ?? 0.5) + by).clamp(0.01, 1.0);
      _brightness = level;
      unawaited(MediaControls.instance.setBrightness(level));
      _say('Brightness ${(level * 100).round()}%');
    } else {
      _setVolume(_volume + by * _maxVolume);
    }
  }

  void _setVolume(double value) {
    _volume = value.clamp(0.0, _maxVolume);
    unawaited(_player.setVolume(_volume));
    _say('Volume ${_volume.round()}%');
  }

  void _onScroll(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (HardwareKeyboard.instance.isControlPressed) {
      _setView(zoom: _view.value.zoom * (event.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1));
      _settleView();
      return;
    }
    _setVolume(_volume - event.scrollDelta.dy.sign * 5);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (event is KeyDownEvent) {
      if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
        _togglePlay();
      } else if (key == LogicalKeyboardKey.keyF) {
        unawaited(_toggleFullscreen());
      } else if (key == LogicalKeyboardKey.keyM) {
        _setVolume(_volume > 0 ? 0 : 100);
      } else if (key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.numpadAdd) {
        _setView(zoom: _view.value.zoom * 1.25);
      } else if (key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract) {
        _setView(zoom: _view.value.zoom / 1.25);
      } else if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
        _view.value = const VideoView();
        _say('Zoom 100%');
      } else if (key == LogicalKeyboardKey.keyN) {
        unawaited(_next());
      } else if (key == LogicalKeyboardKey.keyP) {
        unawaited(_previous());
      } else if (key == LogicalKeyboardKey.escape) {
        if (_fullscreen) {
          unawaited(_toggleFullscreen());
        } else {
          Navigator.of(context).maybePop();
        }
      } else if (key != LogicalKeyboardKey.arrowLeft &&
          key != LogicalKeyboardKey.arrowRight &&
          key != LogicalKeyboardKey.arrowUp &&
          key != LogicalKeyboardKey.arrowDown) {
        return KeyEventResult.ignored;
      }
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _skip(-_seekStep);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _skip(_seekStep);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _setVolume(_volume + 5);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _setVolume(_volume - 5);
    }
    _showControls();
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveProgress();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _hide?.cancel();
    _flashEnd?.cancel();
    _save?.cancel();
    _sleep?.cancel();
    _position.dispose();
    _view.dispose();
    _errorWait?.cancel();
    _focus.dispose();
    unawaited(_player.dispose());
    final controls = MediaControls.instance;
    unawaited(controls.stopped());
    unawaited(controls.setAutoPip(on: false));
    if (_brightness != null) unawaited(controls.setBrightness(null));
    if (_phone) {
      unawaited(SystemBars.show());
      SystemChrome.setPreferredOrientations(const []);
    } else {
      if (_fullscreen) unawaited(windowManager.setFullScreen(false));
      if (_inPip) {
        unawaited(windowManager.setAlwaysOnTop(false));
        final bounds = _boundsBeforePip;
        if (bounds != null) unawaited(windowManager.setBounds(bounds));
      }
      ExplorerTabs.instance.setChromeHidden(false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: Desktop.isDesktop ? (_) => _showControls() : null,
          child: Listener(
            onPointerSignal: Desktop.isDesktop ? _onScroll : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (controller != null) _video(controller),
                if (_error != null) _errorMessage(),
                if (_inPip) ..._pipOverlay() else ...[
                  _gestureLayer(),
                  if (_buffering && _error == null)
                    const Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3)),
                  if (_flash != null) _flashMessage(),
                  if (_locked) _lockedOverlay() else _controls(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _video(VideoController controller) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: ValueListenableBuilder<VideoView>(
            valueListenable: _view,
            builder: (_, view, child) => Transform.translate(
              offset: view.pan,
              child: Transform.scale(scale: view.zoom, child: child),
            ),
            child: Video(
              controller: controller,
              fit: _fit.box,
              aspectRatio: _fit.aspectRatio,
              fill: Colors.black,
              controls: NoVideoControls,
              pauseUponEnteringBackgroundMode: false,
              // Its own would zoom with the picture, and off the screen.
              subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
            ),
          ),
        ),
        ListenableBuilder(
          listenable: _settings,
          builder: (_, _) => SubtitleView(
            key: _subtitleKey,
            controller: controller,
            configuration: SubtitleViewConfiguration(
              style: TextStyle(
                height: 1.35,
                fontSize: _settings.subtitleSize * 1.5,
                fontWeight: FontWeight.w500,
                color: subtitleColors[_settings.subtitleColor],
                backgroundColor: _settings.subtitleBox ? const Color(0x99000000) : null,
                shadows: _settings.subtitleBox ? null : const [Shadow(blurRadius: 6)],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorMessage() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.videoOff, color: Colors.white70, size: 40),
            const SizedBox(height: 12),
            Text(
              _isStream ? "Can't play this stream" : "Can't play this video",
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              _error!,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            if (!_isStream) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(LucideIcons.externalLink, size: 16),
                label: const Text('Open with another app'),
                onPressed: () => OpenFilex.open(_queue.current),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _gestureLayer() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (Desktop.isDesktop && !_controlsShown) return _showControls();
        if (_controlsShown) {
          _hide?.cancel();
          _setControlsShown(false);
        } else {
          _showControls();
        }
      },
      onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
      onDoubleTap: Desktop.isDesktop ? () => unawaited(_toggleFullscreen()) : _onDoubleTap,
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd: _onScaleEnd,
    );
  }

  Widget _flashMessage() {
    return Align(
      alignment: const Alignment(0, -0.35),
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(_flash!, style: const TextStyle(color: Colors.white, fontSize: 15)),
          ),
        ),
      ),
    );
  }

  /// In the phone's small window the system adds its own controls; a computer's
  /// needs a way back and a way to move it.
  List<Widget> _pipOverlay() {
    if (!Desktop.isDesktop) return const [];
    return [
      const DragToMoveArea(child: SizedBox.expand()),
      Align(
        alignment: Alignment.topRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _button(_playing ? LucideIcons.pause : LucideIcons.play, _playing ? 'Pause' : 'Play', _togglePlay),
            _button(LucideIcons.maximize, 'Back to the full window', _desktopPip),
          ],
        ),
      ),
    ];
  }

  Widget _lockedOverlay() {
    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedOpacity(
        opacity: _controlsShown ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: IgnorePointer(
          ignoring: !_controlsShown,
          child: SafeArea(
            child: _button(LucideIcons.lock, 'Unlock', () {
              setState(() => _locked = false);
              _showControls();
            }),
          ),
        ),
      ),
    );
  }

  Widget _button(IconData icon, String tooltip, VoidCallback? onPressed, {double size = 22, Color? color}) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: size),
      color: color ?? Colors.white,
      disabledColor: Colors.white38,
      onPressed: onPressed == null
          ? null
          : () {
              onPressed();
              if (_controlsShown) _hideLater();
            },
    );
  }

  Widget _scrim({required Widget child, required bool top}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: top ? Alignment.topCenter : Alignment.bottomCenter,
          end: top ? Alignment.bottomCenter : Alignment.topCenter,
          colors: const [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: child,
    );
  }

  Widget _controls() {
    return AnimatedOpacity(
      opacity: _controlsShown ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      child: IgnorePointer(
        ignoring: !_controlsShown,
        child: Column(
          children: [
            _scrim(top: true, child: SafeArea(bottom: false, child: _topBar())),
            const Spacer(),
            _scrim(top: false, child: SafeArea(top: false, child: _bottomBar())),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          _button(LucideIcons.arrowLeft, 'Back', () => Navigator.of(context).maybePop()),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              videoTitle(_queue.current),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          _button(LucideIcons.captions, 'Subtitles', () => unawaited(_showSubtitles())),
          _button(LucideIcons.audioLines, 'Audio', () => unawaited(_showAudio())),
          Tooltip(
            message: 'Decoder',
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                minimumSize: const Size(44, 40),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              onPressed: () {
                unawaited(_showDecoder());
                _hideLater();
              },
              child: Text(_decoderLabel),
            ),
          ),
          if (_pipSupported || Desktop.isDesktop)
            _button(LucideIcons.pictureInPicture2, 'Picture in picture', () => unawaited(_enterPip())),
          _button(LucideIcons.settings2, 'Settings', () => unawaited(_showSettings())),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    final theme = SliderTheme.of(context).copyWith(
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      activeTrackColor: context.colors.primary,
      thumbColor: context.colors.primary,
      inactiveTrackColor: Colors.white30,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<Duration>(
            valueListenable: _position,
            builder: (_, position, _) {
              final shown = _dragTo ?? position;
              final total = _duration.inMilliseconds.toDouble();
              return Row(
                children: [
                  _time(shown),
                  Expanded(
                    child: SliderTheme(
                      data: theme,
                      child: Slider(
                        value: total <= 0 ? 0 : shown.inMilliseconds.clamp(0, total.toInt()).toDouble(),
                        max: total <= 0 ? 1 : total,
                        onChanged: total <= 0
                            ? null
                            : (value) {
                                _showControls();
                                setState(() => _dragTo = Duration(milliseconds: value.toInt()));
                              },
                        onChangeEnd: total <= 0
                            ? null
                            : (value) {
                                setState(() => _dragTo = null);
                                unawaited(_seek(Duration(milliseconds: value.toInt())));
                              },
                      ),
                    ),
                  ),
                  _isStream && _duration == Duration.zero
                      ? const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 12))
                      : _time(_duration),
                ],
              );
            },
          ),
          Row(
            children: [
              _button(LucideIcons.lockOpen, 'Lock', _phone
                  ? () {
                      setState(() => _locked = true);
                      _showControls();
                    }
                  : null),
              const Spacer(),
              _button(LucideIcons.skipBack, 'Previous', _previous),
              const SizedBox(width: 8),
              _button(
                _playing ? LucideIcons.pause : LucideIcons.play,
                _playing ? 'Pause' : 'Play',
                _togglePlay,
                size: 36,
              ),
              const SizedBox(width: 8),
              _button(LucideIcons.skipForward, 'Next', _queue.hasNext ? _next : null),
              const Spacer(),
              _button(LucideIcons.scan, 'Picture: ${_fit.label}', () {
                // After a pinch, first back to how it fits.
                if (_view.value.isPlain) setState(() => _fit = _fit.next);
                _view.value = const VideoView();
                _say(_fit.label);
              }),
              if (_phone)
                _button(LucideIcons.rotateCw, 'Rotate', _rotate)
              else
                _button(
                  _fullscreen ? LucideIcons.minimize : LucideIcons.maximize,
                  _fullscreen ? 'Leave full screen' : 'Full screen',
                  () => unawaited(_toggleFullscreen()),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _time(Duration time) => Text(
        formatVideoTime(time),
        style: const TextStyle(color: Colors.white, fontSize: 12, fontFeatures: [FontFeature.tabularFigures()]),
      );

  // The sheets

  Future<void> _sheet(Widget Function(BuildContext, StateSetter) builder) async {
    await AppSheet.show<void>(
      context,
      style: SheetStyle.side,
      child: StatefulBuilder(
        builder: (sheet, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
          child: builder(sheet, setSheet),
        ),
      ),
    );
    if (mounted) _focus.requestFocus();
  }

  static Widget _heading(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );

  static final _rowShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));

  static Widget _choice(
    BuildContext context, {
    required IconData icon,
    required String label,
    String? detail,
    bool selected = false,
    VoidCallback? onTap,
  }) {
    final colors = context.colors;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      shape: _rowShape,
      tileColor: selected ? colors.primary.withValues(alpha: 0.1) : null,
      leading: Icon(icon, size: 18, color: selected ? colors.primary : colors.mutedForeground),
      title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: detail == null ? null : Text(detail),
      trailing: selected ? Icon(LucideIcons.check, size: 18, color: colors.primary) : null,
      onTap: onTap,
    );
  }

  /// A value stepped by two buttons.
  static Widget _stepper(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onLess,
    required VoidCallback onMore,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: context.colors.mutedForeground),
          const SizedBox(width: 16),
          Expanded(child: Text(label)),
          IconButton(icon: const Icon(LucideIcons.minus, size: 16), tooltip: 'Less', onPressed: onLess),
          SizedBox(width: 64, child: Text(value, textAlign: TextAlign.center)),
          IconButton(icon: const Icon(LucideIcons.plus, size: 16), tooltip: 'More', onPressed: onMore),
        ],
      ),
    );
  }

  static String _trackName(String? title, String? language, String id) {
    final parts = [?title, ?language].where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? 'Track $id' : parts.join(' · ');
  }

  static String _delayText(double seconds) => '${seconds > 0 ? '+' : ''}${seconds.toStringAsFixed(1)} s';

  Future<void> _pickSubtitles(StateSetter setSheet) async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Subtitle file',
      initialDirectory: _isStream ? null : p.dirname(_queue.current),
      // Android's picker doesn't know these as types: any file, then checked.
      type: FileType.any,
    );
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    if (!subtitleExtensions.contains(p.extension(path).toLowerCase())) {
      _say('Not a subtitle file');
      return;
    }
    _subtitleFiles.add(path);
    await _player.setSubtitleTrack(SubtitleTrack.uri(path, title: p.basename(path)));
    if (mounted) setSheet(() {});
  }

  Future<void> _searchSubtitles(StateSetter setSheet) async {
    final path = await AppSheet.show<String>(
      context,
      style: SheetStyle.side,
      child: OnlineSubtitlesSheet(video: _queue.current),
    );
    if (path == null || !mounted) return;
    _subtitleFiles.add(path);
    await _player.setSubtitleTrack(SubtitleTrack.uri(path, title: p.basename(path)));
    if (mounted) setSheet(() {});
  }

  Future<void> _showSubtitles() => _sheet((sheet, setSheet) {
        final current = _track.subtitle;
        // mpv lists a file it was given as one more track: it has its own row.
        final fileNames = {for (final file in _subtitleFiles) p.basename(file)};
        final embedded = [
          for (final track in _tracks.subtitle)
            if (track.id != 'auto' && track.id != 'no' && !track.uri && !fileNames.contains(track.title)) track,
        ];
        final picked = current.id == 'auto' && _subtitleFiles.isEmpty ? embedded.firstOrNull?.id : current.id;
        return ListenableBuilder(
          listenable: _settings,
          builder: (_, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _heading(sheet, 'Subtitles'),
              _choice(
                sheet,
                icon: LucideIcons.captionsOff,
                label: 'Off',
                selected: current.id == 'no',
                onTap: () async {
                  await _player.setSubtitleTrack(SubtitleTrack.no());
                  setSheet(() {});
                },
              ),
              for (final track in embedded)
                _choice(
                  sheet,
                  icon: LucideIcons.captions,
                  label: _trackName(track.title, track.language, track.id),
                  selected: picked == track.id,
                  onTap: () async {
                    await _player.setSubtitleTrack(track);
                    setSheet(() {});
                  },
                ),
              for (final file in _subtitleFiles)
                _choice(
                  sheet,
                  icon: LucideIcons.fileText,
                  label: p.basename(file),
                  selected: current.id == file || current.title == p.basename(file),
                  onTap: () async {
                    await _player.setSubtitleTrack(SubtitleTrack.uri(file, title: p.basename(file)));
                    setSheet(() {});
                  },
                ),
              _choice(
                sheet,
                icon: LucideIcons.globe,
                label: 'Search online…',
                detail: 'In many languages, from OpenSubtitles',
                onTap: () => unawaited(_searchSubtitles(setSheet)),
              ),
              _choice(
                sheet,
                icon: LucideIcons.folderOpen,
                label: 'Load from a file…',
                detail: '.srt, .ass, .ssa, .vtt, .sub or .smi',
                onTap: () => unawaited(_pickSubtitles(setSheet)),
              ),
              _heading(sheet, 'Timing and look'),
              _stepper(
                sheet,
                icon: LucideIcons.timer,
                label: 'Delay',
                value: _delayText(_subtitleDelay),
                onLess: () {
                  setSheet(() => _subtitleDelay -= 0.1);
                  unawaited(_native?.setProperty('sub-delay', '$_subtitleDelay'));
                },
                onMore: () {
                  setSheet(() => _subtitleDelay += 0.1);
                  unawaited(_native?.setProperty('sub-delay', '$_subtitleDelay'));
                },
              ),
              _stepper(
                sheet,
                icon: LucideIcons.aLargeSmall,
                label: 'Size',
                value: '${_settings.subtitleSize.round()}',
                onLess: () => unawaited(_settings.update(subtitleSize: (_settings.subtitleSize - 2).clamp(14, 72))),
                onMore: () => unawaited(_settings.update(subtitleSize: (_settings.subtitleSize + 2).clamp(14, 72))),
              ),
              for (final name in subtitleColors.keys)
                _choice(
                  sheet,
                  icon: LucideIcons.palette,
                  label: name,
                  selected: _settings.subtitleColor == name,
                  onTap: () => unawaited(_settings.update(subtitleColor: name)),
                ),
              SwitchListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                secondary: const Icon(LucideIcons.square, size: 18),
                title: const Text('Dark box behind the text'),
                value: _settings.subtitleBox,
                onChanged: (on) => unawaited(_settings.update(subtitleBox: on)),
              ),
            ],
          ),
        );
      });

  Future<void> _showDecoder() => _sheet((sheet, setSheet) {
        return ListenableBuilder(
          listenable: _settings,
          builder: (_, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _heading(sheet, 'Decoder'),
              for (final decoder in VideoDecoder.available)
                _choice(
                  sheet,
                  icon: LucideIcons.cpu,
                  label: '${decoder.short} · ${decoder.label}',
                  detail: decoder.description,
                  selected: _decoderLabel == decoder.short,
                  // All this phone's graphics can do is HW+.
                  onTap: _settings.gpuRefused && decoder != VideoDecoder.hwPlus
                      ? null
                      : () {
                          // A restart would leave this sheet on a player that's gone.
                          Navigator.pop(sheet);
                          unawaited(_setDecoder(decoder));
                        },
                ),
              if (_settings.gpuRefused)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Text(
                    "This device's graphics can only show video with HW+.",
                    style: Theme.of(sheet).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        );
      });

  Future<void> _showAudio() => _sheet((sheet, setSheet) {
        final current = _track.audio;
        final tracks = [
          for (final track in _tracks.audio)
            if (track.id != 'auto' && track.id != 'no') track,
        ];
        final picked = current.id == 'auto' ? tracks.firstOrNull?.id : current.id;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _heading(sheet, 'Audio track'),
            if (tracks.isEmpty)
              _choice(sheet, icon: LucideIcons.volumeX, label: 'This video has no sound'),
            for (final track in tracks)
              _choice(
                sheet,
                icon: LucideIcons.audioLines,
                label: _trackName(track.title, track.language, track.id),
                detail: [
                  ?track.codec,
                  // mpv names what it can't tell "unknown1".
                  if (track.channels != null && !track.channels!.startsWith('unknown')) track.channels!,
                ].join(' · '),
                selected: picked == track.id,
                onTap: () async {
                  await _player.setAudioTrack(track);
                  setSheet(() {});
                },
              ),
            _heading(sheet, 'Sound'),
            _stepper(
              sheet,
              icon: LucideIcons.volume2,
              label: 'Volume',
              value: '${_volume.round()}%',
              onLess: () => setSheet(() => _setVolume(_volume - 10)),
              onMore: () => setSheet(() => _setVolume(_volume + 10)),
            ),
            _stepper(
              sheet,
              icon: LucideIcons.timer,
              label: 'Delay',
              value: _delayText(_audioDelay),
              onLess: () {
                setSheet(() => _audioDelay -= 0.1);
                unawaited(_native?.setProperty('audio-delay', '$_audioDelay'));
              },
              onMore: () {
                setSheet(() => _audioDelay += 0.1);
                unawaited(_native?.setProperty('audio-delay', '$_audioDelay'));
              },
            ),
          ],
        );
      });

  void _setSleep(int? minutes) {
    _sleep?.cancel();
    _sleep = null;
    _sleepAt = null;
    if (minutes == null) return;
    final length = Duration(minutes: minutes);
    _sleepAt = DateTime.now().add(length);
    _sleep = Timer(length, () {
      _sleepAt = null;
      unawaited(_player.pause());
    });
  }

  Future<void> _screenshot() async {
    final bytes = await _player.screenshot(format: 'image/jpeg');
    if (!mounted) return;
    if (bytes == null) {
      _say("This frame can't be saved");
      return;
    }
    final name = '${p.basenameWithoutExtension(videoTitle(_queue.current))}_${_position.value.inSeconds}s.jpg';
    final folder = Directory(p.join(ExplorerPaths.homePath, 'Pictures', 'Explorer'));
    await folder.create(recursive: true);
    await File(p.join(folder.path, name)).writeAsBytes(bytes);
    _say('Saved in Pictures/Explorer');
  }

  Future<void> _showSettings() => _sheet((sheet, setSheet) {
        return ListenableBuilder(
          listenable: _settings,
          builder: (_, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _heading(sheet, 'Speed'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final speed in _speeds)
                    ChoiceChip(
                      shape: const StadiumBorder(),
                      label: Text('$speed×'),
                      selected: _speed == speed,
                      onSelected: (_) {
                        setSheet(() => _speed = speed);
                        setState(() {});
                        unawaited(_player.setRate(speed));
                        _updateOutside();
                      },
                    ),
                ],
              ),
              _heading(sheet, 'Picture'),
              for (final fit in VideoFit.values)
                _choice(
                  sheet,
                  icon: LucideIcons.scan,
                  label: fit.label,
                  selected: _fit == fit,
                  onTap: () {
                    setSheet(() => _fit = fit);
                    setState(() {});
                    _view.value = const VideoView();
                  },
                ),
              _heading(sheet, 'Playing'),
              for (final mode in VideoRepeat.values)
                _choice(
                  sheet,
                  icon: switch (mode) {
                    VideoRepeat.off => LucideIcons.arrowRight,
                    VideoRepeat.one => LucideIcons.repeat1,
                    VideoRepeat.all => LucideIcons.repeat,
                  },
                  label: mode.label,
                  selected: _queue.repeat == mode,
                  onTap: () {
                    setSheet(() => _queue.repeat = mode);
                    setState(() {});
                    _updateOutside();
                  },
                ),
              SwitchListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                secondary: const Icon(LucideIcons.shuffle, size: 18),
                title: const Text('Shuffle'),
                value: _queue.shuffle,
                onChanged: (on) {
                  setSheet(() => _queue.shuffle = on);
                  setState(() {});
                  _updateOutside();
                },
              ),
              SwitchListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                secondary: const Icon(LucideIcons.history, size: 18),
                title: const Text('Continue where it stopped'),
                value: _settings.resume,
                onChanged: (on) => unawaited(_settings.update(resume: on)),
              ),
              _heading(sheet, 'Sleep timer'),
              _choice(
                sheet,
                icon: LucideIcons.timerOff,
                label: 'Off',
                selected: _sleepAt == null,
                onTap: () => setSheet(() => _setSleep(null)),
              ),
              Wrap(
                spacing: 6,
                children: [
                  for (final minutes in _sleepMinutes)
                    ActionChip(
                      shape: const StadiumBorder(),
                      avatar: const Icon(LucideIcons.timer, size: 14),
                      label: Text('$minutes min'),
                      onPressed: () {
                        setSheet(() => _setSleep(minutes));
                        _say('Pauses in $minutes minutes');
                      },
                    ),
                ],
              ),
              if (_phone) ...[
                _heading(sheet, 'On leaving the app'),
                for (final leaving in LeavingVideo.values)
                  _choice(
                    sheet,
                    icon: switch (leaving) {
                      LeavingVideo.pip => LucideIcons.pictureInPicture2,
                      LeavingVideo.background => LucideIcons.headphones,
                      LeavingVideo.pause => LucideIcons.pause,
                    },
                    label: leaving.label,
                    selected: _settings.leaving == leaving,
                    onTap: () async {
                      await _settings.update(leaving: leaving);
                      _updateAutoPip();
                    },
                  ),
              ],
              _heading(sheet, 'Advanced'),
              if (_phone)
                SwitchListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  secondary: const Icon(LucideIcons.hand, size: 18),
                  title: const Text('Gestures'),
                  subtitle: const Text('Drag to seek, and for brightness and volume'),
                  value: _settings.gestures,
                  onChanged: (on) {
                    unawaited(_settings.update(gestures: on));
                    setState(() {});
                  },
                ),
              _choice(sheet, icon: LucideIcons.camera, label: 'Save this frame', onTap: () => unawaited(_screenshot())),
              if (!_isStream) ...[
                _choice(
                  sheet,
                  icon: LucideIcons.share2,
                  label: 'Share',
                  onTap: () => FileActionsService().shareMany(sheet, [File(_queue.current)]),
                ),
                _choice(
                  sheet,
                  icon: LucideIcons.externalLink,
                  label: 'Open with another app',
                  onTap: () => OpenFilex.open(_queue.current),
                ),
              ],
            ],
          ),
        );
      });
}
