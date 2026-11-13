import 'package:flutter/material.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/features/document_scanner/document_scanner.dart';
import 'package:folders/shared/ui/app_sheet.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

/// PDF or pictures, in a sheet; null if the user closed it.
Future<ScanFormat?> chooseScanFormat(BuildContext context) =>
    AppSheet.show<ScanFormat>(context, child: const ScanFormatList());

/// "Scan document" in the new-item sheet: asks PDF or pictures, scans, and
/// saves into [folder] (never a virtual one). The paths saved, or empty.
Future<List<String>> scanDocumentInto(BuildContext context, String folder) async {
  if (ExplorerPaths.isVirtual(folder)) return const [];
  final format = await chooseScanFormat(context);
  if (format == null || !context.mounted) return const [];
  return scanAndSave(context, folder, format);
}

/// Scans and saves into [folder] as [format], saying in a snack bar what
/// became of it.
Future<List<String>> scanAndSave(BuildContext context, String folder, ScanFormat format) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  void say(String text) => messenger?.showSnackBar(SnackBar(content: Text(text)));
  try {
    final scan = await DocumentScanner.scan(format);
    if (scan == null) return const [];
    final saved = await DocumentScanner.save(scan, format, folder);
    say(saved.length == 1 ? 'Saved ${p.basename(saved.single)}' : 'Saved ${saved.length} pages as pictures');
    return saved;
  } on ScanUnavailable catch (e) {
    say(e.message);
  } on Exception catch (e) {
    say("Couldn't save the scan: $e");
  }
  return const [];
}

/// The two ways to save a scan.
class ScanFormatList extends StatelessWidget {
  const ScanFormatList({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget row(ScanFormat format, IconData icon, String title, String subtitle) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, size: 20, color: colors.onSurfaceVariant),
          title: Text(title),
          subtitle: Text(subtitle),
          onTap: () => Navigator.pop(context, format),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Scan document', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        row(ScanFormat.pdf, LucideIcons.fileText, 'Save as PDF', 'One file with every page'),
        row(ScanFormat.jpeg, LucideIcons.images, 'Save as pictures', 'One JPEG for each page'),
      ],
    );
  }
}
