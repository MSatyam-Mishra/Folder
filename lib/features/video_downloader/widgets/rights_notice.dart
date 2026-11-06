import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:flutter/material.dart';

const rightsNoticeText =
    'Only download videos and audio that you own, that you have permission '
    'to download, or that are offered for free download (for example under '
    'a Creative Commons license or in the public domain). Downloading other '
    "people's copyrighted content without permission may be illegal and "
    "against the site's terms.";

/// The first-use notice; true when the user accepted it.
Future<bool> showRightsNotice(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Row(
        children: [
          Icon(LucideIcons.scale, size: 18),
          SizedBox(width: 10),
          Expanded(child: Text('Before you download')),
        ],
      ),
      content: const SizedBox(
        width: 440,
        child: SingleChildScrollView(child: Text(rightsNoticeText)),
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('I understand'),
        ),
      ],
    ),
  );
  return ok ?? false;
}
