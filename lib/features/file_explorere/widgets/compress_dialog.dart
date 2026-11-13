import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/compress/archive_sink.dart';
import 'package:folders/core/services/compress/compress_job.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/theme/app_style.dart';
import 'package:folders/shared/ui/app_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// What the Compress dialog chose: the archive's name and how to make it.
class CompressChoice {
  const CompressChoice(this.name, this.options);

  /// With the kind's extension.
  final String name;
  final CompressOptions options;
}

/// Sizes to split an archive into, the last asking for one.
enum VolumeChoice {
  none('Don\'t split', null, LucideIcons.fileArchive),
  mb100('100 MB', 100 * 1000 * 1000, LucideIcons.fileStack),
  mb700('700 MB (a CD)', 700 * 1000 * 1000, LucideIcons.disc3),
  gb4('4 GB (a FAT32 drive)', 4000 * 1000 * 1000, LucideIcons.usb),
  custom('Other size…', null, LucideIcons.ruler);

  const VolumeChoice(this.label, this.bytes, this.icon);

  final String label;
  final int? bytes;
  final IconData icon;
}

/// Compress: the archive's name, its kind (ZIP, 7z, TAR, TAR.GZ, TAR.XZ,
/// TAR.BZ2), how hard to compress, a password (ZIP and 7z; 7z can hide the
/// names too), and parts to split it into. A dialog on computers, a sheet on
/// phones.
class CompressDialog extends StatefulWidget {
  const CompressDialog({super.key, required this.initialName, required this.count});

  /// The name to start from, without an extension.
  final String initialName;

  /// How many items are being compressed.
  final int count;

  static Future<CompressChoice?> show(BuildContext context, {required String initialName, required int count}) =>
      AppSheet.show<CompressChoice>(
        context,
        child: CompressDialog(initialName: initialName, count: count),
      );

  @override
  State<CompressDialog> createState() => _CompressDialogState();
}

class _CompressDialogState extends State<CompressDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  final _password = TextEditingController();
  final _customSize = TextEditingController(text: '1');
  var _kind = ArchiveKind.zip;
  var _level = CompressLevel.normal;
  var _showPassword = false;
  var _encryptNames = true;
  var _volumes = VolumeChoice.none;
  var _customGb = true;

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _customSize.dispose();
    super.dispose();
  }

  static IconData _levelIcon(CompressLevel level) => switch (level) {
        CompressLevel.store => LucideIcons.box,
        CompressLevel.fast => LucideIcons.zap,
        CompressLevel.normal => LucideIcons.gauge,
        CompressLevel.best => LucideIcons.shrink,
      };

  static IconData _kindIcon(ArchiveKind kind) => switch (kind) {
        ArchiveKind.zip => LucideIcons.fileArchive,
        ArchiveKind.sevenZip => LucideIcons.package,
        _ => LucideIcons.archive,
      };

  /// What the level means for this kind, in a line.
  String? get _levelNote => switch (_kind) {
        ArchiveKind.tar => "A TAR keeps files together but doesn't make them smaller.",
        ArchiveKind.tarBz2 => 'bzip2 has a single level.',
        ArchiveKind.sevenZip when _level == CompressLevel.fast => 'Fast uses Deflate: much quicker, a little bigger.',
        ArchiveKind.sevenZip || ArchiveKind.tarXz when _level != CompressLevel.store =>
          'LZMA2 makes the smallest files, but takes its time.',
        _ => null,
      };

  String? get _passwordNote => switch (_kind) {
        ArchiveKind.zip => "AES-256. 7-Zip, WinRAR and macOS open it; Windows' own ZIP folders can't.",
        ArchiveKind.sevenZip => 'AES-256. Windows opens 7z files, but not with a password: use 7-Zip or WinRAR.',
        _ => 'Only ZIP and 7z can have a password.',
      };

  int? get _volumeSize {
    if (_volumes != VolumeChoice.custom) return _volumes.bytes;
    final value = double.tryParse(_customSize.text.replaceAll(',', '.'));
    if (value == null || value <= 0) return null;
    return (value * (_customGb ? 1000 * 1000 * 1000 : 1000 * 1000)).round();
  }

  String? get _problem {
    final name = _name.text.trim();
    if (name.isEmpty) return 'Give the archive a name';
    if (RegExp(r'[\\/:*?"<>|]').hasMatch(name)) return 'A name can\'t have \\ / : * ? " < > |';
    if (_volumes == VolumeChoice.custom) {
      final size = _volumeSize;
      if (size == null) return 'Give the size of each part';
      if (size < ArchiveSink.minVolume) return 'Parts must be at least 64 KB';
    }
    return null;
  }

  void _setKind(ArchiveKind kind) => setState(() {
        _kind = kind;
        final levels = kind.levels;
        if (levels.isNotEmpty && !levels.contains(_level)) _level = CompressLevel.normal;
      });

  void _submit() {
    if (_problem != null) return;
    final password = _kind.canEncrypt && _password.text.isNotEmpty ? _password.text : null;
    Navigator.pop(
      context,
      CompressChoice(
        _kind.nameFor(_name.text.trim()),
        CompressOptions(
          kind: _kind,
          level: _kind.levels.isEmpty ? CompressLevel.normal : _level,
          password: password,
          encryptNames: password != null && _kind == ArchiveKind.sevenZip && _encryptNames,
          volumeSize: _volumeSize,
        ),
      ),
    );
  }

  Widget _label(String text, IconData icon) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 15, color: context.look.iconColor(icon, colors.mutedForeground)),
          const SizedBox(width: 8),
          Text(text, style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
  }

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      );

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final problem = _problem;
    final levels = _kind.levels;
    final levelNote = _levelNote;
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(LucideIcons.fileArchive, size: 20, color: context.look.iconColor(LucideIcons.fileArchive, colors.primary)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.count == 1 ? 'Compress' : 'Compress ${widget.count} items',
                  style: text.titleLarge,
                ),
              ),
            ],
          ),
          _label('Name', LucideIcons.pencil),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(suffixText: '.${_kind.extension}'),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          _label('Format', LucideIcons.archive),
          DropdownButtonFormField<ArchiveKind>(
            initialValue: _kind,
            isExpanded: true,
            items: [
              for (final kind in ArchiveKind.values)
                DropdownMenuItem(
                  value: kind,
                  child: Row(
                    children: [
                      Icon(_kindIcon(kind), size: 16, color: context.look.iconColor(_kindIcon(kind), colors.mutedForeground)),
                      const SizedBox(width: 10),
                      Text(kind.label),
                    ],
                  ),
                ),
            ],
            onChanged: (kind) {
              if (kind != null) _setKind(kind);
            },
          ),
          _label('Compression', LucideIcons.gauge),
          if (levels.isNotEmpty)
            SegmentedButton<CompressLevel>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                for (final level in levels)
                  ButtonSegment(value: level, icon: Icon(_levelIcon(level), size: 15), label: Text(level.label)),
              ],
              selected: {_level},
              onSelectionChanged: (chosen) => setState(() => _level = chosen.first),
            ),
          if (levelNote != null) _note(levelNote),
          _label('Password', LucideIcons.lockKeyhole),
          TextField(
            controller: _password,
            enabled: _kind.canEncrypt,
            obscureText: !_showPassword,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: _kind.canEncrypt ? 'None' : null,
              suffixIcon: _kind.canEncrypt
                  ? IconButton(
                      tooltip: _showPassword ? 'Hide password' : 'Show password',
                      icon: Icon(_showPassword ? LucideIcons.eyeOff : LucideIcons.eye, size: 18),
                      onPressed: () => setState(() => _showPassword = !_showPassword),
                    )
                  : null,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          if (_passwordNote case final note?) _note(note),
          if (_kind == ArchiveKind.sevenZip && _password.text.isNotEmpty)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _encryptNames,
              onChanged: (value) => setState(() => _encryptNames = value ?? false),
              secondary: Icon(LucideIcons.eyeOff, size: 18, color: colors.mutedForeground),
              title: const Text('Encrypt file names'),
              subtitle: const Text('Nobody sees what\'s inside without the password.'),
            ),
          _label('Split into parts', LucideIcons.scissors),
          DropdownButtonFormField<VolumeChoice>(
            initialValue: _volumes,
            isExpanded: true,
            items: [
              for (final choice in VolumeChoice.values)
                DropdownMenuItem(
                  value: choice,
                  child: Row(
                    children: [
                      Icon(choice.icon, size: 16, color: context.look.iconColor(choice.icon, colors.mutedForeground)),
                      const SizedBox(width: 10),
                      Flexible(child: Text(choice.label, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
                ),
            ],
            onChanged: (choice) {
              if (choice != null) setState(() => _volumes = choice);
            },
          ),
          if (_volumes == VolumeChoice.custom)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _customSize,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                      decoration: const InputDecoration(labelText: 'Each part'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: const [
                      ButtonSegment(value: false, label: Text('MB')),
                      ButtonSegment(value: true, label: Text('GB')),
                    ],
                    selected: {_customGb},
                    onSelectionChanged: (chosen) => setState(() => _customGb = chosen.first),
                  ),
                ],
              ),
            ),
          if (_volumes != VolumeChoice.none)
            _note('Parts are numbered .001, .002…; open the first one in 7-Zip or here to get everything back.'),
          if (problem != null && _name.text.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(problem, style: text.bodySmall?.copyWith(color: colors.destructive)),
          ],
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: problem == null ? _submit : null,
                icon: const Icon(LucideIcons.fileArchive, size: 16),
                label: const Text('Compress'),
              ),
            ],
          ),
        ],
    );
  }
}

/// Compressing from the browser: the quick ZIP and Compress….
abstract final class CompressActions {
  /// Where an archive of [paths] goes when they're shown in [folder]: there,
  /// or beside the first item when [folder] isn't a real one (a category).
  static String destinationFolder(String folder, List<String> paths) =>
      ExplorerPaths.isVirtual(folder) || RemotePaths.isRemote(folder) ? p.dirname(paths.first) : folder;

  /// The name an archive of [paths] starts with: one item's own, or the
  /// folder they're in.
  static String suggestedName(List<String> paths, String folder) {
    if (paths.length == 1) {
      final name = p.basename(paths.single);
      final isFile = FileSystemEntity.typeSync(paths.single) == FileSystemEntityType.file;
      return isFile && p.extension(name).isNotEmpty ? p.basenameWithoutExtension(name) : name;
    }
    final name = ExplorerPaths.isVirtual(folder) ? '' : p.basename(folder);
    return name.isEmpty ? 'Archive' : name;
  }

  /// Asks how, then compresses [paths] in the background; [onDone] runs
  /// once the archive is made.
  static Future<void> compressWith(
    BuildContext context,
    List<String> paths,
    String folder, {
    VoidCallback? onDone,
  }) async {
    if (!_canCompress(context, paths)) return;
    final choice = await CompressDialog.show(context, initialName: suggestedName(paths, folder), count: paths.length);
    if (choice == null || !context.mounted) return;
    _start(context, paths, folder, choice.name, choice.options, onDone: onDone);
  }

  /// "Compress to ZIP": the name is the only question.
  static void compressToZip(BuildContext context, List<String> paths, String folder, String name,
      {VoidCallback? onDone}) {
    if (!_canCompress(context, paths)) return;
    _start(context, paths, folder, ArchiveKind.zip.nameFor(name), const CompressOptions(), onDone: onDone);
  }

  static bool _canCompress(BuildContext context, List<String> paths) {
    if (paths.isEmpty) return false;
    if (paths.any((path) => RemotePaths.isRemote(path) || !ExplorerPaths.isOnDisk(path))) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Only files on this device can be compressed')),
      );
      return false;
    }
    return true;
  }

  static void _start(BuildContext context, List<String> paths, String folder, String name, CompressOptions options,
      {VoidCallback? onDone}) {
    final destination = CompressJob.freePath(
      destinationFolder(folder, paths),
      name,
      split: options.volumeSize != null,
    );
    CompressTask.start(paths, destination, options, onDone: (result) {
      if (result != null) onDone?.call();
    });
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Compressing to ${p.basename(destination)} in the background')),
    );
  }
}
