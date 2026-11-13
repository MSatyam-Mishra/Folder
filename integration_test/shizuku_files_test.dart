import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/shizuku/shizuku.dart';
import 'package:folders/core/services/remote/shizuku/shizuku_fs.dart';
import 'package:integration_test/integration_test.dart';

/// On an Android device with Shizuku installed and started:
/// `flutter test integration_test/shizuku_files_test.dart -d DEVICE`
/// The first run makes Shizuku ask whether Folders may use it: tap Allow.
///
/// Drives the App folders place directly: lists Android/data and obb, and
/// writes, reads, renames and deletes in another app's folder. Each step
/// prints a `SHIZUKU:` line, for the record of what works on which Android.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  void log(String line) => debugPrint('SHIZUKU: $line');

  Future<List<int>> readAll(ShizukuFileSystem fs, String path, {int start = 0, int? end}) =>
      fs.openRead(path, start: start, end: end).expand((c) => c).toList();

  testWidgets('App folders through Shizuku', (tester) async {
    await tester.runAsync(() async {
      var status = await Shizuku.status();
      log('Android API ${status.sdk}, Shizuku ${status.state.name}, version ${status.version}, uid ${status.uid}');
      expect(status.running, isTrue, reason: 'start Shizuku first');
      if (status.state == ShizukuState.notAllowed) {
        log('asking for permission: tap Allow');
        await Shizuku.requestPermission();
        status = await Shizuku.status();
      }
      expect(status.state, ShizukuState.ready);
      ShizukuPlaces.sdk = status.sdk;
      expect(ShizukuPlaces.redirect('/storage/emulated/0/Android/data/x'), status.sdk >= 30 ? 'explorer://remote/shizuku/data/x' : isNull);

      // What the app sees without Shizuku.
      try {
        final plain = Directory('${ShizukuPlaces.androidFolder}/data').listSync().map((e) => e.path.split('/').last).toList();
        log('without Shizuku, Android/data shows ${plain.length}: $plain');
      } on FileSystemException catch (e) {
        log('without Shizuku, Android/data refuses: ${e.osError?.message ?? e.message}');
      }

      final fs = ShizukuFileSystem(ShizukuPlaces.connection);
      await fs.connect();
      try {
        final top = (await fs.list('/')).map((e) => e.name).toSet();
        log('Android folder: $top');
        expect(top, containsAll(['data', 'obb']));

        final apps = (await fs.list('/data')).where((e) => e.isDirectory).map((e) => e.name).toList();
        log('Android/data through Shizuku shows ${apps.length}: $apps');
        // Another maker's app, to be sure it isn't only Folders' own.
        final others = apps.where((a) => !a.startsWith('com.synqixlabs.')).toList();
        expect(others, isNotEmpty, reason: "other apps' folders show");
        final app = others.contains('com.android.chrome') ? 'com.android.chrome' : others.first;

        final stamp = DateTime.now().millisecondsSinceEpoch;
        final folder = '/data/$app/folders-test-$stamp';
        await fs.createDirectory(folder);
        expect((await fs.stat(folder)).isDirectory, isTrue);
        log('made a folder in Android/data/$app');

        final bytes = Uint8List.fromList(List.generate(1500 * 1024, (i) => Random(i).nextInt(256)));
        final watch = Stopwatch()..start();
        await fs.write('$folder/a.bin', Stream.fromIterable([for (var i = 0; i < bytes.length; i += 65536) bytes.sublist(i, min(i + 65536, bytes.length))]));
        log('wrote 1.5 MB in ${watch.elapsedMilliseconds} ms');
        expect((await fs.stat('$folder/a.bin')).size, bytes.length);
        watch.reset();
        expect(await readAll(fs, '$folder/a.bin'), bytes);
        log('read it back in ${watch.elapsedMilliseconds} ms');
        expect(await readAll(fs, '$folder/a.bin', start: 1000, end: 700000), bytes.sublist(1000, 700000));
        log('read a part of it');

        // Speed, without the test's own copying of bytes.
        const mb = 32;
        final block = Uint8List(1024 * 1024);
        watch.reset();
        await fs.write('$folder/big.bin', Stream.fromIterable([for (var i = 0; i < mb; i++) block]));
        final wrote = watch.elapsedMilliseconds;
        watch.reset();
        var total = 0;
        await for (final chunk in fs.openRead('$folder/big.bin')) {
          total += chunk.length;
        }
        expect(total, mb * 1024 * 1024);
        log('$mb MB: wrote in $wrote ms, read in ${watch.elapsedMilliseconds} ms');
        await fs.delete('$folder/big.bin');

        await expectLater(fs.write('$folder/a.bin', Stream.value([1])), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.alreadyExists)));
        await fs.write('$folder/a.bin', Stream.value([1, 2, 3]), overwrite: true);
        expect(await readAll(fs, '$folder/a.bin'), [1, 2, 3]);
        log('overwrote it');

        await fs.rename('$folder/a.bin', '$folder/b.bin');
        await expectLater(fs.stat('$folder/a.bin'), throwsA(isA<RemoteException>().having((e) => e.kind, 'kind', RemoteErrorKind.notFound)));
        expect((await fs.list(folder)).single.name, 'b.bin');
        log('renamed it');

        await fs.createDirectory('$folder/inner');
        await fs.write('$folder/inner/c.txt', Stream.value('hello'.codeUnits));
        await fs.delete(folder);
        await expectLater(fs.stat(folder), throwsA(isA<RemoteException>()));
        log('deleted the folder with what was in it');

        final obbApps = (await fs.list('/obb')).map((e) => e.name).toList();
        log('Android/obb shows ${obbApps.length}: $obbApps');
        final obb = '/obb/com.synqixlabs.test$stamp';
        await fs.createDirectory(obb);
        await fs.write('$obb/main.1.obb', Stream.value(bytes.sublist(0, 4096)));
        expect(await readAll(fs, '$obb/main.1.obb'), bytes.sublist(0, 4096));
        await fs.rename('$obb/main.1.obb', '$obb/main.2.obb');
        await fs.delete(obb);
        await expectLater(fs.stat(obb), throwsA(isA<RemoteException>()));
        log('made, wrote, read, renamed and deleted in Android/obb');
      } finally {
        await fs.close();
      }
    });
  });
}
