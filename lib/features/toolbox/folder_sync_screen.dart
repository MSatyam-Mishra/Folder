import 'package:flutter/material.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';

/// Compares two folders and makes them match.
class FolderSyncScreen extends StatelessWidget {
  const FolderSyncScreen({super.key});

  @override
  Widget build(BuildContext context) => const ExplorerScaffold(title: 'Folder sync', body: SizedBox.shrink());
}
