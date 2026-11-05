import 'dart:io';
import 'dart:isolate';

import 'package:folder/core/services/new_files.dart';
import 'package:folder/features/viewer_office/common/viewer_ui.dart';
import 'package:folder/shared/layout/adaptive_layout.dart';
import 'package:folder/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folder/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import '../controller/spreadsheet_controller.dart';
import '../model/workbook.dart';
import '../readers/csv_codec.dart';
import '../readers/workbook_loader.dart';
import '../widgets/find_bar.dart';
import '../widgets/format_toolbar.dart';
import '../widgets/formula_bar.dart';
import '../widgets/grid_colors.dart';
import '../widgets/sheet_grid.dart';
import '../widgets/sheet_tabs.dart';
import '../widgets/side_panel.dart';
import '../widgets/status_bar.dart';
import '../widgets/text_prompt.dart';
import '../writers/xlsx_writer.dart';

/// Spreadsheet viewer/editor for .xlsx/.xlsm/.xltx/.xltm, .xls/.xlt,
/// .csv/.tsv/.tab/.psv and .ods/.ots files.
///
/// Pops with `true` when a new file was written next to the original (so the
/// explorer refreshes).
class SpreadsheetScreen extends StatefulWidget {
  const SpreadsheetScreen({super.key, required this.file});

  final File file;

  @override
  State<SpreadsheetScreen> createState() => _SpreadsheetScreenState();
}

enum _Menu {
  find,
  replace,
  goTo,
  freezeHere,
  freezeTopRow,
  freezeFirstColumn,
  unfreeze,
  sortAsc,
  sortDesc,
  insertRow,
  insertColumn,
  deleteRow,
  deleteColumn,
  fillDown,
  recalc,
  delimiter,
  header,
  saveCopy,
  exportCsv,
  openWith,
}

enum _CellMenu {
  cut,
  copy,
  paste,
  clear,
  clearAll,
  insertRowAbove,
  insertRowBelow,
  insertColLeft,
  insertColRight,
  deleteRows,
  deleteCols,
  fillDown,
  fillRight,
  sortAsc,
  sortDesc,
  merge,
  unmerge,
  freezeHere,
}

enum _TabMenu { rename, duplicate, moveLeft, moveRight, hide, unhide, delete }

class _SpreadsheetScreenState extends State<SpreadsheetScreen> {
  late File _file;
  SpreadsheetController? _ctrl;

  /// Original package bytes (xlsx family) used to keep unknown parts.
  Uint8List? _packageBytes;
  bool _loading = true;
  String? _error;
  bool _saving = false;
  bool _createdNewFile = false;
  bool _csvLossAccepted = false;
  bool _findOpen = false;
  bool _replaceMode = false;
  int _findKey = 0;

  final _gridFocus = FocusNode(debugLabel: 'sheet-grid');
  final _editorFocus = FocusNode(debugLabel: 'sheet-cell-editor');
  final _formulaFocus = FocusNode(debugLabel: 'sheet-formula-bar');

  @override
  void initState() {
    super.initState();
    _file = widget.file;
    _formulaFocus.addListener(_onFormulaFocus);
    _load();
  }

  @override
  void dispose() {
    _formulaFocus.removeListener(_onFormulaFocus);
    _gridFocus.dispose();
    _editorFocus.dispose();
    _formulaFocus.dispose();
    _ctrl?.removeListener(_onControllerChanged);
    _ctrl?.dispose();
    super.dispose();
  }

  bool _lastDirty = false;

  /// Rebuilds the screen only when the title's "unsaved" marker changes.
  void _onControllerChanged() {
    final d = _ctrl?.dirty ?? false;
    if (d != _lastDirty && mounted) {
      setState(() => _lastDirty = d);
    }
  }

  void _onFormulaFocus() {
    final c = _ctrl;
    if (c == null || !_formulaFocus.hasFocus) return;
    if (!c.editing) {
      c.beginEdit(origin: EditOrigin.formulaBar);
    } else if (c.editOrigin != EditOrigin.formulaBar) {
      c.beginEdit(origin: EditOrigin.formulaBar);
    }
  }

  String get _fileName => p.basename(_file.path);

  // ---------------------------------------------------------------------------
  // Loading

  /// Files at least this big first show their first rows (read-only) while
  /// the whole file is read in the background.
  static const _previewMinBytes = 1024 * 1024;

  /// Identifies the current load so results of a superseded one are dropped.
  int _loadGen = 0;

  /// True while [_ctrl] is a read-only preview of the file being loaded.
  bool _previewing = false;

  Future<void> _load({CsvLoadOptions? csv}) async {
    final gen = ++_loadGen;
    if (!_loading || _error != null || _previewing) {
      setState(() {
        _loading = true;
        _previewing = false;
        _error = null;
      });
    }
    try {
      final bytes = await _file.readAsBytes();
      if (!mounted || gen != _loadGen) return;
      final name = _fileName;
      final full = _parseInBackground(bytes, name, csv);
      if (bytes.length >= _previewMinBytes) {
        // Runs in parallel; ignored if the full workbook is ready first.
        _previewInBackground(bytes, name, csv).then((wb) {
          if (wb != null && mounted && gen == _loadGen && _loading) _showPreview(wb);
        }, onError: (Object _) {});
      }
      final wb = await full;
      if (!mounted || gen != _loadGen) return;
      _install(wb, bytes);
    } on SpreadsheetReadException catch (e) {
      _failLoad(gen, e.message);
    } on FileSystemException {
      _failLoad(gen, 'This file can\'t be read. Check that it still exists and that the app may access it.');
    } catch (_) {
      _failLoad(gen, 'This file couldn\'t be opened. It may be damaged or in a format that isn\'t supported.');
    }
  }

  void _failLoad(int gen, String message) {
    if (!mounted || gen != _loadGen) return;
    setState(() {
      _loading = false;
      _previewing = false;
      _error = message;
    });
  }

  void _replaceController(SpreadsheetController next) {
    final old = _ctrl;
    old?.removeListener(_onControllerChanged);
    next.addListener(_onControllerChanged);
    _ctrl = next;
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  void _showPreview(Workbook wb) {
    final next = SpreadsheetController(wb)
      ..readOnly = true
      ..onReadOnly = () => _toast('Still opening the file. You can edit in a moment.');
    setState(() {
      _replaceController(next);
      _previewing = true;
      _lastDirty = false;
    });
  }

  void _install(Workbook wb, Uint8List bytes) {
    final preview = _previewing ? _ctrl : null;
    final next = SpreadsheetController(wb);
    if (preview != null) next.adoptViewFrom(preview);
    _lastDirty = false;
    setState(() {
      _replaceController(next);
      _packageBytes = wb.format.isXlsxFamily ? bytes : null;
      _loading = false;
      _previewing = false;
      // Matches found in the preview point at its (discarded) sheets.
      if (preview != null) _findOpen = false;
    });
    if (wb.warnings.isNotEmpty) _toast(wb.warnings.first);
    if (preview == null || !_formulaFocus.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _gridFocus.requestFocus();
      });
    }
  }

  /// False (with a message) while the file is still being read.
  bool _readyToSave() {
    if (!_loading) return true;
    _toast('Still opening the file. Try again in a moment.');
    return false;
  }

  // ---------------------------------------------------------------------------
  // Messages

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
  }

  Future<bool> _confirm(String title, String message, String action, {bool destructive = false}) =>
      showViewerConfirm(
        context,
        title: title,
        message: message,
        confirmLabel: action,
        destructive: destructive,
      );

  // ---------------------------------------------------------------------------
  // Saving

  bool _commitPending() {
    final c = _ctrl;
    if (c == null || !c.editing) return true;
    final err = c.commitEdit();
    if (err != null) {
      _toast(err);
      return false;
    }
    return true;
  }

  Future<File> _uniqueFile(String dir, String base, String ext) async {
    var f = File(p.join(dir, '$base$ext'));
    var n = 1;
    while (await f.exists()) {
      f = File(p.join(dir, '$base ($n)$ext'));
      n++;
    }
    return f;
  }

  Future<void> _writeBytes(File target, Uint8List bytes) async {
    final tmp = File('${target.path}.saving~');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      await target.writeAsBytes(bytes, flush: true);
    }
  }

  /// Points each sheet at its part in the package just written. [saved] is
  /// the sheet list and names as they were when the save started (edits made
  /// while it ran aren't in the file, so they must not be marked as saved).
  void _syncAfterXlsxSave(SpreadsheetController c, XlsxWriteResult result,
      List<(SheetData, String)> saved, int serial) {
    if (result.sheetPaths.length != saved.length) return;
    final unchanged = c.editSerial == serial;
    for (var i = 0; i < saved.length; i++) {
      final (sheet, name) = saved[i];
      sheet
        ..sourcePath = result.sheetPaths[i]
        ..sourceIndex = i
        ..sourceName = name;
      if (unchanged) sheet.structureChanged = false;
    }
  }

  List<(SheetData, String)> _sheetSnapshot(SpreadsheetController c) =>
      [for (final s in c.workbook.sheets) (s, s.name)];

  Future<XlsxWriteResult> _buildXlsx(SpreadsheetController c, SpreadsheetFormat target) =>
      _writeXlsxInBackground(c.workbook, _packageBytes, target);

  /// A new file gets its name now; everything saved goes beside it.
  Future<bool> _nameIfNew() async {
    final named = await UntitledFiles.saveTarget(context, _file);
    if (named == null || !mounted) return false;
    _file = named;
    return true;
  }

  /// Save (Ctrl+S): overwrite when possible, otherwise "Save as .xlsx".
  Future<bool> _save() async {
    final c = _ctrl;
    if (c == null || _saving || !_readyToSave()) return false;
    if (!_commitPending()) return false;
    if (!await _nameIfNew()) return false;
    final fmt = c.workbook.format;
    if (fmt.isXlsxFamily) return _overwriteXlsx(c);
    if (fmt == SpreadsheetFormat.csv) return _saveCsv(c);
    return _saveAsXlsx(c, switchToNew: true);
  }

  Future<bool> _overwriteXlsx(SpreadsheetController c) async {
    setState(() => _saving = true);
    try {
      final serial = c.editSerial;
      final saved = _sheetSnapshot(c);
      final result = await _buildXlsx(c, c.workbook.format);
      await _writeBytes(_file, result.bytes);
      if (!mounted) return true;
      _packageBytes = result.bytes;
      _syncAfterXlsxSave(c, result, saved, serial);
      c.markSaved(atSerial: serial);
      setState(() {});
      _toast(c.dirty ? 'Saved. Changes made while saving aren\'t saved yet.' : 'Saved');
      return true;
    } catch (e) {
      _toast('Couldn\'t save: ${_describe(e)}');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _saveAsXlsx(SpreadsheetController c, {required bool switchToNew}) async {
    if (!_readyToSave() || !_commitPending()) return false;
    setState(() => _saving = true);
    try {
      final dir = p.dirname(_file.path);
      final base = p.basenameWithoutExtension(_file.path);
      final target = await _uniqueFile(dir, base, '.xlsx');
      final serial = c.editSerial;
      final saved = _sheetSnapshot(c);
      final result = await _buildXlsx(c, SpreadsheetFormat.xlsx);
      await _writeBytes(target, result.bytes);
      if (!mounted) return true;
      _createdNewFile = true;
      if (switchToNew) {
        _file = target;
        _packageBytes = result.bytes;
        c.workbook.format = SpreadsheetFormat.xlsx;
        c.workbook.csv = null;
        _syncAfterXlsxSave(c, result, saved, serial);
        c.markSaved(atSerial: serial);
      }
      setState(() {});
      _toast('Saved as ${p.basename(target.path)}');
      return true;
    } catch (e) {
      _toast('Couldn\'t save: ${_describe(e)}');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _saveCsv(SpreadsheetController c, {File? target}) async {
    final wb = c.workbook;
    final csv = wb.csv ?? CsvSettings();
    final sheet = c.sheet;
    if (target == null && !_csvLossAccepted) {
      final hasFormulas = sheet.cells.values.any((x) => x.formula != null);
      final hasStyles = sheet.cells.values.any((x) => !x.style.isDefaultLook && x.style.numFmt == 'General');
      if (wb.sheets.length > 1 || hasFormulas || hasStyles) {
        final choice = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Save as delimited text?'),
            content: Text(
              '${wb.sheets.length > 1 ? 'Only the sheet "${sheet.name}" is saved. ' : ''}'
              'Formulas are saved as their results and formatting is lost.',
            ),
            actions: [
              OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              OutlinedButton(onPressed: () => Navigator.pop(context, 'xlsx'), child: const Text('Save as .xlsx')),
              FilledButton(onPressed: () => Navigator.pop(context, 'csv'), child: const Text('Save')),
            ],
          ),
        );
        if (!mounted || choice == null) return false;
        if (choice == 'xlsx') return _saveAsXlsx(c, switchToNew: true);
        _csvLossAccepted = true;
      }
    }
    setState(() => _saving = true);
    try {
      final delimiter = csv.delimiter;
      final newline = csv.newline;
      final date1904 = wb.date1904;
      final encoding = target == null ? csv.encoding : TextEncodingKind.utf8Bom;
      final serial = c.editSerial;
      final bytes = await _writeCsvInBackground(sheet, delimiter, newline, date1904, encoding);
      await _writeBytes(target ?? _file, bytes);
      if (!mounted) return true;
      if (target == null) {
        c.markSaved(atSerial: serial);
        _toast(c.dirty ? 'Saved. Changes made while saving aren\'t saved yet.' : 'Saved');
      } else {
        _createdNewFile = true;
        _toast('Exported ${p.basename(target.path)}');
      }
      setState(() {});
      return true;
    } catch (e) {
      _toast('Couldn\'t save: ${_describe(e)}');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _exportCsv() async {
    final c = _ctrl;
    if (c == null || !_readyToSave() || !_commitPending()) return;
    final dir = p.dirname(_file.path);
    final base = p.basenameWithoutExtension(_file.path);
    final name = c.workbook.sheets.length > 1 ? '$base - ${c.sheet.name}' : base;
    final target = await _uniqueFile(dir, name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'), '.csv');
    if (!mounted) return;
    await _saveCsv(c, target: target);
  }

  String _describe(Object e) {
    if (e is FileSystemException) {
      final os = e.osError?.message;
      return os == null || os.isEmpty ? 'the file couldn\'t be written' : os;
    }
    return 'something went wrong';
  }

  // ---------------------------------------------------------------------------
  // Leaving

  Future<void> _onPop() async {
    final c = _ctrl;
    if (c != null && c.editing) {
      if (c.commitEdit() != null) c.cancelEdit();
    }
    if (c != null && c.dirty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Unsaved changes'),
          content: Text('Save your changes to "$_fileName"?'),
          actions: [
            TextButton(
              style: TextButton.styleFrom(foregroundColor: context.colors.destructive),
              onPressed: () => Navigator.pop(context, 'discard'),
              child: const Text('Discard'),
            ),
            OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('Save')),
          ],
        ),
      );
      if (!mounted || choice == null) return;
      if (choice == 'save') {
        final ok = await _save();
        if (!ok || !mounted) return;
        if (c.dirty) return;
      }
    }
    if (mounted) Navigator.of(context).pop(_createdNewFile ? true : null);
  }

  // ---------------------------------------------------------------------------
  // Commands

  KeyEventResult _onScreenKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isControlPressed || hw.isMetaPressed;
    if (!ctrl) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.keyS) {
      _save();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.keyF) {
      _openFind(replace: false);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.keyH) {
      _openFind(replace: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _openFind({required bool replace}) {
    setState(() {
      if (!_findOpen) _findKey++;
      _findOpen = true;
      _replaceMode = replace;
    });
  }

  void _closeFind() {
    setState(() => _findOpen = false);
    _gridFocus.requestFocus();
  }

  void _commit(int dr, int dc) {
    final c = _ctrl;
    if (c == null) return;
    final err = c.commitEdit(dr: dr, dc: dc);
    if (err != null) {
      _toast(err);
    } else {
      _gridFocus.requestFocus();
    }
  }

  void _cancelEdit() {
    _ctrl?.cancelEdit();
    _gridFocus.requestFocus();
  }

  Future<void> _goTo() async {
    final c = _ctrl;
    if (c == null) return;
    final text = await showTextPrompt(
      context,
      title: 'Go to',
      initial: c.selectionLabel.contains('R x') ? cellName(c.selRow, c.selCol) : c.selectionLabel,
      label: 'Cell or range',
      helper: 'e.g. B12, A1:C10 or Sheet2!A1',
      action: 'Go',
      validate: (v) => _parseGoTo(c, v) == null ? 'Enter a cell like B12 or Sheet2!A1' : null,
    );
    if (text == null || !mounted) return;
    final target = _parseGoTo(c, text);
    if (target == null) return;
    if (target.$1 != c.activeIndex) c.activateSheet(target.$1);
    final r = target.$2;
    if (r.isSingle) {
      c.select(r.r1, r.c1);
    } else {
      c.selectRange(r, reveal: true);
    }
    _gridFocus.requestFocus();
  }

  (int, CellRange)? _parseGoTo(SpreadsheetController c, String text) {
    var t = text.trim();
    var sheetIndex = c.activeIndex;
    final bang = t.lastIndexOf('!');
    if (bang > 0) {
      var name = t.substring(0, bang);
      if (name.startsWith("'") && name.endsWith("'") && name.length >= 2) {
        name = name.substring(1, name.length - 1).replaceAll("''", "'");
      }
      sheetIndex = c.workbook.indexOfSheetName(name);
      if (sheetIndex < 0) return null;
      t = t.substring(bang + 1);
    }
    final r = CellRange.parse(t);
    if (r == null) return null;
    return (sheetIndex, r);
  }

  Future<void> _chooseDelimiter() async {
    final c = _ctrl;
    final csv = c?.workbook.csv;
    if (c == null || csv == null) return;
    final d = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Delimiter'),
        contentPadding: const EdgeInsets.fromLTRB(4, 12, 4, 16),
        children: [
          for (final cand in CsvCodec.candidates)
            ViewerListTile(
              title: CsvSettings.delimiterLabel(cand),
              selected: cand == csv.delimiter,
              trailing: cand == csv.delimiter
                  ? const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Icon(LucideIcons.check),
                    )
                  : null,
              onTap: () => Navigator.pop(context, cand),
            ),
        ],
      ),
    );
    if (d == null || d == csv.delimiter || !mounted) return;
    if (c.dirty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Use ${CsvSettings.delimiterLabel(d).toLowerCase()}s'),
          content: const Text('Re-read the file with this delimiter (your changes are discarded), '
              'or keep your changes and use it when saving?'),
          actions: [
            OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            OutlinedButton(onPressed: () => Navigator.pop(context, 'save'), child: const Text('When saving')),
            FilledButton(onPressed: () => Navigator.pop(context, 'reload'), child: const Text('Re-read')),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'save') {
        csv.delimiter = d;
        c.dirty = true;
        setState(() {});
        return;
      }
    }
    await _load(csv: CsvLoadOptions(delimiter: d, hasHeader: csv.hasHeader));
  }

  Future<void> _openWith() async {
    final c = _ctrl;
    if (c != null && c.dirty) _toast('Unsaved changes aren\'t included. Save first to share them.');
    try {
      final r = await OpenFilex.open(_file.path);
      if (r.type != ResultType.done && mounted) {
        _toast(r.type == ResultType.noAppToOpen ? 'No app found to open this file.' : 'Couldn\'t open the file.');
      }
    } catch (_) {
      _toast('Couldn\'t open the file.');
    }
  }

  Future<void> _onMenu(_Menu m) async {
    final c = _ctrl;
    if (c == null) return;
    switch (m) {
      case _Menu.find:
        _openFind(replace: false);
      case _Menu.replace:
        _openFind(replace: true);
      case _Menu.goTo:
        await _goTo();
      case _Menu.freezeHere:
        c.setFrozen(c.selRow, c.selCol);
      case _Menu.freezeTopRow:
        c.setFrozen(1, 0);
      case _Menu.freezeFirstColumn:
        c.setFrozen(0, 1);
      case _Menu.unfreeze:
        c.setFrozen(0, 0);
      case _Menu.sortAsc:
        final e = c.sort(ascending: true);
        if (e != null) _toast(e);
      case _Menu.sortDesc:
        final e = c.sort(ascending: false);
        if (e != null) _toast(e);
      case _Menu.insertRow:
        c.insertRows();
      case _Menu.insertColumn:
        c.insertColumns();
      case _Menu.deleteRow:
        c.deleteRows();
      case _Menu.deleteColumn:
        c.deleteColumns();
      case _Menu.fillDown:
        c.fillDown();
      case _Menu.recalc:
        c.recalculate();
      case _Menu.delimiter:
        await _chooseDelimiter();
      case _Menu.header:
        c.setCsvHeader(!(c.workbook.csv?.hasHeader ?? false));
      case _Menu.saveCopy:
        if (await _nameIfNew()) await _saveAsXlsx(c, switchToNew: false);
      case _Menu.exportCsv:
        if (await _nameIfNew()) await _exportCsv();
      case _Menu.openWith:
        await _openWith();
    }
  }

  Future<void> _showCellMenu(Offset global) async {
    final c = _ctrl;
    if (c == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rect = RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size);
    final hasMerge = c.selectionHasMerge;
    PopupMenuEntry<_CellMenu> item(_CellMenu v, IconData icon, String label,
            {bool enabled = true, bool destructive = false}) =>
        viewerMenuItem(value: v, icon: icon, label: label, enabled: enabled, destructive: destructive);
    final choice = await showMenu<_CellMenu>(
      context: context,
      position: rect,
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
      items: [
        item(_CellMenu.cut, LucideIcons.scissors, 'Cut'),
        item(_CellMenu.copy, LucideIcons.copy, 'Copy'),
        item(_CellMenu.paste, LucideIcons.clipboardPaste, 'Paste'),
        item(_CellMenu.clear, LucideIcons.eraser, 'Clear contents'),
        item(_CellMenu.clearAll, LucideIcons.removeFormatting, 'Clear all'),
        viewerMenuDivider(),
        item(_CellMenu.insertRowAbove, LucideIcons.betweenHorizontalStart, 'Insert row above'),
        item(_CellMenu.insertRowBelow, LucideIcons.betweenHorizontalEnd, 'Insert row below'),
        item(_CellMenu.insertColLeft, LucideIcons.betweenVerticalStart, 'Insert column left'),
        item(_CellMenu.insertColRight, LucideIcons.betweenVerticalEnd, 'Insert column right'),
        item(_CellMenu.deleteRows, LucideIcons.rows3, 'Delete rows', destructive: true),
        item(_CellMenu.deleteCols, LucideIcons.columns3, 'Delete columns', destructive: true),
        viewerMenuDivider(),
        item(_CellMenu.fillDown, LucideIcons.arrowDownToLine, 'Fill down'),
        item(_CellMenu.fillRight, LucideIcons.arrowRightToLine, 'Fill right'),
        item(_CellMenu.sortAsc, LucideIcons.arrowDownAZ, 'Sort A to Z'),
        item(_CellMenu.sortDesc, LucideIcons.arrowDownZA, 'Sort Z to A'),
        if (hasMerge)
          item(_CellMenu.unmerge, LucideIcons.tableCellsSplit, 'Unmerge cells')
        else
          item(_CellMenu.merge, LucideIcons.tableCellsMerge, 'Merge cells', enabled: !c.selection.isSingle),
        item(_CellMenu.freezeHere, LucideIcons.snowflake, 'Freeze panes here'),
      ],
    );
    if (choice == null || !mounted) return;
    String? msg;
    switch (choice) {
      case _CellMenu.cut:
        msg = await c.copySelection(cut: true);
      case _CellMenu.copy:
        msg = await c.copySelection();
      case _CellMenu.paste:
        msg = await c.paste();
      case _CellMenu.clear:
        c.clearSelection();
      case _CellMenu.clearAll:
        c.clearSelection(formats: true);
      case _CellMenu.insertRowAbove:
        c.insertRows();
      case _CellMenu.insertRowBelow:
        c.insertRows(below: true);
      case _CellMenu.insertColLeft:
        c.insertColumns();
      case _CellMenu.insertColRight:
        c.insertColumns(right: true);
      case _CellMenu.deleteRows:
        c.deleteRows();
      case _CellMenu.deleteCols:
        c.deleteColumns();
      case _CellMenu.fillDown:
        c.fillDown();
      case _CellMenu.fillRight:
        c.fillRight();
      case _CellMenu.sortAsc:
        msg = c.sort(ascending: true);
      case _CellMenu.sortDesc:
        msg = c.sort(ascending: false);
      case _CellMenu.merge:
        c.mergeSelection();
      case _CellMenu.unmerge:
        c.unmergeSelection();
      case _CellMenu.freezeHere:
        c.setFrozen(c.selRow, c.selCol);
    }
    if (msg != null) _toast(msg);
    if (mounted) _gridFocus.requestFocus();
  }

  Future<void> _showTabMenu(int index, Offset global) async {
    final c = _ctrl;
    if (c == null || !c.workbook.format.supportsSheets) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rect = RelativeRect.fromRect(global & const Size(1, 1), Offset.zero & overlay.size);
    final s = c.workbook.sheets[index];
    final hidden = s.visibility != SheetVisibility.visible;
    final choice = await showMenu<_TabMenu>(
      context: context,
      position: rect,
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 280),
      items: [
        viewerMenuItem(value: _TabMenu.rename, icon: LucideIcons.pencil, label: 'Rename'),
        viewerMenuItem(value: _TabMenu.duplicate, icon: LucideIcons.copy, label: 'Duplicate'),
        viewerMenuItem(
          value: _TabMenu.moveLeft,
          icon: LucideIcons.arrowLeft,
          label: 'Move left',
          enabled: index > 0,
        ),
        viewerMenuItem(
          value: _TabMenu.moveRight,
          icon: LucideIcons.arrowRight,
          label: 'Move right',
          enabled: index < c.workbook.sheets.length - 1,
        ),
        if (hidden)
          viewerMenuItem(value: _TabMenu.unhide, icon: LucideIcons.eye, label: 'Unhide')
        else
          viewerMenuItem(value: _TabMenu.hide, icon: LucideIcons.eyeOff, label: 'Hide'),
        viewerMenuDivider(),
        viewerMenuItem(
          value: _TabMenu.delete,
          icon: LucideIcons.trash2,
          label: 'Delete',
          destructive: true,
        ),
      ],
    );
    if (choice == null || !mounted) return;
    String? msg;
    switch (choice) {
      case _TabMenu.rename:
        final name = await showTextPrompt(
          context,
          title: 'Rename sheet',
          initial: s.name,
          label: 'Sheet name',
          action: 'Rename',
          validate: (v) {
            final err = validateSheetName(v);
            if (err != null) return err;
            final other = c.workbook.sheetByName(v);
            if (other != null && !identical(other, s)) return 'A sheet with this name already exists';
            return null;
          },
        );
        if (name != null && mounted) msg = c.renameSheet(c.workbook.sheets.indexOf(s), name);
      case _TabMenu.duplicate:
        c.duplicateSheet(index);
      case _TabMenu.moveLeft:
        c.moveSheet(index, -1);
      case _TabMenu.moveRight:
        c.moveSheet(index, 1);
      case _TabMenu.hide:
        msg = c.setSheetHidden(index, true);
      case _TabMenu.unhide:
        msg = c.setSheetHidden(index, false);
      case _TabMenu.delete:
        final ok = await _confirm(
          'Delete sheet?',
          'Delete "${s.name}"? You can undo this until you close the file.',
          'Delete',
          destructive: true,
        );
        if (ok && mounted) msg = c.deleteSheet(c.workbook.sheets.indexOf(s));
    }
    if (msg != null) _toast(msg);
  }

  // ---------------------------------------------------------------------------
  // UI

  Widget _topActions(BuildContext context) {
    final c = _ctrl;
    final compact = WindowSize.of(context).isCompact;
    final buttons = <Widget>[];
    if (c != null) {
      if (!compact) {
        buttons.addAll([
          ListenableBuilder(
            listenable: c,
            builder: (context, _) => ViewerAction(
              icon: LucideIcons.undo2,
              tooltip: 'Undo',
              onPressed: c.canUndo ? c.undo : null,
            ),
          ),
          ListenableBuilder(
            listenable: c,
            builder: (context, _) => ViewerAction(
              icon: LucideIcons.redo2,
              tooltip: 'Redo',
              onPressed: c.canRedo ? c.redo : null,
            ),
          ),
          ViewerAction(
            icon: LucideIcons.search,
            tooltip: 'Find & replace',
            selected: _findOpen,
            onPressed: () => _openFind(replace: false),
          ),
        ]);
      }
      buttons.add(ListenableBuilder(
        listenable: c,
        builder: (context, _) => ViewerAction(
          icon: LucideIcons.save,
          badge: c.dirty,
          busy: _saving,
          tooltip: c.workbook.format.canOverwrite ? 'Save' : 'Save as .xlsx',
          onPressed: _save,
        ),
      ));
      buttons.add(_moreMenu(context, compact));
    } else {
      buttons.add(ViewerAction(
        icon: LucideIcons.squareArrowOutUpRight,
        tooltip: 'Open in another app',
        onPressed: _openWith,
      ));
    }
    return ViewerActions(children: buttons);
  }

  Widget _moreMenu(BuildContext context, bool compact) {
    final c = _ctrl!;
    final isCsv = c.workbook.format == SpreadsheetFormat.csv;
    final frozen = c.sheet.frozenRows > 0 || c.sheet.frozenCols > 0;
    PopupMenuEntry<_Menu> item(_Menu v, IconData icon, String label, {bool destructive = false}) =>
        viewerMenuItem(value: v, icon: icon, label: label, destructive: destructive);
    return ViewerMenuButton<_Menu>(
      onSelected: _onMenu,
      itemBuilder: (context) => [
        if (compact) item(_Menu.find, LucideIcons.search, 'Find'),
        item(_Menu.replace, LucideIcons.replace, 'Find & replace'),
        item(_Menu.goTo, LucideIcons.locateFixed, 'Go to cell…'),
        viewerMenuDivider(),
        item(_Menu.sortAsc, LucideIcons.arrowDownAZ, 'Sort A to Z'),
        item(_Menu.sortDesc, LucideIcons.arrowDownZA, 'Sort Z to A'),
        item(_Menu.fillDown, LucideIcons.arrowDownToLine, 'Fill down'),
        item(_Menu.insertRow, LucideIcons.betweenHorizontalStart, 'Insert row'),
        item(_Menu.insertColumn, LucideIcons.betweenVerticalStart, 'Insert column'),
        item(_Menu.deleteRow, LucideIcons.rows3, 'Delete row', destructive: true),
        item(_Menu.deleteColumn, LucideIcons.columns3, 'Delete column', destructive: true),
        viewerMenuDivider(),
        item(_Menu.freezeHere, LucideIcons.snowflake, 'Freeze at selection'),
        item(_Menu.freezeTopRow, LucideIcons.panelTop, 'Freeze top row'),
        item(_Menu.freezeFirstColumn, LucideIcons.panelLeft, 'Freeze first column'),
        if (frozen) item(_Menu.unfreeze, LucideIcons.grid2x2X, 'Unfreeze panes'),
        item(_Menu.recalc, LucideIcons.sigma, 'Recalculate'),
        if (isCsv) ...[
          viewerMenuDivider(),
          item(_Menu.delimiter, LucideIcons.textCursorInput,
              'Delimiter: ${CsvSettings.delimiterLabel(c.workbook.csv?.delimiter ?? ',')}'),
          viewerMenuItem(
            value: _Menu.header,
            icon: LucideIcons.heading,
            label: 'First row is header',
            checked: c.workbook.csv?.hasHeader ?? false,
          ),
        ],
        viewerMenuDivider(),
        item(_Menu.saveCopy, LucideIcons.copy, 'Save a copy as .xlsx'),
        item(_Menu.exportCsv, LucideIcons.fileOutput, 'Export sheet as CSV'),
        item(_Menu.openWith, LucideIcons.externalLink, 'Open in another app'),
      ],
    );
  }

  Widget _buildError(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: DockedGlossyTopBar.contentTopInset(context)),
      child: ViewerMessage(
        icon: LucideIcons.fileSpreadsheet,
        destructive: true,
        title: "Can't open this spreadsheet",
        message: _error,
        actions: [
          OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(LucideIcons.refreshCw, size: 16),
            label: const Text('Try again'),
          ),
          FilledButton.icon(
            onPressed: _openWith,
            icon: const Icon(LucideIcons.externalLink, size: 16),
            label: const Text('Open in another app'),
          ),
        ],
      ),
    );
  }

  /// First frame while the file is read: an empty grid, not a spinner.
  Widget _buildSkeleton(BuildContext context) {
    final colors = context.colors;
    return Column(
      children: [
        SizedBox(height: DockedGlossyTopBar.contentTopInset(context)),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.background,
            border: Border(bottom: BorderSide(color: colors.border)),
          ),
          child: SizedBox(height: WindowSize.of(context).isCompact ? 40 : 44, width: double.infinity),
        ),
        const LinearProgressIndicator(minHeight: 1),
        Expanded(
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size.infinite,
              painter: _SkeletonGridPainter(GridColors.of(context)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEditor(BuildContext context, SpreadsheetController c) {
    final colors = context.colors;
    final width = MediaQuery.sizeOf(context).width;
    final ws = WindowSize.of(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    final compact = ws.isCompact;
    final hideChrome = compact && keyboard;
    final canSheets = c.workbook.format.supportsSheets;

    final formulaBar = FormulaBar(
      controller: c,
      focusNode: _formulaFocus,
      onCommit: _commit,
      onCancel: _cancelEdit,
      onGoTo: _goTo,
      dense: compact,
    );
    final toolbar = FormatToolbar(controller: c, showUndoRedo: compact);

    Widget topBars;
    if (width >= 1100) {
      topBars = Row(
        children: [
          Expanded(flex: 5, child: formulaBar),
          VerticalDivider(width: 1, color: colors.border),
          Expanded(flex: 6, child: SizedBox(height: 44, child: toolbar)),
        ],
      );
    } else {
      topBars = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          formulaBar,
          if (!hideChrome) ...[
            Divider(height: 1, color: colors.border),
            SizedBox(height: 44, child: toolbar),
          ],
        ],
      );
    }

    final grid = SheetGrid(
      controller: c,
      focusNode: _gridFocus,
      editorFocusNode: _editorFocus,
      onContextMenu: _showCellMenu,
      onMessage: _toast,
    );

    return Focus(
      onKeyEvent: _onScreenKey,
      child: Column(
        children: [
          SizedBox(height: DockedGlossyTopBar.contentTopInset(context)),
          Material(color: colors.background, child: topBars),
          if (_findOpen)
            FindReplaceBar(
              key: ValueKey(_findKey),
              controller: c,
              replaceMode: _replaceMode,
              onClose: _closeFind,
              onMessage: _toast,
            ),
          if (_previewing)
            const LinearProgressIndicator(minHeight: 1)
          else
            Divider(height: 1, color: colors.border),
          Expanded(
            child: AdaptiveSplitView(
              secondaryOnLeading: false,
              secondaryWidth: 300,
              primary: grid,
              secondary: SheetSidePanel(
                controller: c,
                onTabMenu: _showTabMenu,
                onAdd: canSheets ? c.addSheet : null,
              ),
            ),
          ),
          if (!hideChrome)
            Material(
              color: colors.background,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Divider(height: 1, color: colors.border),
                    SheetStatusBar(controller: c),
                    SheetTabs(
                      controller: c,
                      onTabMenu: _showTabMenu,
                      onAdd: canSheets ? c.addSheet : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onPop();
      },
      child: ExplorerScaffold(
        title: '${c?.dirty == true ? '• ' : ''}$_fileName',
        trailing: _topActions(context),
        body: _error != null
            ? _buildError(context)
            : (c != null && (!_loading || _previewing))
                ? _buildEditor(context, c)
                : _buildSkeleton(context),
      ),
    );
  }
}

// Isolate entry points live at top level so their closures can't capture the
// widget state (which isn't sendable to another isolate).

Future<Workbook> _parseInBackground(Uint8List bytes, String name, CsvLoadOptions? csv) =>
    Isolate.run(() => loadWorkbook(bytes, fileName: name, csv: csv));

Future<Workbook?> _previewInBackground(Uint8List bytes, String name, CsvLoadOptions? csv) =>
    Isolate.run(() => loadWorkbookPreview(bytes, fileName: name, csv: csv));

/// Header bands and grid lines at default sizes (no text, so it costs
/// nothing to lay out on the first frame).
class _SkeletonGridPainter extends CustomPainter {
  _SkeletonGridPainter(this.colors);

  final GridColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    const headerH = 22.0;
    const headerW = 40.0;
    const colW = kDefaultColWidth;
    const rowH = kDefaultRowHeight;
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.paper);
    final header = Paint()..color = colors.header;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, headerH), header);
    canvas.drawRect(Rect.fromLTWH(0, 0, headerW, size.height), header);
    final grid = Paint()
      ..color = colors.gridLine
      ..strokeWidth = 1;
    final line = Paint()
      ..color = colors.headerLine
      ..strokeWidth = 1;
    for (var x = headerW + colW; x < size.width; x += colW) {
      canvas.drawLine(Offset(x, headerH), Offset(x, size.height), grid);
      canvas.drawLine(Offset(x, 0), Offset(x, headerH), line);
    }
    for (var y = headerH + rowH; y < size.height; y += rowH) {
      canvas.drawLine(Offset(headerW, y), Offset(size.width, y), grid);
      canvas.drawLine(Offset(0, y), Offset(headerW, y), line);
    }
    canvas.drawLine(const Offset(0, headerH), Offset(size.width, headerH), line);
    canvas.drawLine(const Offset(headerW, 0), Offset(headerW, size.height), line);
  }

  @override
  bool shouldRepaint(covariant _SkeletonGridPainter old) => old.colors != colors;
}

Future<XlsxWriteResult> _writeXlsxInBackground(
        Workbook wb, Uint8List? original, SpreadsheetFormat target) =>
    Isolate.run(() => XlsxWriter.writePackage(wb, original: original, target: target));

Future<Uint8List> _writeCsvInBackground(SheetData sheet, String delimiter, String newline,
        bool date1904, TextEncodingKind encoding) =>
    Isolate.run(() => CsvCodec.encode(
          CsvCodec.write(sheet, delimiter: delimiter, newline: newline, date1904: date1904),
          encoding,
        ));
