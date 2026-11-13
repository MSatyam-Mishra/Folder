import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/files/file_types.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/shared/file_icons/file_thumbnail.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// A quick look at [file] over the blurred page, without opening it: a tap
/// outside closes it, as does Back.
Future<void> showFilePeek(
  BuildContext context,
  File file, {
  required VoidCallback onOpen,
  VoidCallback? onShare,
}) {
  HapticFeedback.mediumImpact();
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.25),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (peek, _, _) => FilePeek(
      file: file,
      onOpen: () {
        Navigator.pop(peek);
        onOpen();
      },
      onShare: onShare == null
          ? null
          : () {
              Navigator.pop(peek);
              onShare();
            },
    ),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn);
      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: Tween(begin: 0.88, end: 1.0).animate(curved), child: child),
      );
    },
  );
}

class FilePeek extends StatelessWidget {
  const FilePeek({super.key, required this.file, required this.onOpen, this.onShare});

  final File file;
  final VoidCallback onOpen;
  final VoidCallback? onShare;

  /// Text kinds show their first lines rather than an icon.
  static bool _isText(FileKind kind) => const {
        FileKind.text,
        FileKind.code,
        FileKind.json,
        FileKind.markdown,
      }.contains(kind);

  Widget _preview(BuildContext context, double room) {
    final kind = FileTypes.kindOf(file.path);
    final fallback = EntityIcon(entity: file, size: 96);
    if (kind == FileKind.image || kind == FileKind.rasterImage) {
      return Image.file(
        file,
        fit: BoxFit.contain,
        cacheWidth: 1400,
        errorBuilder: (_, _, _) => Center(child: fallback),
      );
    }
    if (_isText(kind)) return _TextPeek(file: file);
    final thumbnail = Center(child: FileThumbnail(path: file.path, size: room, fallback: fallback));
    if (kind != FileKind.video) return thumbnail;
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(child: thumbnail),
        const DecoratedBox(
          decoration: BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
          child: Padding(padding: EdgeInsets.all(14), child: Icon(LucideIcons.play, color: Colors.white, size: 28)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 48).clamp(0.0, 520.0);
    final height = (size.height * 0.5).clamp(160.0, 520.0);
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
      child: Stack(
        children: [
          // Anywhere around the card closes it, also where the blur covers
          // the barrier.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.maybePop(context),
            ),
          ),
          Center(
            child: Material(
              color: colors.card,
              elevation: 12,
              shadowColor: Colors.black54,
              clipBehavior: Clip.antiAlias,
              borderRadius: BorderRadius.circular(20),
              child: SizedBox(
                width: width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(height: height, child: _preview(context, height)),
                    Divider(height: 1, color: colors.border),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  ExplorerPaths.displayNameForEntity(file.path),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                                ),
                                const SizedBox(height: 2),
                                EntityStatBuilder(
                                  entity: file,
                                  builder: (context, stat) => Text(
                                    stat == null ? ' ' : EntityFormat.summary(file, stat),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: text.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (onShare != null)
                            IconButton(tooltip: 'Share', icon: const Icon(LucideIcons.share2, size: 20), onPressed: onShare),
                          IconButton(tooltip: 'Open', icon: const Icon(LucideIcons.externalLink, size: 20), onPressed: onOpen),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The first lines of a text file.
class _TextPeek extends StatefulWidget {
  const _TextPeek({required this.file});

  final File file;

  @override
  State<_TextPeek> createState() => _TextPeekState();
}

class _TextPeekState extends State<_TextPeek> {
  static const _bytes = 8 * 1024;
  String? _text;

  Future<void> _load() async {
    var text = '';
    try {
      final bytes = await widget.file.openRead(0, _bytes).fold<List<int>>([], (all, part) => all..addAll(part));
      text = utf8.decode(bytes, allowMalformed: true);
    } on FileSystemException {
      // Nothing to show of it.
    }
    if (mounted) setState(() => _text = text);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    if (text == null) return const SizedBox.shrink();
    if (text.trim().isEmpty) {
      return Center(child: Text('This file is empty', style: Theme.of(context).textTheme.bodySmall));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Text(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4)),
    );
  }
}
