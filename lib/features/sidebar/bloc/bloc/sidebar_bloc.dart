import 'dart:io';

import 'package:folders/core/repositories/file_repository.dart';
import 'package:folders/core/services/device_files.dart';
import 'package:folders/features/category_view/home_media.dart';
import 'package:folders/features/sidebar/model/category_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;

part 'sidebar_event.dart';
part 'sidebar_state.dart';

class SidebarBloc extends Bloc<SidebarEvent, SidebarState> {
  SidebarBloc() : super(SidebarLoading()) {
    on<LoadSidebarData>(_onLoadSidebarData);
  }

  /// Shows the categories at once; storage volumes and counts fill in as
  /// they're found.
  Future<void> _onLoadSidebarData(
    LoadSidebarData event,
    Emitter<SidebarState> emit,
  ) async {
    final counts = <String, int>{};
    var volumes = const <Directory>[];
    void publish() {
      if (!emit.isDone) {
        emit(SidebarLoaded(_categories(counts), externalStorage: volumes));
      }
    }

    publish();
    try {
      volumes = await LocalFileRepository().getStorageVolumes();
      publish();
    } catch (e) {
      debugPrint('Sidebar: no storage volumes: $e');
    }

    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      try {
        final permission = await PhotoManager.requestPermissionExtend();
        if (permission.hasAccess) {
          final media = await Future.wait([
            PhotoManager.getAssetCount(type: RequestType.image),
            PhotoManager.getAssetCount(type: RequestType.video),
            PhotoManager.getAssetCount(type: RequestType.audio),
          ]);
          counts
            ..['Photos'] = media[0]
            ..['Video'] = media[1]
            ..['Audio'] = media[2];
          publish();
        }
      } catch (e) {
        debugPrint('Sidebar: media counts failed: $e');
      }
    }

    // macOS: the Photos library has no audio, and Video also lists loose
    // files, so count what those categories show. Those folders are
    // searched while Documents and Archives are counted.
    Future<void> countHomeMedia() async {
      try {
        final found = await Future.wait([
          HomeMedia.find(RequestType.audio),
          HomeMedia.find(RequestType.video),
        ]);
        counts
          ..['Audio'] = found[0].length
          ..['Video'] = (counts['Video'] ?? 0) + found[1].length;
        publish();
      } catch (e) {
        debugPrint('Sidebar: home media counts failed: $e');
      }
    }

    final homeMedia = Platform.isMacOS ? countHomeMedia() : null;
    for (final (name, group) in const [
      ('Documents', DeviceFileGroup.documents),
      ('Archives', DeviceFileGroup.archives),
    ]) {
      try {
        counts[name] = (await DeviceFiles.find(group)).length;
        publish();
      } catch (e) {
        debugPrint('Sidebar: $name count failed: $e');
      }
    }
    await homeMedia;
  }

  static List<Category> _categories(Map<String, int> counts) => [
        for (final (icon, name, color) in [
          (LucideIcons.image, 'Photos', Colors.purple.shade300),
          (LucideIcons.clapperboard, 'Video', Colors.red.shade300),
          (LucideIcons.music, 'Audio', Colors.orange.shade300),
          (LucideIcons.fileText, 'Documents', Colors.blue.shade300),
          (LucideIcons.archive, 'Archives', Colors.brown.shade300),
          (LucideIcons.download, 'Downloads', Colors.green.shade300),
          (LucideIcons.layoutGrid, 'Apps', Colors.teal.shade300),
          (LucideIcons.lock, 'Vault', Colors.indigo.shade300),
        ])
          Category(
            icon: icon,
            name: name,
            fileCount: counts[name] ?? 0,
            color: color,
          ),
      ];
}
