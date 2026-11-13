import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:folders/core/services/audio/audio_support.dart';
import 'package:folders/core/services/device_files.dart';
import 'package:folders/features/category_view/home_media.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// All the music on the device, played one song after another.
class MusicPlayerScreen extends StatefulWidget {
  const MusicPlayerScreen({super.key});

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen> {
  final _player = AudioPlayer();
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _random = math.Random();
  List<DeviceFile>? _songs;
  int? _current;
  bool _shuffle = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  Future<void> _load() async {
    List<DeviceFile> songs;
    try {
      // Android has its media index; computers keep music in home folders.
      songs = Platform.isAndroid ? await DeviceFiles.findAndroidAudio() : await HomeMedia.find(RequestType.audio);
    } catch (e) {
      debugPrint('Music: $e');
      songs = const [];
    }
    if (mounted) setState(() => _songs = songs);
  }

  Future<void> _play(int index) async {
    final songs = _songs;
    if (songs == null || index < 0 || index >= songs.length) return;
    setState(() {
      _current = index;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    try {
      await AudioSupport.load(_player, songs[index].path);
      if (!mounted) return;
      setState(() => _duration = _player.duration ?? Duration.zero);
      unawaited(_player.play());
    } catch (e) {
      debugPrint('Playing ${songs[index].path}: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AudioSupport.whyNot(songs[index].path) ?? "Couldn't play ${songs[index].name}")),
      );
    }
  }

  void _next() {
    final songs = _songs;
    final current = _current;
    if (songs == null || songs.isEmpty || current == null) return;
    if (_shuffle) {
      _play(_random.nextInt(songs.length));
    } else if (current + 1 < songs.length) {
      _play(current + 1);
    } else {
      _player.stop();
    }
  }

  void _previous() {
    final current = _current;
    if (current == null) return;
    // Well into a song, it goes back to the start of it.
    if (_position > const Duration(seconds: 3) || current == 0) {
      _player.seek(Duration.zero);
    } else {
      _play(current - 1);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    _subscriptions
      ..add(_player.playerStateStream.listen((state) {
        if (!mounted) return;
        setState(() => _playing = state.playing && state.processingState != ProcessingState.completed);
        if (state.processingState == ProcessingState.completed) _next();
      }))
      ..add(_player.positionStream.listen((position) {
        if (mounted) setState(() => _position = position);
      }));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  static String _time(Duration d) {
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inMinutes}:$seconds';
  }

  Widget _controls(DeviceFile song) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final total = _duration.inMilliseconds.toDouble();
    final content = SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(song.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
            Row(
              children: [
                Text(_time(_position), style: text.bodySmall),
                Expanded(
                  child: Slider(
                    value: total <= 0 ? 0 : _position.inMilliseconds.clamp(0, total.toInt()).toDouble(),
                    max: total <= 0 ? 1 : total,
                    onChanged: total <= 0 ? null : (value) => _player.seek(Duration(milliseconds: value.toInt())),
                  ),
                ),
                Text(_time(_duration), style: text.bodySmall),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: _shuffle ? 'Shuffle is on' : 'Shuffle',
                  icon: Icon(LucideIcons.shuffle, size: 20, color: _shuffle ? colors.primary : null),
                  onPressed: () => setState(() => _shuffle = !_shuffle),
                ),
                IconButton(tooltip: 'Previous', icon: const Icon(LucideIcons.skipBack), onPressed: _previous),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: _playing ? 'Pause' : 'Play',
                  iconSize: 28,
                  icon: Icon(_playing ? LucideIcons.pause : LucideIcons.play, color: colors.primaryForeground),
                  onPressed: () => _playing ? _player.pause() : _player.play(),
                ),
                const SizedBox(width: 8),
                IconButton(tooltip: 'Next', icon: const Icon(LucideIcons.skipForward), onPressed: _next),
                const SizedBox(width: 40),
              ],
            ),
          ],
        ),
      ),
    );
    return AppGlass.isLiquid(context)
        ? LiquidGlass(borderRadius: const BorderRadius.vertical(top: Radius.circular(24)), child: content)
        : Material(color: colors.card, elevation: 4, child: content);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final top = DockedGlossyTopBar.contentTopInset(context);
    final songs = _songs;
    final current = _current;
    final Widget body;
    if (songs == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (songs.isEmpty) {
      body = ExplorerEmptyState(
        padding: EdgeInsets.fromLTRB(24, top + 24, 24, 24),
        icon: LucideIcons.music,
        title: 'No music found',
        description: 'Songs on this device show up here.',
      );
    } else {
      body = Stack(
        children: [
          ListView.builder(
            padding: EdgeInsets.fromLTRB(4, top + 8, 4, current == null ? 16 : 190),
            itemCount: songs.length,
            itemBuilder: (context, index) {
              final song = songs[index];
              final selected = index == current;
              return ListTile(
                selected: selected,
                selectedTileColor: colors.accent,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                leading: Icon(
                  selected && _playing ? LucideIcons.play : LucideIcons.music,
                  size: 20,
                  color: selected ? colors.primary : colors.mutedForeground,
                ),
                title: Text(song.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                subtitle: Text(
                  '${p.basename(p.dirname(song.path))} · ${EntityFormat.size(song.size)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
                onTap: () => _play(index),
              );
            },
          ),
          if (current != null)
            Positioned(left: 0, right: 0, bottom: 0, child: _controls(songs[current])),
        ],
      );
    }
    return ExplorerScaffold(title: 'Music player', body: body);
  }
}
