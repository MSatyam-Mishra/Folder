import 'package:explorer/shared/ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// A name being edited where it's shown, as in File Explorer. Enter or a click
/// elsewhere keeps what's typed; Esc keeps the name it had.
class InlineRename extends StatefulWidget {
  const InlineRename({super.key, required this.name, required this.onDone, this.centered = false});

  final String name;

  /// What was typed, or null for Esc.
  final ValueChanged<String?> onDone;

  /// Under an icon, in a tile, rather than in a row.
  final bool centered;

  @override
  State<InlineRename> createState() => _InlineRenameState();
}

class _InlineRenameState extends State<InlineRename> {
  late final _controller = TextEditingController(text: widget.name);
  final _focus = FocusNode(debugLabel: 'Inline rename');
  bool _focused = false;
  bool _done = false;

  void _finish(String? name) {
    if (_done) return;
    _done = true;
    widget.onDone(name);
  }

  void _onFocusChange() {
    if (_focus.hasFocus) {
      _focused = true;
    } else if (_focused) {
      _finish(_controller.text.trim());
    }
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
    // The name without its extension is what gets replaced by typing.
    final extension = p.extension(widget.name);
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.name.length - extension.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(4),
      borderSide: BorderSide(color: colors.ring),
    );
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _finish(null)},
      child: SizedBox(
        height: 26,
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          maxLines: 1,
          textAlign: widget.centered ? TextAlign.center : TextAlign.start,
          textAlignVertical: TextAlignVertical.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: colors.background.withValues(alpha: 1),
            contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            border: border,
            enabledBorder: border,
            focusedBorder: border,
          ),
          onSubmitted: (value) => _finish(value.trim()),
        ),
      ),
    );
  }
}
