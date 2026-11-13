import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// Picks the player for each file: [preferred] (just_audio's own, ExoPlayer
/// on Android), or [fallback] (libmpv through just_audio_media_kit) for files
/// [wantsFallback] names and for anything [preferred] fails to load. The
/// app's `AudioPlayer`s don't see the difference.
///
/// Each player wraps one player of either kind, made when a file loads and
/// swapped for the other kind when needed; settings (volume, speed, loop...)
/// and playing carry over.
class RoutingAudioPlatform extends JustAudioPlatform {
  RoutingAudioPlatform({required this.preferred, required this.fallback, required this.wantsFallback});

  final JustAudioPlatform preferred;
  final JustAudioPlatform fallback;

  /// Whether the file at [uri] should go to [fallback] at once.
  final bool Function(String uri) wantsFallback;

  /// How long [fallback] may take to open a file before it counts as failed.
  static Duration openTimeout = const Duration(seconds: 20);

  final _players = <String, RoutedAudioPlayer>{};

  /// The players now open, for tests.
  @visibleForTesting
  Iterable<RoutedAudioPlayer> get players => _players.values;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    if (_players.containsKey(request.id)) {
      throw PlatformException(code: 'error', message: 'Player ${request.id} already exists');
    }
    return _players[request.id] = RoutedAudioPlayer._(request, this);
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async {
    await _players.remove(request.id)?.release();
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async {
    final players = _players.values.toList();
    _players.clear();
    for (final player in players) {
      await player.release();
    }
    for (final platform in [preferred, fallback]) {
      try {
        await platform.disposeAllPlayers(request);
      } catch (_) {
        // Not every platform has it.
      }
    }
    return DisposeAllPlayersResponse();
  }

  /// The addresses [source] plays.
  @visibleForTesting
  static List<String> urisOf(AudioSourceMessage source) => switch (source) {
        UriAudioSourceMessage(:final uri) => [uri],
        ConcatenatingAudioSourceMessage(:final children) => [for (final child in children) ...urisOf(child)],
        ClippingAudioSourceMessage(:final child) => [child.uri],
        LoopingAudioSourceMessage(:final child) => urisOf(child),
        _ => const [],
      };
}

/// One app player, playing through whichever kind suits the file.
class RoutedAudioPlayer extends AudioPlayerPlatform {
  RoutedAudioPlayer._(this._request, this._owner) : super(_request.id);

  final InitRequest _request;
  final RoutingAudioPlatform _owner;
  final _events = StreamController<PlaybackEventMessage>.broadcast();
  final _data = StreamController<PlayerDataMessage>.broadcast();

  AudioPlayerPlatform? _inner;
  JustAudioPlatform? _platform;
  String? _innerId;
  int _generation = 0;
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// Events held back while the preferred player loads: if it fails, they
  /// would tell just_audio the player stopped, though the other one takes over.
  List<void Function()>? _held;

  bool _playing = false;
  Completer<PlayResponse>? _play;
  bool _released = false;

  SetVolumeRequest? _volume;
  SetSpeedRequest? _speed;
  SetPitchRequest? _pitch;
  SetSkipSilenceRequest? _skipSilence;
  SetLoopModeRequest? _loopMode;
  SetShuffleModeRequest? _shuffleMode;
  SetAndroidAudioAttributesRequest? _audioAttributes;
  SetAutomaticallyWaitsToMinimizeStallingRequest? _stalling;

  /// Whether the file now loaded plays through the fallback (libmpv).
  bool get usesFallback => identical(_platform, _owner.fallback);

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  void _emit(void Function() send) {
    if (_released) return;
    final held = _held;
    if (held != null) {
      held.add(send);
    } else {
      send();
    }
  }

  void _releaseHeld() {
    final held = _held;
    _held = null;
    for (final send in held ?? const <void Function()>[]) {
      send();
    }
  }

  Future<void> _use(JustAudioPlatform platform) async {
    if (identical(platform, _platform) && _inner != null) return;
    await _dropInner();
    final innerId = '$id.${++_generation}';
    final inner = await platform.init(InitRequest(
      id: innerId,
      audioLoadConfiguration: _request.audioLoadConfiguration,
      androidAudioEffects: identical(platform, _owner.preferred) ? _request.androidAudioEffects : const [],
      darwinAudioEffects: identical(platform, _owner.preferred) ? _request.darwinAudioEffects : const [],
      androidAudioOffloadPreferences: _request.androidAudioOffloadPreferences,
      androidOffloadSchedulingEnabled: _request.androidOffloadSchedulingEnabled,
      useLazyPreparation: _request.useLazyPreparation,
    ));
    _inner = inner;
    _platform = platform;
    _innerId = innerId;
    _subscriptions
      ..add(inner.playbackEventMessageStream.listen(
        (event) => _emit(() => _events.add(event)),
        onError: (Object e, StackTrace s) => _emit(() => _events.addError(e, s)),
      ))
      ..add(inner.playerDataMessageStream.listen(
        (data) => _emit(() => _data.add(data)),
        onError: (Object e, StackTrace s) => _emit(() => _data.addError(e, s)),
      ));
    // What the app set before, on the new player too. Each may be missing
    // from one kind of player.
    Future<void> apply(Future<Object?> Function() set) async {
      try {
        await set();
      } catch (_) {}
    }

    if (_audioAttributes case final r?) await apply(() => inner.setAndroidAudioAttributes(r));
    if (_stalling case final r?) await apply(() => inner.setAutomaticallyWaitsToMinimizeStalling(r));
    if (_volume case final r?) await apply(() => inner.setVolume(r));
    if (_speed case final r?) await apply(() => inner.setSpeed(r));
    if (_pitch case final r?) await apply(() => inner.setPitch(r));
    if (_skipSilence case final r?) await apply(() => inner.setSkipSilence(r));
    if (_loopMode case final r?) await apply(() => inner.setLoopMode(r));
    if (_shuffleMode case final r?) await apply(() => inner.setShuffleMode(r));
    if (_playing) _startPlaying(inner);
  }

  Future<void> _dropInner() async {
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    final platform = _platform;
    final id = _innerId;
    final inner = _inner;
    _inner = null;
    _platform = null;
    _innerId = null;
    if (platform == null || id == null || inner == null) return;
    try {
      await platform.disposePlayer(DisposePlayerRequest(id: id));
    } catch (_) {
      try {
        await inner.dispose(DisposeRequest());
      } catch (_) {}
    }
  }

  void _startPlaying(AudioPlayerPlatform inner) {
    final done = _play ??= Completer<PlayResponse>();
    inner.play(PlayRequest()).then(
      (response) {
        if (identical(inner, _inner) && !done.isCompleted) done.complete(response);
      },
      onError: (Object e, StackTrace s) {
        if (identical(inner, _inner) && !done.isCompleted) done.completeError(e, s);
      },
    );
  }

  void _stopPlaying() {
    final done = _play;
    _play = null;
    if (done != null && !done.isCompleted) done.complete(PlayResponse());
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final uris = RoutingAudioPlatform.urisOf(request.audioSourceMessage);
    if (uris.any(_owner.wantsFallback)) {
      await _use(_owner.fallback);
      return _loadFallback(request);
    }
    await _use(_owner.preferred);
    _held = [];
    try {
      final response = await _inner!.load(request);
      _releaseHeld();
      return response;
    } on PlatformException catch (e) {
      // Another load came first: not this file's fault.
      if (e.code == 'abort') {
        _releaseHeld();
        rethrow;
      }
      // What it said meanwhile goes with it.
      await _dropInner();
      _held = null;
      debugPrint('Audio: the preferred player failed ($e), trying the other one');
      await _use(_owner.fallback);
      return _loadFallback(request);
    }
  }

  /// just_audio_media_kit's load waits for the file to be ready and never
  /// ends when libmpv can't open it: its error comes as an event instead.
  Future<LoadResponse> _loadFallback(LoadRequest request) async {
    final inner = _inner!;
    final failed = Completer<LoadResponse>();
    final watch = inner.playbackEventMessageStream.listen((event) {
      if (event.errorCode != null && !failed.isCompleted) {
        failed.completeError(PlatformException(code: '${event.errorCode}', message: event.errorMessage));
      }
    });
    try {
      return await Future.any([inner.load(request), failed.future]).timeout(RoutingAudioPlatform.openTimeout);
    } on TimeoutException {
      throw PlatformException(code: 'timeout', message: "The player couldn't open the file");
    } finally {
      await watch.cancel();
    }
  }

  @override
  Future<PlayResponse> play(PlayRequest request) {
    _playing = true;
    final done = _play ??= Completer<PlayResponse>();
    if (_inner case final inner?) _startPlaying(inner);
    return done.future;
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _playing = false;
    final response = await _inner?.pause(request) ?? PauseResponse();
    _stopPlaying();
    return response;
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async => await _inner?.seek(request) ?? SeekResponse();

  /// Passes a setting on, if there's a player yet. One kind may lack it
  /// (libmpv's has no Android audio attributes): then it's simply kept for
  /// the other kind.
  Future<T> _setting<T>(Future<T> Function(AudioPlayerPlatform inner) set, T Function() none) async {
    final inner = _inner;
    if (inner == null) return none();
    try {
      return await set(inner);
    } on UnimplementedError {
      return none();
    }
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    _volume = request;
    return _setting((inner) => inner.setVolume(request), SetVolumeResponse.new);
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    _speed = request;
    return _setting((inner) => inner.setSpeed(request), SetSpeedResponse.new);
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async {
    _pitch = request;
    return _setting((inner) => inner.setPitch(request), SetPitchResponse.new);
  }

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(SetSkipSilenceRequest request) async {
    _skipSilence = request;
    return _setting((inner) => inner.setSkipSilence(request), SetSkipSilenceResponse.new);
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    _loopMode = request;
    return _setting((inner) => inner.setLoopMode(request), SetLoopModeResponse.new);
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) async {
    _shuffleMode = request;
    return _setting((inner) => inner.setShuffleMode(request), SetShuffleModeResponse.new);
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(SetAndroidAudioAttributesRequest request) async {
    _audioAttributes = request;
    return _setting((inner) => inner.setAndroidAudioAttributes(request), SetAndroidAudioAttributesResponse.new);
  }

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse> setAutomaticallyWaitsToMinimizeStalling(
    SetAutomaticallyWaitsToMinimizeStallingRequest request,
  ) async {
    _stalling = request;
    return _setting((inner) => inner.setAutomaticallyWaitsToMinimizeStalling(request), SetAutomaticallyWaitsToMinimizeStallingResponse.new);
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(SetShuffleOrderRequest request) =>
      _inner?.setShuffleOrder(request) ?? super.setShuffleOrder(request);

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(ConcatenatingInsertAllRequest request) =>
      _inner?.concatenatingInsertAll(request) ?? super.concatenatingInsertAll(request);

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(ConcatenatingRemoveRangeRequest request) =>
      _inner?.concatenatingRemoveRange(request) ?? super.concatenatingRemoveRange(request);

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(ConcatenatingMoveRequest request) =>
      _inner?.concatenatingMove(request) ?? super.concatenatingMove(request);

  @override
  Future<AudioEffectSetEnabledResponse> audioEffectSetEnabled(AudioEffectSetEnabledRequest request) =>
      _inner?.audioEffectSetEnabled(request) ?? super.audioEffectSetEnabled(request);

  @override
  Future<AndroidLoudnessEnhancerSetTargetGainResponse> androidLoudnessEnhancerSetTargetGain(
    AndroidLoudnessEnhancerSetTargetGainRequest request,
  ) =>
      _inner?.androidLoudnessEnhancerSetTargetGain(request) ?? super.androidLoudnessEnhancerSetTargetGain(request);

  @override
  Future<AndroidEqualizerGetParametersResponse> androidEqualizerGetParameters(AndroidEqualizerGetParametersRequest request) =>
      _inner?.androidEqualizerGetParameters(request) ?? super.androidEqualizerGetParameters(request);

  @override
  Future<AndroidEqualizerBandSetGainResponse> androidEqualizerBandSetGain(AndroidEqualizerBandSetGainRequest request) =>
      _inner?.androidEqualizerBandSetGain(request) ?? super.androidEqualizerBandSetGain(request);

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    await release();
    return DisposeResponse();
  }

  /// Stops and lets go of the player inside.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _stopPlaying();
    _held = null;
    await _dropInner();
    await _events.close();
    await _data.close();
  }
}
