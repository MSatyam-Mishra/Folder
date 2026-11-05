import 'dart:async';
import 'dart:io';

import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folder/shared/widgets/explorer_scaffold.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

class AudioPlayerScreen extends StatefulWidget {
  final File audioFile;

  const AudioPlayerScreen({super.key, required this.audioFile});

  @override
  State<AudioPlayerScreen> createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends State<AudioPlayerScreen> {
  late AudioPlayer _player;
  bool _isPlaying = false;
  bool _loading = true;
  String? _error;
  int? _size;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    widget.audioFile.length().then((size) {
      if (mounted) setState(() => _size = size);
    }, onError: (Object _) {});
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      await _player.setFilePath(widget.audioFile.path);
      // Left the screen while loading: the player is already disposed.
      if (!mounted) return;
      setState(() {
        _duration = _player.duration ?? Duration.zero;
        _loading = false;
      });

      _subscriptions.add(_player.playerStateStream.listen((state) {
        if (mounted) {
          setState(() {
            _isPlaying = state.playing;
            // When finished, reset
            if (state.processingState == ProcessingState.completed) {
              _player.seek(Duration.zero);
              _player.pause();
            }
          });
        }
      }));

      _subscriptions.add(_player.positionStream.listen((pos) {
        if (mounted) {
          setState(() {
            _position = pos;
          });
        }
      }));

      // Auto play
      _player.play();
    } catch (e) {
      debugPrint('Error loading audio: $e');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$minutes:$seconds' : '$minutes:$seconds';
  }

  void _seekBy(Duration delta) {
    var target = _position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > _duration) target = _duration;
    _player.seek(target);
  }

  @override
  Widget build(BuildContext context) {
    final title = p.basename(widget.audioFile.path);
    final top = DockedGlossyTopBar.contentTopInset(context);
    final bottom = MediaQuery.paddingOf(context).bottom;

    Widget body;
    if (_error != null) {
      body = ViewerMessage(
        icon: LucideIcons.fileAudio,
        title: "Can't play this file",
        message: 'Its format may not be supported on this device.',
        details: _error,
      );
    } else {
      body = _playerView(context, title);
    }

    return ExplorerScaffold(
      title: title,
      body: Padding(
        padding: EdgeInsets.fromLTRB(24, top + 16, 24, bottom + 24),
        child: body,
      ),
    );
  }

  Widget _playerView(BuildContext context, String title) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final ext = p.extension(widget.audioFile.path).replaceFirst('.', '');
    final subtitle = [
      if (ext.isNotEmpty) ext.toUpperCase(),
      if (_size != null) filesize(_size, 1),
      if (_duration > Duration.zero) _formatDuration(_duration),
    ].join(' · ');
    final maxSeconds = _duration.inMilliseconds / 1000;
    final positionSeconds =
        (_position.inMilliseconds / 1000).clamp(0, maxSeconds).toDouble();
    final timeStyle = text.labelMedium?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Artwork shrinks on short (landscape) screens.
        final art = (constraints.maxHeight - 300).clamp(96.0, 280.0);
        return Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: art,
                    height: art,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: colors.border),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          colors.primary.withValues(alpha: 0.22),
                          colors.muted,
                        ],
                      ),
                    ),
                    child: Icon(
                      LucideIcons.music,
                      size: art * 0.32,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    p.basenameWithoutExtension(title),
                    textAlign: TextAlign.center,
                    style: text.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(subtitle, style: text.bodySmall),
                  ],
                  const SizedBox(height: 24),
                  ShadSliderTheme(
                    child: Slider(
                      value: positionSeconds,
                      min: 0,
                      max: maxSeconds <= 0 ? 1 : maxSeconds,
                      onChanged: _loading || maxSeconds <= 0
                          ? null
                          : (value) => _player.seek(
                                Duration(milliseconds: (value * 1000).round()),
                              ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(_position), style: timeStyle),
                        Text(_formatDuration(_duration), style: timeStyle),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _SkipButton(
                        forward: false,
                        onPressed: _loading
                            ? null
                            : () => _seekBy(const Duration(seconds: -10)),
                      ),
                      const SizedBox(width: 28),
                      _PlayButton(
                        playing: _isPlaying,
                        loading: _loading,
                        onPressed: () =>
                            _isPlaying ? _player.pause() : _player.play(),
                      ),
                      const SizedBox(width: 28),
                      _SkipButton(
                        forward: true,
                        onPressed: _loading
                            ? null
                            : () => _seekBy(const Duration(seconds: 10)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.loading,
    required this.onPressed,
  });

  final bool playing;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: playing ? 'Pause' : 'Play',
      child: Material(
        color: colors.primary,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: loading ? null : onPressed,
          child: SizedBox.square(
            dimension: 68,
            child: loading
                ? Padding(
                    padding: const EdgeInsets.all(22),
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: colors.primaryForeground,
                    ),
                  )
                : Icon(
                    playing ? LucideIcons.pause : LucideIcons.play,
                    size: 28,
                    color: colors.primaryForeground,
                  ),
          ),
        ),
      ),
    );
  }
}

/// 10-second skip: a circular arrow with "10" inside.
class _SkipButton extends StatelessWidget {
  const _SkipButton({required this.forward, required this.onPressed});

  final bool forward;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fg = onPressed == null ? colors.mutedForeground : colors.foreground;
    return IconButton(
      tooltip: forward ? 'Forward 10 seconds' : 'Back 10 seconds',
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: 52, height: 52),
      padding: EdgeInsets.zero,
      icon: Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            forward ? LucideIcons.rotateCw : LucideIcons.rotateCcw,
            size: 32,
            color: fg,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '10',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
