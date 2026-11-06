import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:flutter/material.dart';

/// A video thumbnail from the web, with a placeholder while it loads or
/// when there is none.
class MediaThumbnail extends StatelessWidget {
  const MediaThumbnail({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.radius = 8,
    this.icon = LucideIcons.film,
  });

  final String? url;
  final double? width;
  final double? height;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final placeholder = Container(
      width: width,
      height: height,
      color: colors.muted,
      alignment: Alignment.center,
      child: Icon(
        icon,
        color: colors.mutedForeground,
        size: ((height ?? 48) * 0.4).clamp(16, 40),
      ),
    );
    final u = url;
    Widget child = placeholder;
    if (u != null && u.startsWith('http')) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      child = Image.network(
        u,
        width: width,
        height: height,
        fit: BoxFit.cover,
        // Decode at display size: thumbnails can be 1280px wide.
        cacheWidth: width == null ? null : (width! * dpr).round(),
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => placeholder,
        frameBuilder: (context, image, frame, sync) =>
            frame == null && !sync ? placeholder : image,
      );
    }
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: child);
  }
}
