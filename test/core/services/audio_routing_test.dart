import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/audio/audio_support.dart';
import 'package:folders/core/services/audio/routing_audio_platform.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

PlaybackEventMessage event({int? errorCode, ProcessingStateMessage state = ProcessingStateMessage.ready}) => PlaybackEventMessage(
      processingState: state,
      updateTime: DateTime(2026),
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
      duration: const Duration(seconds: 3),
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
      errorCode: errorCode,
      errorMessage: errorCode == null ? null : 'Failed to open',
    );

class FakePlayer extends AudioPlayerPlatform {
  FakePlayer(super.id, this.platform);

  final FakePlatform platform;
  final events = StreamController<PlaybackEventMessage>.broadcast();
  final calls = <String>[];
  double? volume;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => const Stream.empty();

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    calls.add('load');
    switch (platform.onLoad) {
      case LoadOutcome.ok:
        events.add(event());
        return LoadResponse(duration: const Duration(seconds: 3));
      case LoadOutcome.throws:
        // ExoPlayer says so in an event too, before the call fails.
        events.add(event(errorCode: 1, state: ProcessingStateMessage.idle));
        throw PlatformException(code: '1', message: 'Source error');
      case LoadOutcome.errorEventOnly:
        // just_audio_media_kit when libmpv can't open the file.
        events.add(event(errorCode: 1, state: ProcessingStateMessage.idle));
        return Completer<LoadResponse>().future;
    }
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    calls.add('play');
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    calls.add('pause');
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    volume = request.volume;
    return SetVolumeResponse();
  }
}

enum LoadOutcome { ok, throws, errorEventOnly }

class FakePlatform extends JustAudioPlatform {
  FakePlatform(this.name);

  final String name;
  LoadOutcome onLoad = LoadOutcome.ok;
  final players = <String, FakePlayer>{};
  final disposed = <String>[];

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async => players[request.id] = FakePlayer(request.id, this);

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async {
    disposed.add(request.id);
    return DisposePlayerResponse();
  }
}

LoadRequest file(String path) => LoadRequest(
      audioSourceMessage: ConcatenatingAudioSourceMessage(
        id: 'playlist',
        children: [ProgressiveAudioSourceMessage(id: 'a', uri: Uri.file(path).toString())],
        useLazyPreparation: true,
        shuffleOrder: const [0],
      ),
    );

void main() {
  late FakePlatform exo;
  late FakePlatform mpv;
  late RoutingAudioPlatform routing;
  late AudioPlayerPlatform player;
  late List<PlaybackEventMessage> seen;

  setUp(() async {
    exo = FakePlatform('exo');
    mpv = FakePlatform('mpv');
    routing = RoutingAudioPlatform(preferred: exo, fallback: mpv, wantsFallback: AudioSupport.wantsMpvOnAndroid);
    player = await routing.init(InitRequest(id: 'p1'));
    seen = [];
    player.playbackEventMessageStream.listen(seen.add);
  });

  test('ExoPlayer plays what it can; WMA and AIFF go straight to libmpv', () async {
    await player.load(file('/sdcard/Music/song.mp3'));
    expect(exo.players.values.single.calls, ['load']);
    expect(mpv.players, isEmpty);

    await player.load(file('/sdcard/Music/old song.WMA'));
    expect(exo.disposed, ['p1.1'], reason: 'one player at a time');
    expect(mpv.players.values.single.calls, ['load']);
    expect((player as RoutedAudioPlayer).usesFallback, isTrue);

    await player.load(file('/sdcard/Music/b.aiff'));
    expect(mpv.players.values.single.calls, ['load', 'load'], reason: 'kept while it suits');
  });

  test("what ExoPlayer can't load goes to libmpv, with the settings and playing", () async {
    exo.onLoad = LoadOutcome.throws;
    await player.setVolume(SetVolumeRequest(volume: 0.4));
    unawaited(player.play(PlayRequest()));
    final response = await player.load(file('/sdcard/Music/odd.mka'));
    expect(response.duration, const Duration(seconds: 3));
    final fallback = mpv.players.values.single;
    expect(fallback.volume, 0.4);
    expect(fallback.calls, ['play', 'load']);
    expect(seen.where((e) => e.errorCode != null), isEmpty, reason: "ExoPlayer's failure isn't passed on");
    expect(seen, isNotEmpty);
  });

  test("libmpv's error event ends a load that would wait for ever", () async {
    mpv.onLoad = LoadOutcome.errorEventOnly;
    await expectLater(player.load(file('/sdcard/Music/voice.caf.wma')), throwsA(isA<PlatformException>()));

    exo.onLoad = LoadOutcome.throws;
    await expectLater(
      player.load(file('/sdcard/Music/voice.caf')),
      throwsA(isA<PlatformException>().having((e) => e.message, 'message', 'Failed to open')),
    );
  });

  test("settings libmpv lacks don't throw, and still reach ExoPlayer later", () async {
    await player.load(file('/sdcard/a.wma'));
    final attributes = SetAndroidAudioAttributesRequest(contentType: 2, flags: 0, usage: 1);
    await player.setAndroidAudioAttributes(attributes);
    await player.load(file('/sdcard/a.mp3'));
    expect(exo.players.values.single.calls, ['load']);
  });

  test('an interrupted load is just passed on', () async {
    final interrupted = FakePlatform('exo');
    final routing = RoutingAudioPlatform(preferred: _Aborting(interrupted), fallback: mpv, wantsFallback: (_) => false);
    final p = await routing.init(InitRequest(id: 'p2'));
    await expectLater(p.load(file('/a.mp3')), throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'abort')));
    expect(mpv.players, isEmpty);
  });

  test('disposing lets go of the player inside', () async {
    await player.load(file('/sdcard/a.mp3'));
    await routing.disposePlayer(DisposePlayerRequest(id: 'p1'));
    expect(exo.disposed, ['p1.1']);
    expect(await routing.init(InitRequest(id: 'p1')), isA<RoutedAudioPlayer>(), reason: 'the id is free again');
  });

  test('addresses in playlists, clips and loops', () {
    final uris = RoutingAudioPlatform.urisOf(LoopingAudioSourceMessage(
      id: 'l',
      count: 2,
      child: ConcatenatingAudioSourceMessage(
        id: 'c',
        useLazyPreparation: true,
        shuffleOrder: const [0, 1],
        children: [
          ProgressiveAudioSourceMessage(id: 'a', uri: 'file:///a.mp3'),
          ClippingAudioSourceMessage(id: 'b', child: ProgressiveAudioSourceMessage(id: 'b0', uri: 'file:///b.wma')),
        ],
      ),
    ));
    expect(uris, ['file:///a.mp3', 'file:///b.wma']);
    expect(AudioSupport.wantsMpvOnAndroid('file:///storage/emulated/0/My%20Music/b.WMA'), isTrue);
    expect(AudioSupport.wantsMpvOnAndroid('/storage/emulated/0/a.flac'), isFalse);
  });

  test('says why a CAF file plays nowhere on Android', () {
    expect(AudioSupport.whyNot('/sdcard/a.caf', android: true), contains('CAF'));
    expect(AudioSupport.whyNot('/sdcard/a.caf', android: false), isNull);
    expect(AudioSupport.whyNot('/sdcard/a.wma', android: true), isNull);
  });
}

class _Aborting extends JustAudioPlatform {
  _Aborting(this.inner);

  final FakePlatform inner;

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async => _AbortingPlayer(request.id, inner);

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async => DisposePlayerResponse();
}

class _AbortingPlayer extends FakePlayer {
  _AbortingPlayer(super.id, super.platform);

  @override
  Future<LoadResponse> load(LoadRequest request) async => throw PlatformException(code: 'abort', message: 'Loading interrupted');
}
