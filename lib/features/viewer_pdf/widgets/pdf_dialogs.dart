import 'package:folders/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Colours offered for annotations, ink and text.
const pdfPaletteColors = <Color>[
  Color(0xFFFFEB3B), // yellow
  Color(0xFFFF9800), // orange
  Color(0xFFF44336), // red
  Color(0xFFE91E63), // pink
  Color(0xFF9C27B0), // purple
  Color(0xFF3F51B5), // indigo
  Color(0xFF2196F3), // blue
  Color(0xFF00BCD4), // cyan
  Color(0xFF4CAF50), // green
  Color(0xFF8BC34A), // light green
  Color(0xFF795548), // brown
  Color(0xFF000000), // black
  Color(0xFF9E9E9E), // grey
  Color(0xFFFFFFFF), // white
];

/// Asks for the password of an encrypted PDF. Returns null when cancelled.
Future<String?> showPdfPasswordDialog(
  BuildContext context, {
  required String fileName,
  bool wrongPassword = false,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _PasswordDialog(
      title: 'Password required',
      message: '"$fileName" is protected. Enter its password to open it.',
      errorText: wrongPassword ? 'Wrong password, try again' : null,
      confirmLabel: 'Open',
    ),
  );
}

/// Asks for a new document password (entered twice).
Future<String?> showSetPdfPasswordDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (context) => const _PasswordDialog(
      title: 'Set password',
      message: 'Anyone opening the saved file will need this password.',
      confirmLabel: 'Set',
      confirm: true,
    ),
  );
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.errorText,
    this.confirm = false,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String? errorText;
  final bool confirm;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _error = widget.errorText;
  }

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _password.text;
    if (value.isEmpty) {
      setState(() => _error = 'Enter a password');
      return;
    }
    if (widget.confirm && value != _repeat.text) {
      setState(() => _error = 'Passwords do not match');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message),
            const SizedBox(height: 16),
            TextField(
              controller: _password,
              autofocus: true,
              obscureText: _obscure,
              textInputAction: widget.confirm
                  ? TextInputAction.next
                  : TextInputAction.done,
              onSubmitted: widget.confirm ? null : (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Password',
                errorText: widget.confirm ? null : _error,
                prefixIcon: const Icon(LucideIcons.keyRound, size: 16),
                suffixIcon: ViewerAction(
                  icon: _obscure ? LucideIcons.eye : LucideIcons.eyeOff,
                  tooltip: _obscure ? 'Show password' : 'Hide password',
                  iconSize: 16,
                  size: 36,
                  color: context.colors.mutedForeground,
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            if (widget.confirm) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _repeat,
                obscureText: _obscure,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Repeat password',
                  prefixIcon: const Icon(LucideIcons.keyRound, size: 16),
                  errorText: _error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

/// Asks for a 1-based page number.
Future<int?> showGoToPageDialog(
  BuildContext context, {
  required int pageCount,
  required int currentPage,
}) {
  return showDialog<int>(
    context: context,
    builder: (context) =>
        _GoToPageDialog(pageCount: pageCount, currentPage: currentPage),
  );
}

class _GoToPageDialog extends StatefulWidget {
  const _GoToPageDialog({required this.pageCount, required this.currentPage});

  final int pageCount;
  final int currentPage;

  @override
  State<_GoToPageDialog> createState() => _GoToPageDialogState();
}

class _GoToPageDialogState extends State<_GoToPageDialog> {
  late final _controller = TextEditingController(text: '${widget.currentPage}')
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: '${widget.currentPage}'.length,
    );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final page = int.tryParse(_controller.text.trim());
    if (page == null || page < 1 || page > widget.pageCount) {
      setState(() => _error = 'Enter 1 to ${widget.pageCount}');
      return;
    }
    Navigator.pop(context, page);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Go to page'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: 'Page (1-${widget.pageCount})',
          errorText: _error,
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Go')),
      ],
    );
  }
}

/// Text entry dialog; returns the trimmed text or null when cancelled.
Future<String?> showPdfTextInputDialog(
  BuildContext context, {
  required String title,
  String initialText = '',
  String? hint,
  String confirmLabel = 'OK',
  bool multiline = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _TextInputDialog(
      title: title,
      initialText: initialText,
      hint: hint,
      confirmLabel: confirmLabel,
      multiline: multiline,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.initialText,
    required this.confirmLabel,
    required this.multiline,
    this.hint,
  });

  final String title;
  final String initialText;
  final String? hint;
  final String confirmLabel;
  final bool multiline;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final _controller = TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: _controller,
          autofocus: true,
          minLines: widget.multiline ? 3 : 1,
          maxLines: widget.multiline ? 8 : 1,
          keyboardType: widget.multiline
              ? TextInputType.multiline
              : TextInputType.text,
          onSubmitted: widget.multiline
              ? null
              : (value) => Navigator.pop(context, value.trim()),
          decoration: InputDecoration(hintText: widget.hint),
        ),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Palette picker. Returns the chosen colour or null.
Future<Color?> showPdfColorPicker(BuildContext context, Color current) {
  return showDialog<Color>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Colour'),
        content: SizedBox(
          width: 296,
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final color in pdfPaletteColors)
                Semantics(
                  button: true,
                  selected: color.toARGB32() == current.toARGB32(),
                  label: 'Colour ${color.toARGB32().toRadixString(16)}',
                  child: InkResponse(
                    onTap: () => Navigator.pop(context, color),
                    radius: 22,
                    child: SizedBox.square(
                      dimension: 40,
                      child: Center(
                        child: ViewerSwatch(
                          color: color,
                          size: 28,
                          selected: color.toARGB32() == current.toARGB32(),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      );
    },
  );
}

enum UnsavedChoice { save, saveCopy, discard }

/// Asks what to do with unsaved edits. Null means "keep editing".
Future<UnsavedChoice?> showUnsavedPdfDialog(BuildContext context) {
  return showDialog<UnsavedChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Save changes?'),
      content: const Text('This PDF has changes that have not been saved.'),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: context.colors.destructive,
          ),
          onPressed: () => Navigator.pop(context, UnsavedChoice.discard),
          child: const Text('Discard'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(context, UnsavedChoice.saveCopy),
          child: const Text('Save as copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, UnsavedChoice.save),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

Future<bool> showPdfConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) => showViewerConfirm(
  context,
  title: title,
  message: message,
  confirmLabel: confirmLabel,
  destructive: destructive,
);
