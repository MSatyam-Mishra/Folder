import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What's pressed outside the app: in the notification, on the lock screen, on
/// a headset or in the small picture-in-picture window.
enum MediaCommand { play, pause, next, previous, stop, seek }

/// The video player's way out of the app on Android: notification and lock
/// screen controls (MediaPlaybackService.kt), picture in picture and the
/// window's brightness (VideoPlayerNative.kt). It does nothing elsewhere.
class MediaControls {
  MediaControls._() {
    if (Platform.isAndroid) _channel.setMethodCallHandler(_onCall);
  }

  static final instance = MediaControls._();

  static const _channel = MethodChannel('explorer/video_player');

  final _commands = StreamController<(MediaCommand, Duration?)>.broadcast();
  final _pip = StreamController<bool>.broadcast();

  /// A command, with its position when it's a seek.
  Stream<(MediaCommand, Duration?)> get commands => _commands.stream;

  /// Whether the window has gone into picture in picture.
  Stream<bool> get pipChanges => _pip.stream;

  Future<void> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'command':
        final args = call.arguments as Map<Object?, Object?>;
        final command = MediaCommand.values.asNameMap()[args['name']];
        final position = args['position'] as num?;
        if (command != null) {
          _commands.add((command, position == null ? null : Duration(milliseconds: position.toInt())));
        }
      case 'pipChanged':
        _pip.add(call.arguments as bool);
    }
  }

  @visibleForTesting
  void sendCommand(MediaCommand command, [Duration? position]) => _commands.add((command, position));

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      debugPrint('Video player: $method failed: $e');
    }
  }

  Future<void> nowPlaying({
    required String title,
    required String detail,
    required bool playing,
    required Duration position,
    required Duration duration,
    required bool hasPrevious,
    required bool hasNext,
    required double speed,
  }) =>
      _invoke('nowPlaying', {
        'title': title,
        'detail': detail,
        'playing': playing,
        'position': position.inMilliseconds,
        'duration': duration.inMilliseconds,
        'hasPrevious': hasPrevious,
        'hasNext': hasNext,
        'speed': speed,
      });

  Future<void> artwork(Uint8List? bytes) => _invoke('artwork', {'bytes': bytes});

  Future<void> stopped() => _invoke('stopped');

  Future<bool> get pipSupported async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('pipSupported') ?? false;
  }

  /// Into picture in picture now; false if the system refused.
  Future<bool> enterPip({required int width, required int height}) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('enterPip', {'width': width, 'height': height}) ?? false;
  }

  /// Whether leaving the app takes the video into picture in picture.
  Future<void> setAutoPip({required bool on, int width = 16, int height = 9}) =>
      _invoke('setAutoPip', {'on': on, 'width': width, 'height': height});

  /// This window's brightness, 0 to 1; null gives it back to the system.
  Future<void> setBrightness(double? value) => _invoke('brightness', {'value': value});
}
