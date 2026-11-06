import 'dart:io';
import 'dart:typed_data';

import 'package:folders/shared/widgets/scrollbar_scroll_view.dart';
import 'package:folders/core/files/file_types.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/features/category_view/bloc/bloc/category_bloc.dart';
import 'package:folders/features/file_explorere/widgets/entity_meta.dart';
import 'package:folders/features/file_explorere/widgets/explorer_empty_state.dart';
import 'package:folders/features/file_explorere/widgets/file_list_item.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

class CategoryViewerScreen extends StatelessWidget {
  final RequestType categoryType;
  final String title;
  final String? path;

  const CategoryViewerScreen({
    super.key,
    required this.categoryType,
    required this.title,
    this.path,
  });

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) =>
          CategoryBloc()..add(LoadCategoryAssets(categoryType, path: path)),
      child: ExplorerScaffold(
        title: title,
        body: BlocBuilder<CategoryBloc, CategoryState>(
          builder: (context, state) {
            final top = DockedGlossyTopBar.contentTopInset(context);
            final statePadding = EdgeInsets.fromLTRB(24, top + 24, 24, 24);
            if (state is CategoryLoading) {
              return Padding(
                padding: EdgeInsets.only(top: top),
                child: const Center(
                  child: SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            if (state is CategoryError) {
              return ExplorerEmptyState(
                padding: statePadding,
                destructive: true,
                icon: LucideIcons.circleAlert,
                title: "Couldn't load ${title.toLowerCase()}",
                description: categoryType == RequestType.common
                    ? state.message
                    : "Folders couldn't read the device's media library. "
                        'Check that it may access photos and media, then try '
                        'again.',
                actions: [
                  FilledButton.icon(
                    onPressed: () => context.read<CategoryBloc>().add(
                      LoadCategoryAssets(categoryType, path: path),
                    ),
                    icon: const Icon(LucideIcons.refreshCw, size: 16),
                    label: const Text('Try again'),
                  ),
                ],
              );
            }
            if (state is CategoryLoaded) {
              if (state.groupedAssets.isEmpty) {
                final (icon, noun) = switch (categoryType) {
                  RequestType.image => (LucideIcons.image, 'photos'),
                  RequestType.video => (LucideIcons.clapperboard, 'videos'),
                  RequestType.audio => (LucideIcons.music, 'audio files'),
                  _ => (LucideIcons.folderOpen, 'files'),
                };
                return ExplorerEmptyState(
                  padding: statePadding,
                  icon: icon,
                  title: 'No $noun yet',
                  description: 'When there are $noun on this device, '
                      "they'll show up here, newest first.",
                );
              }
              return _GroupedAssets(
                groups: state.groupedAssets,
                asList: categoryType == RequestType.audio ||
                    categoryType == RequestType.common,
              );
            }
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }
}

/// Assets grouped by day: a date heading over a thumbnail grid (photos,
/// videos) or a list (audio, files). Built lazily with slivers.
class _GroupedAssets extends StatelessWidget {
  const _GroupedAssets({required this.groups, required this.asList});

  final Map<DateTime, List<dynamic>> groups;
  final bool asList;

  static final _weekday = DateFormat('EEEE, MMM d');
  static final _full = DateFormat.yMMMMd();

  static String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7 || day.year == now.year) return _weekday.format(day);
    return _full.format(day);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final media = MediaQuery.of(context);
    final wide = media.size.width >= 840;
    final pad = wide ? 24.0 : 12.0;
    final top = DockedGlossyTopBar.contentTopInset(context);

    final slivers = <Widget>[SliverToBoxAdapter(child: SizedBox(height: top))];
    for (final MapEntry(key: day, value: items) in groups.entries) {
      slivers.add(
        SliverPadding(
          padding: EdgeInsets.fromLTRB(pad + 4, 20, pad + 4, 10),
          sliver: SliverToBoxAdapter(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(_dayLabel(day), style: text.titleSmall),
                const SizedBox(width: 8),
                Text('${items.length}', style: text.bodySmall),
              ],
            ),
          ),
        ),
      );
      if (asList) {
        slivers.add(
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: wide ? 16 : 0),
            sliver: SliverList.builder(
              itemCount: items.length,
              itemBuilder: (context, index) => _ItemRow(item: items[index]),
            ),
          ),
        );
      } else {
        slivers.add(
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: pad),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: wide ? 168 : 112,
                crossAxisSpacing: 4,
                mainAxisSpacing: 4,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                if (item is AssetEntity) return _MediaTile(asset: item);
                if (item is File) return _FileTile(file: item);
                if (item is FileSystemEntity) {
                  return Center(child: EntityIcon(entity: item, size: 40));
                }
                return const SizedBox.shrink();
              },
            ),
          ),
        );
      }
    }
    slivers.add(
      SliverToBoxAdapter(child: SizedBox(height: media.padding.bottom + 24)),
    );
    return ScrollbarScrollView(slivers: slivers);
  }
}

Future<void> _openAsset(BuildContext context, AssetEntity asset) async {
  final file = await asset.file;
  if (file == null || !context.mounted) return;
  await FileOpener.open(context, file);
}

/// A file from a folder (desktop media categories): a thumbnail for
/// pictures, an icon otherwise.
class _FileTile extends StatelessWidget {
  const _FileTile({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    final kind = FileTypes.kindOf(file.path);
    final icon = Center(child: EntityIcon(entity: file, size: 40));
    return Material(
      color: context.colors.muted,
      child: InkWell(
        onTap: () => FileOpener.open(context, file),
        child: kind == FileKind.image
            ? Image.file(
                file,
                fit: BoxFit.cover,
                cacheWidth: 320,
                errorBuilder: (_, _, _) => icon,
              )
            : icon,
      ),
    );
  }
}

/// Square thumbnail; videos get a duration pill.
class _MediaTile extends StatelessWidget {
  const _MediaTile({required this.asset});

  final AssetEntity asset;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isVideo = asset.type == AssetType.video;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Material(
        color: colors.muted,
        child: InkWell(
          onTap: () => _openAsset(context, asset),
          child: Stack(
            fit: StackFit.expand,
            children: [
              AssetBytesThumbnail(asset: asset),
              if (isVideo)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: _DurationPill(duration: asset.videoDuration),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DurationPill extends StatelessWidget {
  const _DurationPill({required this.duration});

  final Duration duration;

  @override
  Widget build(BuildContext context) {
    // On top of a photo, so a fixed dark scrim reads in both themes.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(5, 2, 7, 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.play, size: 10, color: Colors.white),
            const SizedBox(width: 3),
            Text(
              _format(duration),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _format(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(h > 0 ? 2 : 1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// A row for audio assets and plain files.
class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final dynamic item;

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    if (item is FileSystemEntity) {
      return FileListItem(
        entity: item,
        isSelectionMode: false,
        isSelected: false,
        onTap: () {
          if (item is File) FileOpener.open(context, item);
        },
        onLongPress: () {},
      );
    }
    if (item is! AssetEntity) return const SizedBox.shrink();

    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final meta = [
      if (item.duration > 0) _format(item.videoDuration),
      EntityFormat.date(item.modifiedDateTime),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openAsset(context, item),
        child: SizedBox(
          height: 60,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.muted,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    LucideIcons.music,
                    size: 18,
                    color: colors.mutedForeground,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title ?? 'Untitled',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Thumbnail of a photo or video, loaded once per tile.
class AssetBytesThumbnail extends StatefulWidget {
  final AssetEntity asset;
  const AssetBytesThumbnail({super.key, required this.asset});

  @override
  State<AssetBytesThumbnail> createState() => _AssetBytesThumbnailState();
}

class _AssetBytesThumbnailState extends State<AssetBytesThumbnail> {
  late Future<Uint8List?> _bytes = _load();

  Future<Uint8List?> _load() => widget.asset.thumbnailDataWithSize(
        const ThumbnailSize.square(256),
      );

  @override
  void didUpdateWidget(AssetBytesThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) _bytes = _load();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data != null) {
          return Image.memory(
            data,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return ColoredBox(color: colors.muted);
        }
        return ColoredBox(
          color: colors.muted,
          child: Icon(
            LucideIcons.imageOff,
            size: 20,
            color: colors.mutedForeground,
          ),
        );
      },
    );
  }
}
