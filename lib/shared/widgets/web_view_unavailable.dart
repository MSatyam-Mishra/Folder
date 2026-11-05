import 'dart:io';

import 'package:folder/core/router/file_opener.dart';
import 'package:folder/features/viewer_office/common/viewer_ui.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Shown instead of a web view where there is none (Linux:
/// flutter_inappwebview has no implementation there). Offers the browser or
/// another app instead.
class WebViewUnavailable extends StatelessWidget {
  const WebViewUnavailable({
    super.key,
    required this.file,
    required this.title,
    this.inBrowser = true,
  });

  final File file;
  final String title;

  /// Whether a web browser can show [file] (web pages, Markdown).
  final bool inBrowser;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: ViewerMessage(
            icon: LucideIcons.globe,
            title: title,
            message: 'Folder can only show this with a web view, which it '
                "doesn't have on Linux yet.",
            actions: [
              if (inBrowser)
                FilledButton.icon(
                  onPressed: () => launchUrl(Uri.file(file.path)),
                  icon: const Icon(LucideIcons.globe, size: 16),
                  label: const Text('Open in browser'),
                ),
              OutlinedButton.icon(
                onPressed: () => FileOpener.showOpenWith(context, file),
                icon: const Icon(LucideIcons.squareArrowOutUpRight, size: 16),
                label: const Text('Open with…'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
