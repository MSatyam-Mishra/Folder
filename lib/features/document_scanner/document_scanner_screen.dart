import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/features/document_scanner/document_scanner.dart';
import 'package:folders/features/document_scanner/scan_document.dart';
import 'package:folders/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:shared_preferences/shared_preferences.dart';

/// The Toolbox's Document scanner (Android): scans with Google's scanner and
/// saves into a folder of the user's choice, Documents/Scans at first, as a
/// PDF or pictures. Both choices are remembered.
class DocumentScannerScreen extends StatefulWidget {
  const DocumentScannerScreen({super.key});

  static const folderKey = 'document_scanner_folder';
  static const formatKey = 'document_scanner_format';

  static String get defaultFolder => p.join(ExplorerPaths.userFolder, 'Documents', 'Scans');

  @override
  State<DocumentScannerScreen> createState() => _DocumentScannerScreenState();
}

class _DocumentScannerScreenState extends State<DocumentScannerScreen> {
  String _folder = DocumentScannerScreen.defaultFolder;
  ScanFormat _format = ScanFormat.pdf;
  bool? _available;
  bool _scanning = false;
  final _saved = <String>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final available = await DocumentScanner.available();
    if (!mounted) return;
    setState(() {
      _folder = prefs.getString(DocumentScannerScreen.folderKey) ?? _folder;
      _format = ScanFormat.values.asNameMap()[prefs.getString(DocumentScannerScreen.formatKey)] ?? _format;
      _available = available;
    });
  }

  Future<void> _chooseFolder() async {
    final folder = await FilePicker.platform.getDirectoryPath(initialDirectory: _folder);
    if (folder == null || !mounted) return;
    setState(() => _folder = folder);
    await (await SharedPreferences.getInstance()).setString(DocumentScannerScreen.folderKey, folder);
  }

  Future<void> _setFormat(ScanFormat format) async {
    setState(() => _format = format);
    await (await SharedPreferences.getInstance()).setString(DocumentScannerScreen.formatKey, format.name);
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      await Directory(_folder).create(recursive: true);
    } on FileSystemException {
      // Said when saving fails.
    }
    if (!mounted) return;
    final saved = await scanAndSave(context, _folder, _format);
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _saved.insertAll(0, saved);
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final Widget body;
    if (_available == false) {
      body = const ExplorerEmptyState(
        icon: LucideIcons.scanLine,
        title: 'No scanner on this phone',
        description: "The scanner comes with Google Play services, which this phone doesn't have.",
      );
    } else {
      body = ListView(
        padding: EdgeInsets.fromLTRB(20, DockedGlossyTopBar.contentTopInset(context) + 24, 20, 24),
        children: [
          Text(
            'Point the camera at a page: the scanner finds its edges, straightens it and cleans it up. '
            'You can add more pages, or pick photos you already have.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 20),
          Text('Save in', style: text.labelMedium),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _chooseFolder,
            icon: const Icon(LucideIcons.folderOpen, size: 16),
            label: Align(
              alignment: Alignment.centerLeft,
              child: Text(_folder, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ),
          const SizedBox(height: 16),
          Text('Save as', style: text.labelMedium),
          const SizedBox(height: 8),
          SegmentedButton<ScanFormat>(
            segments: const [
              ButtonSegment(value: ScanFormat.pdf, icon: Icon(LucideIcons.fileText, size: 16), label: Text('PDF')),
              ButtonSegment(value: ScanFormat.jpeg, icon: Icon(LucideIcons.images, size: 16), label: Text('Pictures')),
            ],
            selected: {_format},
            showSelectedIcon: false,
            onSelectionChanged: (chosen) => _setFormat(chosen.single),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _scanning || _available == null ? null : _scan,
            icon: const Icon(LucideIcons.scanLine, size: 18),
            label: const Text('Scan'),
          ),
          if (_saved.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('Saved', style: text.labelMedium),
            for (final path in _saved)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(path.endsWith('.pdf') ? LucideIcons.fileText : LucideIcons.fileImage, color: colors.primary),
                title: Text(p.basename(path)),
                onTap: () => FileOpener.open(context, File(path)),
              ),
          ],
        ],
      );
    }
    return ExplorerScaffold(title: 'Document scanner', body: body);
  }
}
