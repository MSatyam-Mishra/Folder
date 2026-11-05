import 'dart:io';

import 'package:folder/features/category_view/home_media.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:photo_manager/photo_manager.dart';

part 'category_event.dart';
part 'category_state.dart';

class CategoryBloc extends Bloc<CategoryEvent, CategoryState> {
  /// The last full list per media type, shown while it's refreshed.
  static final _mediaCache = <RequestType, Map<DateTime, List<dynamic>>>{};

  static Map<DateTime, List<dynamic>> _snapshot(
    Map<DateTime, List<dynamic>> groups,
  ) => {for (final e in groups.entries) e.key: List.unmodifiable(e.value)};

  static int _length(Map<DateTime, List<dynamic>> groups) =>
      groups.values.fold(0, (sum, list) => sum + list.length);

  /// Two newest-first lists of (time, item) merged into groups by day,
  /// newest first.
  @visibleForTesting
  static Map<DateTime, List<dynamic>> mergeByDay(
    List<(DateTime, Object)> a,
    List<(DateTime, Object)> b,
  ) {
    final groups = <DateTime, List<dynamic>>{};
    var i = 0, j = 0;
    while (i < a.length || j < b.length) {
      final (t, item) =
          j >= b.length || (i < a.length && !a[i].$1.isBefore(b[j].$1))
          ? a[i++]
          : b[j++];
      (groups[DateTime(t.year, t.month, t.day)] ??= []).add(item);
    }
    return groups;
  }

  CategoryBloc() : super(CategoryLoading()) {
    on<LoadCategoryAssets>(_onLoadCategoryAssets);
  }

  Future<void> _onLoadCategoryAssets(
    LoadCategoryAssets event,
    Emitter<CategoryState> emit,
  ) async {
    emit(CategoryLoading());
    // macOS: the search for loose videos, which runs while the library
    // loads.
    Future<void>? looseVideos;
    try {
      // A folder: its files grouped by day.
      if (event.type == RequestType.common) {
        final dir = Directory(event.path!);
        if (await dir.exists()) {
          // All files under the folder, newest first. Each file is stat'ed
          // once (not inside the sort comparator).
          final files = await dir
              .list(recursive: true)
              .handleError((Object _) {})
              .where((e) => e is File)
              .toList();
          final modified = <FileSystemEntity, DateTime>{};
          for (final file in files) {
            try {
              modified[file] = (await file.stat()).modified;
            } catch (_) {
              modified[file] = DateTime.fromMillisecondsSinceEpoch(0);
            }
          }
          files.sort((a, b) => modified[b]!.compareTo(modified[a]!));

          final groupedFiles = groupBy(files, (FileSystemEntity file) {
            final m = modified[file]!;
            return DateTime(m.year, m.month, m.day);
          });
          emit(CategoryLoaded(groupedFiles));
        } else {
          emit(CategoryError('Folder not found: ${event.path}'));
        }
        return; // Exit after handling this case
      }
      // Windows and Linux have no media library (photo_manager): look
      // through the user's Pictures, Videos or Music folders instead. The
      // macOS Photos library holds no audio, so audio comes from there too.
      if (Platform.isWindows ||
          Platform.isLinux ||
          (Platform.isMacOS && event.type == RequestType.audio)) {
        final files = await HomeMedia.find(event.type);
        final groups = <DateTime, List<dynamic>>{};
        for (final file in files) {
          final m = file.modified;
          (groups[DateTime(m.year, m.month, m.day)] ??= []).add(File(file.path));
        }
        if (!emit.isDone) emit(CategoryLoaded(groups));
        return;
      }

      // Photos, videos or audio from the media library, newest first.
      // The last list shows at once; the newest page then replaces it and
      // older pages follow in the background, so big libraries open fast.
      final cached = _mediaCache[event.type];
      if (cached != null) emit(CategoryLoaded(cached));

      // macOS: loose videos in Movies, Downloads and Desktop as well,
      // merged with the library by date. They're searched for while the
      // library loads: they show at once if nothing is on screen yet, and
      // join the library's next page otherwise. Photos keeps its copies
      // inside its own library, which isn't searched, so they aren't listed
      // twice.
      var loose = const <(DateTime, Object)>[];
      if (Platform.isMacOS && event.type == RequestType.video) {
        looseVideos = HomeMedia.find(event.type).then((files) {
          loose = [for (final file in files) (file.modified, File(file.path))];
          if (loose.isNotEmpty && state is! CategoryLoaded && !emit.isDone) {
            emit(CategoryLoaded(mergeByDay(const [], loose)));
          }
        }, onError: (Object _) {});
      }
      Map<DateTime, List<dynamic>> withLoose(
        Map<DateTime, List<dynamic>> groups,
      ) => loose.isEmpty
          ? _snapshot(groups)
          : mergeByDay([
              for (final list in groups.values)
                for (final AssetEntity asset in list)
                  (asset.createDateTime, asset),
            ], loose);

      // Only the "all" album: listing every album too would repeat each
      // photo once per album it's in.
      final albums = await PhotoManager.getAssetPathList(
        type: event.type,
        onlyAll: true,
        filterOption: FilterOptionGroup(
          orders: [
            const OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );
      if (albums.isEmpty) {
        await looseVideos;
        final result = loose.isEmpty
            ? const <DateTime, List<dynamic>>{}
            : mergeByDay(const [], loose);
        _mediaCache[event.type] = result;
        emit(CategoryLoaded(result));
        return;
      }
      final album = albums.first;
      final total = await album.assetCountAsync;
      final groups = <DateTime, List<dynamic>>{};
      var start = 0;
      var pageSize = 120;
      while (start < total) {
        final end = start + pageSize > total ? total : start + pageSize;
        final page = await album.getAssetListRange(start: start, end: end);
        if (page.isEmpty || emit.isDone || isClosed) break;
        for (final asset in page) {
          final t = asset.createDateTime;
          (groups[DateTime(t.year, t.month, t.day)] ??= []).add(asset);
        }
        start = end;
        pageSize = 1000;
        // Keep the cached list until the new one has caught up with it
        // (the full list is shown below in any case).
        if (cached == null || start + loose.length >= _length(cached)) {
          emit(CategoryLoaded(withLoose(groups)));
        }
      }
      await looseVideos;
      if (!emit.isDone && !isClosed) {
        final result = withLoose(groups);
        _mediaCache[event.type] = result;
        emit(CategoryLoaded(result));
      }
    } catch (e) {
      // Keep showing what's already loaded. On macOS the loose videos may
      // still turn up and show on their own.
      if (state is! CategoryLoaded) await looseVideos;
      if (state is! CategoryLoaded && !emit.isDone) {
        emit(CategoryError(e.toString()));
      }
    }
  }
}
