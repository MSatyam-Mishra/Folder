import 'package:flutter/material.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';

/// Shows what fills a drive or a folder.
class StorageAnalyzerScreen extends StatelessWidget {
  const StorageAnalyzerScreen({super.key});

  @override
  Widget build(BuildContext context) => const ExplorerScaffold(title: 'Storage analyzer', body: SizedBox.shrink());
}
