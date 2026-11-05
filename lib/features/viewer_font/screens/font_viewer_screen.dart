import 'dart:io';

import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/shared/layout/adaptive_layout.dart';
import 'package:folder/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folder/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Previews a TrueType/OpenType font: metadata, sample text at several sizes
/// and a glyph grid.
class FontViewerScreen extends StatefulWidget {
  const FontViewerScreen({super.key, required this.file});

  final File file;

  @override
  State<FontViewerScreen> createState() => _FontViewerScreenState();
}

class _FontViewerScreenState extends State<FontViewerScreen> {
  static int _loadCounter = 0;

  /// Fonts registered with the engine can't be unregistered, so reopening
  /// the same (unchanged) file reuses its family instead of loading another
  /// copy — which also makes reopening instant.
  static final Map<String, (String, Map<String, String>)> _registered = {};

  String? _family;
  Map<String, String> _info = const {};
  String? _error;
  final _sample = TextEditingController(
    text: 'The quick brown fox jumps over the lazy dog',
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _sample.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final stat = await widget.file.stat();
      final cacheKey =
          '${widget.file.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
      final cached = _registered[cacheKey];
      if (cached != null) {
        if (mounted) {
          setState(() {
            _family = cached.$1;
            _info = cached.$2;
          });
        }
        return;
      }
      final bytes = await widget.file.readAsBytes();
      // The name table is tiny: show it while the engine registers the font.
      final info = readFontNames(bytes);
      if (!mounted) return;
      setState(() => _info = info);
      final family = 'preview_font_${_loadCounter++}';
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _registered[cacheKey] = (family, info);
      if (!mounted) return;
      setState(() => _family = family);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _info['Full name'] ?? p.basename(widget.file.path);
    final top = DockedGlossyTopBar.contentTopInset(context);
    return ExplorerScaffold(
      title: title,
      body: _error != null
          ? ViewerMessage(
              icon: LucideIcons.fileX2,
              title: "This font couldn't be loaded",
              message: 'The file may be damaged or not a TrueType/OpenType '
                  'font.',
              details: _error,
              padding: EdgeInsets.fromLTRB(24, top + 24, 24, 24),
            )
          : _family == null
              ? Padding(
                  padding: EdgeInsets.only(top: top),
                  child: const ViewerLoading(label: 'Loading font…'),
                )
              : _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final style = TextStyle(fontFamily: _family, color: colors.foreground);
    const glyphs =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
        '!?@#\$%&*()[]{}<>/\\|+-=_.,:;\'"~^`€£¥©®™°±×÷¿¡ÀÉÎÕÜßæøñçΩπ';
    final details = {
      for (final e in _info.entries)
        if (e.key != 'Full name') e.key: e.value,
    };

    return ReadableWidth(
      maxWidth: 1000,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          DockedGlossyTopBar.contentTopInset(context) + 16,
          16,
          32 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          // Specimen: the font's own name, set in the font.
          SurfaceCard(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        _info['Full name'] ?? p.basenameWithoutExtension(
                          widget.file.path,
                        ),
                        style: style.copyWith(fontSize: 34, height: 1.15),
                      ),
                    ),
                    const SizedBox(width: 12),
                    StatusBadge(
                      p.extension(widget.file.path).replaceFirst('.', '')
                          .toUpperCase(),
                      outline: true,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Aa Bb Cc Dd Ee Ff Gg 0123456789',
                  style: style.copyWith(
                    fontSize: 18,
                    color: colors.mutedForeground,
                  ),
                ),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Divider(),
                  DetailList(entries: details.entries, labelWidth: 110),
                ] else
                  const SizedBox(height: 12),
              ],
            ),
          ),
          const SectionLabel('Preview'),
          TextField(
            controller: _sample,
            decoration: const InputDecoration(
              hintText: 'Type to preview',
              prefixIcon: Icon(LucideIcons.type, size: 16),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          for (final size in const [12.0, 16.0, 24.0, 36.0, 48.0, 72.0])
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text(
                        '${size.toInt()}',
                        style: text.labelMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        _sample.text,
                        style: style.copyWith(fontSize: size, height: 1.2),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          SectionLabel(
            'Glyphs',
            trailing: CountPill('${glyphs.runes.length}'),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              // Square cells that fill the row.
              const gap = 6.0;
              final columns = (constraints.maxWidth / 64).floor().clamp(4, 14);
              final cell =
                  (constraints.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final ch in glyphs.runes.map(String.fromCharCode))
                    Container(
                      width: cell,
                      height: cell,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colors.card,
                        border: Border.all(color: colors.border),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(ch, style: style.copyWith(fontSize: 24)),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
// Reads human-readable entries from an OpenType `name` table.
Map<String, String> readFontNames(Uint8List bytes) {
  const labels = {
    4: 'Full name',
    1: 'Family',
    2: 'Style',
    5: 'Version',
    9: 'Designer',
    8: 'Manufacturer',
    0: 'Copyright',
    13: 'License',
  };
  final result = <String, String>{};
  try {
    final data = ByteData.sublistView(bytes);
    final numTables = data.getUint16(4);
    int? nameOffset;
    for (var i = 0; i < numTables; i++) {
      final rec = 12 + i * 16;
      final tag = String.fromCharCodes(bytes.sublist(rec, rec + 4));
      if (tag == 'name') {
        nameOffset = data.getUint32(rec + 8);
        break;
      }
    }
    if (nameOffset == null) return result;
    final count = data.getUint16(nameOffset + 2);
    final storage = nameOffset + data.getUint16(nameOffset + 4);
    final found = <int, String>{};
    for (var i = 0; i < count; i++) {
      final rec = nameOffset + 6 + i * 12;
      final platform = data.getUint16(rec);
      final language = data.getUint16(rec + 4);
      final nameId = data.getUint16(rec + 6);
      final length = data.getUint16(rec + 8);
      final offset = storage + data.getUint16(rec + 10);
      if (!labels.containsKey(nameId) || offset + length > bytes.length) continue;
      String value;
      if (platform == 3 || platform == 0) {
        // Prefer English (0x409) Windows names; take others only if missing.
        if (platform == 3 && language != 0x409 && found.containsKey(nameId)) continue;
        final units = <int>[
          for (var j = 0; j + 1 < length; j += 2)
            data.getUint16(offset + j),
        ];
        value = String.fromCharCodes(units);
      } else if (platform == 1) {
        if (found.containsKey(nameId)) continue;
        value = String.fromCharCodes(bytes.sublist(offset, offset + length));
      } else {
        continue;
      }
      if (value.trim().isNotEmpty) found[nameId] = value.trim();
    }
    for (final id in labels.keys) {
      final v = found[id];
      if (v != null) result[labels[id]!] = v;
    }
  } catch (_) {
    // Malformed tables just mean no metadata.
  }
  return result;
}
