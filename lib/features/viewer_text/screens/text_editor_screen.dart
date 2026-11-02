import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:explorer/core/files/file_types.dart';
import 'package:explorer/core/services/new_files.dart';
import 'package:explorer/core/files/safe_write.dart';
import 'package:explorer/features/viewer_hex/screens/hex_viewer_screen.dart';
import 'package:explorer/features/viewer_text/code_editor_controller.dart';
import 'package:explorer/features/viewer_text/text_document.dart';
import 'package:explorer/features/viewer_text/widgets/large_text_view.dart';
import 'package:explorer/features/viewer_text/widgets/markdown_preview.dart';
import 'package:explorer/features/viewer_kit/viewer_kit.dart';
import 'package:explorer/shared/layout/adaptive_layout.dart';
import 'package:file_picker/file_picker.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Editor for one plain-text/code file: line numbers, syntax colours,
/// find & replace, undo/redo, and Markdown preview. Encoding and line endings
/// are preserved on save.
///
/// Files above [TextDocument.editableLimit] open in a virtualised read-only
/// viewer first (instant for any size); the user can load them into the
/// editor up to [TextDocument.editAnywayLimit].
class TextEditorPane extends StatefulWidget {
  const TextEditorPane({
    super.key,
    required this.file,
    this.onDirtyChanged,
    this.onFileNamed,
    this.topPadding = 0,
    this.saveAsCopy = false,
  });

  final File file;
  final ValueChanged<bool>? onDirtyChanged;

  /// A new file got its name at its first save: this is the file now.
  final ValueChanged<File>? onFileNamed;

  /// Space reserved above the content for the floating top bar.
  final double topPadding;

  /// [file] is a temporary copy (e.g. from the system file picker on
  /// Android/iOS), so saving in place would never reach the user's file.
  /// When true, [TextEditorPaneState.save] asks where to save a copy instead.
  final bool saveAsCopy;

  @override
  State<TextEditorPane> createState() => TextEditorPaneState();
}

enum _MarkdownMode { edit, preview, split }

class TextEditorPaneState extends State<TextEditorPane> {
  static const _fontFamily = CodeFont.family;
  static const _fallbackFonts = CodeFont.fallback;

  late final CodeEditorController _controller;
  final UndoHistoryController _undo = UndoHistoryController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _vScroll = ScrollController();
  final ScrollController _hScroll = ScrollController();
  final ScrollController _gutterScroll = ScrollController();
  final TextEditingController _findController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();

  TextDocument? _document;
  String? _error;
  bool _loading = true;
  bool _readOnly = false;
  String _savedText = '';
  bool _dirty = false;
  Future<bool>? _saveInFlight;

  /// The file is shown in [LargeTextView] instead of the editor.
  bool _largeView = false;
  int _fileSize = 0;
  final GlobalKey<LargeTextViewState> _largeKey = GlobalKey();
  LargeTextStatus? _largeStatus;
  LargeTextSearch _largeSearch = LargeTextSearch.idle;
  Timer? _largeSearchDebounce;

  late bool _wrap;
  double _fontSize = 14;
  bool _showFind = false;
  bool _showReplace = false;
  bool _caseSensitive = false;
  bool _searching = false;
  _MarkdownMode _mdMode = _MarkdownMode.edit;

  /// Text the line/dirty/search state was last computed for; selection-only
  /// changes (and match updates) skip all whole-text work.
  String? _lastText;
  int _lineCount = 1;
  int _longestLine = 0;
  int _cursorLine = 1;
  int _cursorColumn = 1;

  double? _charWidthCache;
  double _charWidthFontSize = 0;
  TextPainter? _revealPainter;
  String? _revealText;
  double _revealWidth = 0;
  double _revealFontSize = 0;

  late final String _ext = FileTypes.extensionOf(widget.file.path);
  late final FileKind _kind = FileTypes.kindOf(widget.file.path);
  bool get _isMarkdown => _kind == FileKind.markdown;
  bool get _isJson => _kind == FileKind.json || _ext == 'ipynb';

  bool get isDirty => _dirty;

  @override
  void initState() {
    super.initState();
    _wrap = _kind == FileKind.text || _isMarkdown;
    _controller = CodeEditorController(
      language: SyntaxLanguage.forExtension(_ext),
    );
    _controller.addListener(_onChanged);
    // The current-line highlight shows only while the editor has focus.
    _focusNode.addListener(() {
      if (mounted) setState(() {});
    });
    _vScroll.addListener(() {
      if (_gutterScroll.hasClients &&
          _gutterScroll.offset != _vScroll.offset) {
        _gutterScroll.jumpTo(
          _vScroll.offset.clamp(0, _gutterScroll.position.maxScrollExtent),
        );
      }
    });
    _load();
  }

  @override
  void dispose() {
    _largeSearchDebounce?.cancel();
    _revealPainter?.dispose();
    _controller.dispose();
    _undo.dispose();
    _focusNode.dispose();
    _vScroll.dispose();
    _hScroll.dispose();
    _gutterScroll.dispose();
    _findController.dispose();
    _replaceController.dispose();
    super.dispose();
  }

  /// Loads the file. Large files go to the virtualised viewer unless
  /// [forEditing]; decoding happens off the UI isolate.
  Future<void> _load({bool forEditing = false}) async {
    try {
      final size = await widget.file.length();
      _fileSize = size;
      if (!forEditing && size > TextDocument.editableLimit) {
        if (!mounted) return;
        setState(() {
          _largeView = true;
          _loading = false;
        });
        return;
      }
      final doc = await TextDocument.load(widget.file);
      if (!mounted) return;
      _document = doc;
      _savedText = doc.text;
      _lastText = doc.text;
      _largeView = false;
      // Text that didn't decode cleanly would be altered by saving: keep it
      // read-only until the user accepts that.
      _readOnly = !doc.isLossless;
      _controller.value = TextEditingValue(text: doc.text);
      _recomputeLines(doc.text);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadForEditing() async {
    _largeSearchDebounce?.cancel();
    setState(() {
      _loading = true;
      _showFind = false;
      _largeStatus = null;
      _largeSearch = LargeTextSearch.idle;
    });
    await _load(forEditing: true);
  }

  void _onChanged() {
    final text = _controller.text;
    if (!identical(text, _lastText) && text != _lastText) {
      _lastText = text;
      final dirty = text != _savedText;
      if (dirty != _dirty) {
        _dirty = dirty;
        widget.onDirtyChanged?.call(dirty);
      }
      _recomputeLines(text);
      if (_showFind) _runSearch(keepIndex: true);
    }
    final sel = _controller.selection;
    if (sel.isValid) {
      final end = math.min(sel.extentOffset, text.length);
      var line = 1, lastBreak = -1;
      for (var i = 0; i < end; i++) {
        if (text.codeUnitAt(i) == 10) {
          line++;
          lastBreak = i;
        }
      }
      _cursorLine = line;
      _cursorColumn = end - lastBreak;
    }
    if (mounted) setState(() {});
  }

  void _recomputeLines(String text) {
    var count = 1, longest = 0, current = 0;
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) {
        count++;
        if (current > longest) longest = current;
        current = 0;
      } else {
        current++;
      }
    }
    _longestLine = math.max(longest, current);
    _lineCount = count;
  }

  /// Writes the file; returns false (and shows why) on failure or when the
  /// user cancels. Overlapping calls share one write.
  Future<bool> save() => _saveInFlight ??=
      _save().whenComplete(() => _saveInFlight = null);

  Future<bool> _save() async {
    var doc = _document;
    if (doc == null || _readOnly || _largeView) return false;
    // Snapshot: keystrokes typed while the write is in flight stay dirty.
    final text = _controller.text;
    Uint8List bytes;
    try {
      bytes = doc.encode(text);
    } on UnencodableTextException catch (e) {
      if (!await _confirmConvertToUtf8(e)) return false;
      doc = doc.withEncoding(TextEncoding.utf8);
      bytes = doc.encode(text);
    }
    try {
      if (widget.saveAsCopy) {
        final saved = await FilePicker.platform.saveFile(
          dialogTitle: 'Save a copy',
          fileName: p.basename(widget.file.path),
          bytes: bytes,
        );
        if (saved == null) return false;
      } else {
        final target = await UntitledFiles.saveTarget(context, widget.file);
        if (target == null || !mounted) return false;
        await writeFileAtomically(target, bytes);
        if (target.path != widget.file.path) widget.onFileNamed?.call(target);
      }
      _document = doc;
      _savedText = text;
      final dirty = _controller.text != text;
      _dirty = dirty;
      widget.onDirtyChanged?.call(dirty);
      if (mounted) setState(() {});
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e')),
        );
      }
      return false;
    }
  }

  Future<bool> _confirmConvertToUtf8(UnencodableTextException e) async {
    if (!mounted) return false;
    final chars = e.characters.map((c) => '"$c"').join(', ');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save as UTF-8?'),
        content: Text(
          'This file is stored as ${e.encodingLabel}, which can\'t hold '
          '$chars. Save it as UTF-8 instead? Programs that expect '
          '${e.encodingLabel} may show its accented letters differently.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save as UTF-8'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // ---- Search ------------------------------------------------------------

  void toggleFind({bool replace = false}) {
    if (_loading || _error != null) return;
    if (_largeView) {
      setState(() {
        _showFind = !_showFind;
        _showReplace = false;
      });
      if (!_showFind) {
        _largeKey.currentState?.search('', caseSensitive: _caseSensitive);
      } else if (_findController.text.isNotEmpty) {
        _scheduleLargeSearch(immediate: true);
      }
      return;
    }
    setState(() {
      if (_showFind && _showReplace == replace) {
        _showFind = false;
        _controller.setMatches(const [], -1);
      } else {
        _showFind = true;
        _showReplace = replace;
        final sel = _controller.selection;
        if (sel.isValid && !sel.isCollapsed) {
          _findController.text = sel.textInside(_controller.text);
        }
        _runSearch();
      }
    });
  }

  void _runSearch({bool keepIndex = false}) {
    // setMatches notifies the controller's listeners; never re-enter.
    if (_searching) return;
    _searching = true;
    try {
      final query = _findController.text;
      if (query.isEmpty) {
        _controller.setMatches(const [], -1);
        return;
      }
      final haystack =
          _caseSensitive ? _controller.text : _controller.text.toLowerCase();
      final needle = _caseSensitive ? query : query.toLowerCase();
      final matches = <TextRange>[];
      var from = 0;
      while (matches.length < 10000) {
        final i = haystack.indexOf(needle, from);
        if (i < 0) break;
        matches.add(TextRange(start: i, end: i + needle.length));
        from = i + math.max(1, needle.length);
      }
      var current = keepIndex ? _controller.currentMatch : 0;
      if (current >= matches.length) current = matches.isEmpty ? -1 : 0;
      if (matches.isEmpty) current = -1;
      _controller.setMatches(matches, current);
      if (!keepIndex && current >= 0) _revealOffset(matches[current].start);
    } finally {
      _searching = false;
    }
  }

  void _scheduleLargeSearch({bool immediate = false}) {
    _largeSearchDebounce?.cancel();
    void run() => _largeKey.currentState
        ?.search(_findController.text, caseSensitive: _caseSensitive);
    if (immediate) {
      run();
    } else {
      _largeSearchDebounce = Timer(const Duration(milliseconds: 350), run);
    }
  }

  void _gotoMatch(int delta) {
    if (_largeView) {
      if (delta > 0) {
        _largeKey.currentState?.nextHit();
      } else {
        _largeKey.currentState?.previousHit();
      }
      return;
    }
    final matches = _controller.matches;
    if (matches.isEmpty) return;
    final next = (_controller.currentMatch + delta) % matches.length;
    _controller.setMatches(matches, next < 0 ? next + matches.length : next);
    final m = matches[_controller.currentMatch];
    _controller.selection = TextSelection(baseOffset: m.start, extentOffset: m.end);
    _revealOffset(m.start);
  }

  void _replaceCurrent() {
    final matches = _controller.matches;
    final i = _controller.currentMatch;
    if (_readOnly || i < 0 || i >= matches.length) return;
    final m = matches[i];
    final replacement = _replaceController.text;
    _controller.value = TextEditingValue(
      text: _controller.text.replaceRange(m.start, m.end, replacement),
      selection: TextSelection.collapsed(offset: m.start + replacement.length),
    );
  }

  void _replaceAll() {
    final query = _findController.text;
    if (_readOnly || query.isEmpty) return;
    final pattern = RegExp(RegExp.escape(query), caseSensitive: _caseSensitive);
    final count = pattern.allMatches(_controller.text).length;
    _controller.value = TextEditingValue(
      text: _controller.text.replaceAll(pattern, _replaceController.text),
    );
    _runSearch();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Replaced $count occurrence${count == 1 ? '' : 's'}')),
    );
  }

  // letterSpacing is explicit: TextField merges the theme's body style
  // (which has some) into this one, and columns are measured without it.
  TextStyle get _textStyle => TextStyle(
        fontFamily: _fontFamily,
        fontFamilyFallback: _fallbackFonts,
        fontSize: _fontSize,
        height: 1.45,
        letterSpacing: 0,
        wordSpacing: 0,
        color: Theme.of(context).colorScheme.onSurface,
      );

  StrutStyle get _strut => StrutStyle(
        fontFamily: _fontFamily,
        fontFamilyFallback: _fallbackFonts,
        fontSize: _fontSize,
        height: 1.45,
        forceStrutHeight: true,
      );

  double get _lineHeight => _fontSize * 1.45;

  double _charWidth() {
    final cached = _charWidthCache;
    if (cached != null && _charWidthFontSize == _fontSize) return cached;
    final painter = TextPainter(
      text: TextSpan(text: 'M', style: _textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    _charWidthFontSize = _fontSize;
    final width = painter.width;
    painter.dispose();
    return _charWidthCache = width;
  }

  /// Scrolls so the line containing [offset] is visible.
  void _revealOffset(int offset) {
    if (!_vScroll.hasClients) return;
    final text = _controller.text;
    double y;
    if (_wrap) {
      final width = (context.size?.width ?? 400) - 32;
      // Laying out the whole text is expensive: reuse it for next/previous.
      var painter = _revealPainter;
      if (painter == null ||
          !identical(_revealText, text) ||
          _revealWidth != width ||
          _revealFontSize != _fontSize) {
        painter?.dispose();
        painter = _revealPainter = TextPainter(
          text: TextSpan(text: text, style: _textStyle),
          strutStyle: _strut,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: width);
        _revealText = text;
        _revealWidth = width;
        _revealFontSize = _fontSize;
      }
      y = painter.getOffsetForCaret(TextPosition(offset: offset), Rect.zero).dy;
    } else {
      var line = 0;
      for (var i = 0; i < offset && i < text.length; i++) {
        if (text.codeUnitAt(i) == 10) line++;
      }
      y = line * _lineHeight;
      if (_hScroll.hasClients) {
        final col = offset - (text.lastIndexOf('\n', math.max(0, offset - 1)) + 1);
        final x = col * _charWidth();
        final viewport = _hScroll.position.viewportDimension;
        if (x < _hScroll.offset || x > _hScroll.offset + viewport - 40) {
          _hScroll.jumpTo((x - viewport / 3).clamp(0, _hScroll.position.maxScrollExtent));
        }
      }
    }
    final viewport = _vScroll.position.viewportDimension;
    final target = (y - viewport / 3).clamp(0.0, _vScroll.position.maxScrollExtent);
    _vScroll.animateTo(target, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  // ---- Commands ----------------------------------------------------------

  void _insertText(String insert) {
    if (_readOnly) return;
    final value = _controller.value;
    final sel = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    _controller.value = TextEditingValue(
      text: value.text.replaceRange(sel.start, sel.end, insert),
      selection: TextSelection.collapsed(offset: sel.start + insert.length),
    );
  }

  void _formatJson() {
    try {
      final decoded = jsonDecode(_controller.text);
      _controller.value = TextEditingValue(
        text: '${const JsonEncoder.withIndent('  ').convert(decoded)}\n',
      );
    } on FormatException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid JSON: ${e.message}')),
      );
    }
  }

  void _openHex() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => HexViewerScreen(file: widget.file)),
    );
  }

  Future<void> _goToLine() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Go to line'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: _largeStatus == null
                ? 'Line number'
                : '1 – ${_largeStatus!.lineCount}${_largeStatus!.complete ? '' : '+'}',
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Go'),
          ),
        ],
      ),
    );
    controller.dispose();
    final line = int.tryParse(value?.trim() ?? '');
    if (line == null || line < 1) return;
    await _largeKey.currentState?.goToLine(line);
  }

  void _showInfo() {
    final doc = _document;
    final large = _largeView;
    final text = large ? '' : _controller.text;
    final words = large ? 0 : RegExp(r'\S+').allMatches(text).length;
    final status = _largeStatus;
    final entries = <String, String>{
      'Size': filesize(_fileSize),
      if (!large) ...{
        'Lines': '$_lineCount',
        'Words': '$words',
        'Characters': '${text.length}',
      } else if (status != null)
        'Lines': '${status.lineCount}${status.complete ? '' : '+ (counting…)'}',
      if (doc != null) 'Encoding': doc.encodingLabel,
      if (large && status != null)
        'Encoding': TextDocument.labelOf(status.encoding),
      if (doc != null) 'Line endings': doc.lineEnding.label,
      if (doc != null && !doc.isLossless)
        'Invalid byte sequences': '${doc.malformedCount}',
      if (!large && _controller.language != null)
        'Highlighting': _controller.language!.name,
    };
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Document info'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: DetailList(entries: entries.entries, labelWidth: 150),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }


  // ---- UI ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: EdgeInsets.only(top: widget.topPadding),
        child: const ViewerLoading(label: 'Opening…'),
      );
    }
    if (_error != null) {
      return Padding(
        padding: EdgeInsets.only(top: widget.topPadding),
        child: ViewerMessage(
          icon: LucideIcons.fileX2,
          title: "Can't open this file as text",
          message: 'It may be a binary file. You can still look at its bytes '
              'in the hex viewer.',
          details: _error,
          actions: [
            OutlinedButton.icon(
              onPressed: _openHex,
              icon: const Icon(LucideIcons.binary, size: 16),
              label: const Text('Open in hex viewer'),
            ),
          ],
        ),
      );
    }
    if (_largeView) return _buildLarge();
    _controller.theme = CodeTheme.of(context);

    final wide = AdaptiveSplitView.isSplit(context);
    final mdMode = _isMarkdown && _mdMode == _MarkdownMode.split && !wide
        ? _MarkdownMode.preview
        : _mdMode;

    Widget content;
    if (_isMarkdown && mdMode == _MarkdownMode.preview) {
      content = MarkdownPreview(markdown: _controller.text, file: widget.file);
    } else if (_isMarkdown && mdMode == _MarkdownMode.split) {
      content = Row(
        children: [
          Expanded(child: _buildEditor()),
          const VerticalDivider(width: 1),
          Expanded(
            child: MarkdownPreview(markdown: _controller.text, file: widget.file),
          ),
        ],
      );
    } else {
      content = _buildEditor();
    }

    final doc = _document;
    final notices = <Widget>[
      if (widget.saveAsCopy)
        const ViewerNotice(
          icon: LucideIcons.copy,
          message: 'This is a temporary copy of the file you picked. Save asks '
              'where to store your changes.',
        ),
      if (doc != null && !doc.isLossless && _readOnly)
        ViewerNotice(
          icon: LucideIcons.triangleAlert,
          tone: Tone.warning,
          message: 'This file has ${doc.malformedCount} byte sequence'
              '${doc.malformedCount == 1 ? '' : 's'} that aren\'t valid '
              '${doc.encodingLabel}. They show as �, and saving would '
              'write � in their place.',
          actions: [
            TextButton(
              onPressed: () => setState(() => _readOnly = false),
              child: const Text('Edit anyway'),
            ),
          ],
        ),
    ];
    return Padding(
      padding: EdgeInsets.only(top: widget.topPadding),
      child: Column(
        children: [
          _buildToolbar(wide),
          ...notices,
          if (notices.isNotEmpty) const SizedBox(height: 8),
          if (_showFind) _buildFindBar(),
          Expanded(child: content),
          _buildStatusBar(),
        ],
      ),
    );
  }

  Widget _buildLarge() {
    final canEdit = _fileSize <= TextDocument.editAnywayLimit;
    return Padding(
      padding: EdgeInsets.only(top: widget.topPadding),
      child: Column(
        children: [
          _toolbarFrame(
            [
              ToolButton(
                icon: LucideIcons.search,
                tooltip: 'Find',
                selected: _showFind,
                onPressed: () => toggleFind(),
              ),
              ToolButton(
                icon: LucideIcons.listOrdered,
                tooltip: 'Go to line',
                onPressed: _goToLine,
              ),
              const ToolDivider(),
              ..._fontSizeButtons(),
              const ToolDivider(),
              ToolButton(
                icon: LucideIcons.binary,
                tooltip: 'Open in hex viewer',
                onPressed: _openHex,
              ),
            ],
            trailing: ToolButton(
              icon: LucideIcons.info,
              tooltip: 'Document info',
              onPressed: _showInfo,
            ),
          ),
          ViewerNotice(
            icon: LucideIcons.gauge,
            message: 'Large file (${filesize(_fileSize)}) shown read-only so '
                'it opens instantly.'
                '${canEdit ? ' Editing it in full can be slow.' : ''}',
            actions: [
              if (canEdit)
                TextButton(onPressed: _loadForEditing, child: const Text('Edit')),
            ],
          ),
          const SizedBox(height: 8),
          if (_showFind) _buildFindBar(),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: context.colors.border)),
              ),
              child: LargeTextView(
                key: _largeKey,
                file: widget.file,
                style: _textStyle,
                strut: _strut,
                lineHeight: _lineHeight,
                onStatus: (s) {
                  if (mounted) setState(() => _largeStatus = s);
                },
                onSearch: (s) {
                  if (mounted) setState(() => _largeSearch = s);
                },
              ),
            ),
          ),
          _buildStatusBar(),
        ],
      ),
    );
  }

  /// Toolbar row: [tools] scroll horizontally on narrow screens, [trailing]
  /// stays at the end.
  Widget _toolbarFrame(List<Widget> tools, {Widget? trailing}) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: tools),
              ),
            ),
            if (trailing != null) ...[
              const ToolDivider(),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: trailing,
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _fontSizeButtons() => [
        ToolButton(
          icon: LucideIcons.aArrowDown,
          tooltip: 'Smaller text',
          onPressed: _fontSize > 9 ? () => setState(() => _fontSize -= 1) : null,
        ),
        ToolButton(
          icon: LucideIcons.aArrowUp,
          tooltip: 'Larger text',
          onPressed: _fontSize < 32 ? () => setState(() => _fontSize += 1) : null,
        ),
      ];

  Widget _buildToolbar(bool wide) {
    return _toolbarFrame(
      [
        ValueListenableBuilder<UndoHistoryValue>(
          valueListenable: _undo,
          builder: (context, value, _) => Row(
            children: [
              ToolButton(
                icon: LucideIcons.undo2,
                tooltip: 'Undo',
                onPressed: value.canUndo && !_readOnly ? _undo.undo : null,
              ),
              ToolButton(
                icon: LucideIcons.redo2,
                tooltip: 'Redo',
                onPressed: value.canRedo && !_readOnly ? _undo.redo : null,
              ),
            ],
          ),
        ),
        const ToolDivider(),
        ToolButton(
          icon: LucideIcons.search,
          tooltip: 'Find',
          selected: _showFind && !_showReplace,
          onPressed: () => toggleFind(),
        ),
        ToolButton(
          icon: LucideIcons.replace,
          tooltip: 'Find and replace',
          selected: _showFind && _showReplace,
          onPressed: _readOnly ? null : () => toggleFind(replace: true),
        ),
        const ToolDivider(),
        ToolButton(
          icon: LucideIcons.wrapText,
          tooltip: _wrap ? 'Disable word wrap' : 'Enable word wrap',
          selected: _wrap,
          onPressed: () => setState(() => _wrap = !_wrap),
        ),
        ..._fontSizeButtons(),
        if (_isJson) ...[
          const ToolDivider(),
          ToolButton(
            icon: LucideIcons.braces,
            tooltip: 'Format JSON',
            onPressed: _readOnly ? null : _formatJson,
          ),
        ],
        if (_isMarkdown) ...[
          const ToolDivider(),
          SegmentedButton<_MarkdownMode>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity(horizontal: -2, vertical: -2),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            segments: [
              const ButtonSegment(
                value: _MarkdownMode.edit,
                icon: Icon(LucideIcons.squarePen, size: 16),
                tooltip: 'Edit',
              ),
              if (wide)
                const ButtonSegment(
                  value: _MarkdownMode.split,
                  icon: Icon(LucideIcons.columns2, size: 16),
                  tooltip: 'Edit and preview',
                ),
              const ButtonSegment(
                value: _MarkdownMode.preview,
                icon: Icon(LucideIcons.eye, size: 16),
                tooltip: 'Preview',
              ),
            ],
            selected: {
              !wide && _mdMode == _MarkdownMode.split
                  ? _MarkdownMode.preview
                  : _mdMode,
            },
            onSelectionChanged: (s) => setState(() => _mdMode = s.first),
          ),
        ],
      ],
      trailing: ToolButton(
        icon: LucideIcons.info,
        tooltip: 'Document info',
        onPressed: _showInfo,
      ),
    );
  }

  Widget _buildFindBar() {
    final String label;
    final bool hasMatches;
    if (_largeView) {
      final s = _largeSearch;
      hasMatches = s.count > 0;
      label = _findController.text.isEmpty
          ? ''
          : s.busy
              ? 'Searching…'
              : s.count == 0
                  ? 'No results'
                  : '${s.current + 1}/${s.count}${s.truncated ? '+' : ''}';
    } else {
      final matches = _controller.matches;
      final current = _controller.currentMatch;
      hasMatches = matches.isNotEmpty;
      label = _findController.text.isEmpty
          ? ''
          : matches.isEmpty
              ? 'No results'
              : '${current + 1}/${matches.length}';
    }
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    InputDecoration decoration(String hint, IconData icon, {String? suffix}) =>
        InputDecoration(
          isDense: true,
          hintText: hint,
          prefixIcon: Icon(icon, size: 16),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 34, minHeight: 34),
          suffixText: suffix == null || suffix.isEmpty ? null : suffix,
          suffixStyle: text.labelMedium?.copyWith(
            color: colors.mutedForeground,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        );
    final compactButton = OutlinedButton.styleFrom(
      minimumSize: const Size(0, 36),
      padding: const EdgeInsets.symmetric(horizontal: 12),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _findController,
                    autofocus: true,
                    style: text.bodyMedium,
                    decoration: decoration(
                      'Find',
                      LucideIcons.search,
                      suffix: label,
                    ),
                    onChanged: (_) {
                      if (_largeView) {
                        _scheduleLargeSearch();
                      } else {
                        setState(_runSearch);
                      }
                    },
                    onSubmitted: (_) => _gotoMatch(1),
                  ),
                ),
                const SizedBox(width: 4),
                ToolButton(
                  icon: LucideIcons.caseSensitive,
                  tooltip: 'Match case',
                  selected: _caseSensitive,
                  onPressed: () => setState(() {
                    _caseSensitive = !_caseSensitive;
                    if (_largeView) {
                      _scheduleLargeSearch(immediate: true);
                    } else {
                      _runSearch();
                    }
                  }),
                ),
                ToolButton(
                  icon: LucideIcons.chevronUp,
                  tooltip: 'Previous',
                  onPressed: hasMatches ? () => _gotoMatch(-1) : null,
                ),
                ToolButton(
                  icon: LucideIcons.chevronDown,
                  tooltip: 'Next',
                  onPressed: hasMatches ? () => _gotoMatch(1) : null,
                ),
                ToolButton(
                  icon: LucideIcons.x,
                  tooltip: 'Close',
                  onPressed: () => toggleFind(replace: _showReplace),
                ),
              ],
            ),
            if (_showReplace && !_largeView)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _replaceController,
                        style: text.bodyMedium,
                        decoration:
                            decoration('Replace with', LucideIcons.replace),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      style: compactButton,
                      onPressed: hasMatches ? _replaceCurrent : null,
                      child: const Text('Replace'),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton(
                      style: compactButton,
                      onPressed: hasMatches ? _replaceAll : null,
                      child: const Text('All'),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// No border in any state: InputDecoration.collapsed alone still picks
  /// up the theme's focused border.
  static const _bareDecoration = InputDecoration(
    isCollapsed: true,
    contentPadding: EdgeInsets.zero,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
    filled: false,
  );

  Widget _buildEditor() {
    final colors = context.colors;
    final field = TextField(
      controller: _controller,
      undoController: _undo,
      focusNode: _focusNode,
      readOnly: _readOnly,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      style: _textStyle,
      strutStyle: _strut,
      scrollPhysics: const NeverScrollableScrollPhysics(),
      decoration: _bareDecoration,
    );
    final editable = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.tab): () => _insertText('  '),
      },
      child: field,
    );

    final showGutter = !_wrap;
    final focused = _focusNode.hasFocus;
    return LayoutBuilder(
      builder: (context, constraints) {
        final gutterWidth = showGutter
            ? 20 + '$_lineCount'.length * _charWidth()
            : 0.0;
        Widget editor;
        if (_wrap) {
          editor = Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
            child: editable,
          );
        } else {
          final contentWidth = math.max(
            constraints.maxWidth - gutterWidth,
            (_longestLine + 4) * _charWidth() + 32,
          );
          editor = Scrollbar(
            controller: _hScroll,
            child: SingleChildScrollView(
              controller: _hScroll,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: contentWidth,
                child: Stack(
                  children: [
                    // Current line (rows have a fixed strut height).
                    if (focused)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 12 + (_cursorLine - 1) * _lineHeight,
                        height: _lineHeight,
                        child: ColoredBox(
                          color: colors.muted.withValues(alpha: 0.7),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 16, 48),
                      child: editable,
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final body = Scrollbar(
          controller: _vScroll,
          child: SingleChildScrollView(
            controller: _vScroll,
            child: editor,
          ),
        );

        if (!showGutter) {
          return GestureDetector(onTap: _focusNode.requestFocus, child: body);
        }

        // Line numbers are a lazily built list (one row per line, same strut
        // height as the editor) instead of one giant paragraph.
        final gutterStyle = _textStyle.copyWith(
          color: colors.mutedForeground.withValues(alpha: 0.75),
        );
        final currentStyle = _textStyle.copyWith(color: colors.foreground);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.muted.withValues(alpha: 0.35),
                border: Border(right: BorderSide(color: colors.border)),
              ),
              child: SizedBox(
                width: gutterWidth,
                child: ScrollConfiguration(
                  behavior: const ScrollBehavior().copyWith(scrollbars: false),
                  child: ListView.builder(
                    controller: _gutterScroll,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(4, 12, 10, 48),
                    itemExtent: _lineHeight,
                    itemCount: _lineCount,
                    itemBuilder: (context, i) => Text(
                      '${i + 1}',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      style: focused && i + 1 == _cursorLine
                          ? currentStyle
                          : gutterStyle,
                      strutStyle: _strut,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: body),
          ],
        );
      },
    );
  }

  Widget _buildStatusBar() {
    final doc = _document;
    final colors = context.colors;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: 11.5,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    final large = _largeStatus;
    final details = [
      if (doc != null && !_largeView) doc.encodingLabel,
      if (doc != null && !_largeView) doc.lineEnding.label,
      if (_largeView && large != null) TextDocument.labelOf(large.encoding),
      if (!_largeView && _controller.language != null)
        _controller.language!.name,
    ].join('  ·  ');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          12,
          0,
          12,
          MediaQuery.paddingOf(context).bottom,
        ),
        child: SizedBox(
          height: 30,
          child: Row(
            children: [
              Text(
                _largeView
                    ? (large == null
                        ? 'Reading…'
                        : '${large.lineCount}${large.complete ? '' : '+'} lines')
                    : 'Ln $_cursorLine, Col $_cursorColumn',
                style: style,
              ),
              if (_readOnly || _largeView) ...[
                const SizedBox(width: 8),
                const StatusBadge('Read-only', icon: LucideIcons.lock),
              ],
              if (_dirty) ...[
                const SizedBox(width: 8),
                const StatusBadge('Modified', tone: Tone.warning),
              ],
              const SizedBox(width: 12),
              // Ellipsizes instead of overflowing on narrow screens.
              Expanded(
                child: Text(
                  details,
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
