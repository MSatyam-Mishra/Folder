import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:folder/core/formats/archive_backend.dart';
import 'package:folder/core/formats/archive_extract.dart';
import 'package:folder/core/formats/archive_open.dart';
import 'package:folder/core/formats/archive_session.dart';
import 'package:path/path.dart' as p;

/// A listed archive member (kept for callers of [ArchiveService.listContents]).
class ArchiveItem {
  final String name;
  final int size;
  final bool isFile;

  /// The underlying [ArcEntry].
  final dynamic originalObject;

  ArchiveItem({
    required this.name,
    required this.size,
    required this.isFile,
    this.originalObject,
  });
}

/// Archive helpers for the rest of the app.
///
/// Reading goes through the format-neutral readers in `lib/core/formats/`
/// (ZIP family, TAR + gzip/bzip2/xz, RAR 4/5, 7z, ISO 9660/UDF). Prefer
/// [ArchiveSession]/[ExtractJob] from UI code: they run in background
/// isolates. The methods here run on the caller's isolate.
class ArchiveService {
  /// Lists the contents of [file] (format detected from content).
  Future<List<ArchiveItem>> listContents(File file, {String? password}) async {
    final opened = await openArchive(file.path, password: password);
    try {
      return [
        for (final e in opened.backend.entries)
          ArchiveItem(
            name: e.path,
            size: e.size,
            isFile: !e.isDirectory,
            originalObject: e,
          ),
      ];
    } finally {
      await opened.backend.close();
    }
  }

  /// Extracts the whole archive into [destination] in a background isolate,
  /// replacing existing files. Throws [ArcException] on failure.
  Future<ExtractResult> extractAll(
    File archiveFile,
    Directory destination, {
    String? password,
    ConflictPolicy policy = ConflictPolicy.overwrite,
  }) async {
    final job = await ExtractJob.start(ExtractRequest(
      archivePath: archiveFile.path,
      destination: destination.path,
      password: password,
      policy: policy == ConflictPolicy.ask ? ConflictPolicy.overwrite : policy,
    ));
    await for (final event in job.events) {
      if (event is ExtractDone) return event.result;
      if (event is ExtractFailed) throw event.error;
    }
    throw ArcException(ArcErrorKind.io, 'Extraction stopped unexpectedly.');
  }

  /// Compresses a list of files into a destination .zip file
  Future<void> compressFiles(List<File> files, File destinationZip) async {
    final encoder = ZipFileEncoder();
    encoder.create(destinationZip.path);

    for (final file in files) {
      final filename = p.basename(file.path);
      await encoder.addFile(file, filename);
    }

    encoder.close();
  }
}
