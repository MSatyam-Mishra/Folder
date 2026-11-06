import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:flutter/material.dart';

/// File icon in the explorer; see [FileIcon] for how icons are chosen.
class FileTypeIcon extends StatelessWidget {
  final String filePath;
  final double size;

  const FileTypeIcon({super.key, required this.filePath, this.size = 42});

  @override
  Widget build(BuildContext context) => FileIcon(path: filePath, size: size);
}
