import 'dart:io';
import 'dart:typed_data';

import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folder/shared/widgets/explorer_scaffold.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Read-only hex dump for any file. Pages are read lazily so multi-gigabyte
/// files open instantly.
class HexViewerScreen extends StatefulWidget {
  const HexViewerScreen({super.key, required this.file});

  final File file;

  @override
  State<HexViewerScreen> createState() => _HexViewerScreenState();
}

class _HexViewerScreenState extends State<HexViewerScreen> {
  static const _pageSize = 64 * 1024;

  RandomAccessFile? _raf;
  int _length = 0;
  String? _error;
  final Map<int, Uint8List> _pages = {};
  final Set<int> _loading = {};
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    RandomAccessFile? raf;
    try {
      raf = await widget.file.open();
      final length = await raf.length();
      if (!mounted) {
        await raf.close();
        return;
      }
      setState(() {
        _raf = raf;
        _length = length;
      });
    } catch (e) {
      if (_raf == null) {
        try {
          await raf?.close();
        } catch (_) {}
      }
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    // A read may be in flight, and RandomAccessFile refuses to close while
    // one is pending ("An async operation is currently pending"), which
    // leaked the handle. Close after the queued work instead; queued reads
    // see `_raf == null` and skip.
    final raf = _raf;
    _raf = null;
    _pending.catchError((Object _) {}).whenComplete(() async {
      try {
        await raf?.close();
      } catch (_) {}
    });
    _scroll.dispose();
    super.dispose();
  }

  Uint8List? _page(int index) {
    final cached = _pages[index];
    if (cached != null) return cached;
    if (_loading.add(index)) {
      _readPage(index);
    }
    return null;
  }

  // RandomAccessFile allows one pending operation at a time, so reads are
  // chained.
  Future<void> _pending = Future.value();

  /// Bytes per row and row height of the current layout, to tell whether a
  /// queued page is still near the viewport.
  int _bytesPerRow = 16;
  double _rowHeight = 22;

  bool _isNearViewport(int index) {
    if (!_scroll.hasClients) return true;
    final position = _scroll.position;
    final firstRow = (position.pixels / _rowHeight).floor();
    final lastRow = ((position.pixels + position.viewportDimension) / _rowHeight).ceil();
    final firstPage = firstRow * _bytesPerRow ~/ _pageSize;
    final lastPage = lastRow * _bytesPerRow ~/ _pageSize;
    return index >= firstPage - 1 && index <= lastPage + 1;
  }

  void _readPage(int index) {
    _pending = _pending.then((_) async {
      if (_raf == null || !mounted) return;
      // Fast scrolling queues many pages; skip the ones scrolled past (the
      // row asks again if it comes back into view).
      if (!_isNearViewport(index)) {
        _loading.remove(index);
        return;
      }
      Uint8List bytes;
      try {
        final raf = _raf;
        if (raf == null) return;
        await raf.setPosition(index * _pageSize);
        if (!mounted || _raf == null) return;
        bytes = await raf.read(_pageSize);
      } catch (e) {
        // Keep the chain alive; show the error rather than retrying forever.
        if (mounted) setState(() => _error = '$e');
        return;
      }
      if (!mounted) return;
      if (_pages.length > 64) _pages.remove(_pages.keys.first);
      setState(() {
        _pages[index] = bytes;
        _loading.remove(index);
      });
    });
  }

  Future<void> _jumpToOffset(int bytesPerRow, double rowHeight) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Go to offset'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. 1024 or 0x400',
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
    if (value == null) return;
    final text = value.trim().toLowerCase();
    final offset = text.startsWith('0x')
        ? int.tryParse(text.substring(2), radix: 16)
        : int.tryParse(text);
    if (offset == null || !_scroll.hasClients) return;
    final row = offset.clamp(0, _length) ~/ bytesPerRow;
    _scroll.jumpTo(
      (row * rowHeight).clamp(0, _scroll.position.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final bytesPerRow = width >= 720 ? 16 : 8;
    const rowHeight = 22.0;
    _bytesPerRow = bytesPerRow;
    _rowHeight = rowHeight;
    final rows = (_length + bytesPerRow - 1) ~/ bytesPerRow;
    final topInset = DockedGlossyTopBar.contentTopInset(context);
    final error = _error;

    Widget body;
    if (error != null) {
      body = ViewerMessage(
        icon: LucideIcons.fileX2,
        title: "Can't read this file",
        details: error,
      );
    } else if (_raf == null) {
      body = const ViewerLoading();
    } else {
      final style = _style(context);
      // Wide screens centre the dump; narrow ones scroll it sideways.
      final painter = TextPainter(
        text: TextSpan(text: '0' * (13 + bytesPerRow * 4), style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final dumpWidth = painter.width + 2;
      painter.dispose();
      final center = width >= 720 && dumpWidth + 32 < width;
      Widget line(Widget text) => center
          ? Center(child: SizedBox(width: dumpWidth, child: text))
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(alignment: Alignment.centerLeft, child: text),
            );
      body = Column(
        children: [
          _header(context, bytesPerRow, style, line),
          Expanded(
            child: Scrollbar(
              controller: _scroll,
              interactive: true,
              thumbVisibility: true,
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.only(top: 4, bottom: 24),
                itemExtent: rowHeight,
                itemCount: rows,
                itemBuilder: (context, row) =>
                    _buildRow(context, row, bytesPerRow, style, line),
              ),
            ),
          ),
          _footer(context, rows),
        ],
      );
    }

    return ExplorerScaffold(
      title: p.basename(widget.file.path),
      trailing: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: AppIconButton(
          icon: const Icon(LucideIcons.locateFixed),
          tooltip: 'Go to offset',
          onPressed: _raf == null
              ? null
              : () => _jumpToOffset(bytesPerRow, rowHeight),
        ),
      ),
      body: Padding(padding: EdgeInsets.only(top: topInset), child: body),
    );
  }

  TextStyle _style(BuildContext context) =>
      CodeFont.style(fontSize: 13, color: context.colors.foreground);

  /// Column labels: two hex digits and a space per byte, with an extra
  /// space after 8 bytes (as in the rows).
  static String _hexHeader(int bytesPerRow) {
    final b = StringBuffer();
    for (var i = 0; i < bytesPerRow; i++) {
      if (i == 8) b.write(' ');
      b.write('${i.toRadixString(16).padLeft(2, '0').toUpperCase()} ');
    }
    return b.toString();
  }

  Widget _header(
    BuildContext context,
    int bytesPerRow,
    TextStyle style,
    Widget Function(Widget) line,
  ) {
    final colors = context.colors;
    final muted = style.copyWith(
      color: colors.mutedForeground,
      fontWeight: FontWeight.w500,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.muted.withValues(alpha: 0.5),
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: SizedBox(
        height: 32,
        width: double.infinity,
        child: line(
          Text(
            '${'Offset'.padRight(8)}   ${_hexHeader(bytesPerRow)} ASCII',
            maxLines: 1,
            style: muted,
          ),
        ),
      ),
    );
  }

  Widget _footer(BuildContext context, int rows) {
    final colors = context.colors;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
          fontSize: 11.5,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    final hexLength = '0x${_length.toRadixString(16).toUpperCase()}';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          MediaQuery.paddingOf(context).bottom,
        ),
        child: SizedBox(
          height: 30,
          child: Row(
            children: [
              Flexible(
                child: Text(
                  _length < 1024
                      ? filesize(_length)
                      : '${filesize(_length)} · $_length bytes',
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              const StatusBadge('Read-only', icon: LucideIcons.lock),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '$hexLength · $rows rows',
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

  Widget _buildRow(
    BuildContext context,
    int row,
    int bytesPerRow,
    TextStyle style,
    Widget Function(Widget) line,
  ) {
    final colors = context.colors;
    final start = row * bytesPerRow;
    final page = _page(start ~/ _pageSize);
    final offsetStyle = TextStyle(color: colors.mutedForeground);
    final zeroStyle = TextStyle(
      color: colors.mutedForeground.withValues(alpha: 0.55),
    );
    final asciiStyle = TextStyle(color: colors.mutedForeground);
    final offset = start.toRadixString(16).padLeft(8, '0').toUpperCase();

    final spans = <TextSpan>[TextSpan(text: '$offset   ', style: offsetStyle)];
    if (page != null) {
      // Runs of zero / non-zero bytes become one span each.
      final run = StringBuffer();
      bool? runZero;
      void flush() {
        if (run.isEmpty) return;
        spans.add(TextSpan(
          text: run.toString(),
          style: runZero == true ? zeroStyle : null,
        ));
        run.clear();
      }

      final ascii = StringBuffer();
      for (var i = 0; i < bytesPerRow; i++) {
        final pos = start + i;
        final inPage = pos - (start ~/ _pageSize) * _pageSize;
        if (i == 8) run.write(' ');
        if (pos >= _length || inPage >= page.length) {
          run.write('   ');
          continue;
        }
        final b = page[inPage];
        final zero = b == 0;
        if (runZero != null && zero != runZero) flush();
        runZero = zero;
        run.write('${b.toRadixString(16).padLeft(2, '0').toUpperCase()} ');
        ascii.writeCharCode(b >= 0x20 && b < 0x7F ? b : 0x2E);
      }
      flush();
      spans
        ..add(const TextSpan(text: ' '))
        ..add(TextSpan(text: ascii.toString(), style: asciiStyle));
    }

    return ColoredBox(
      color: row.isOdd
          ? colors.muted.withValues(alpha: 0.3)
          : Colors.transparent,
      child: line(
        Text.rich(
          TextSpan(style: style, children: spans),
          maxLines: 1,
        ),
      ),
    );
  }
}
