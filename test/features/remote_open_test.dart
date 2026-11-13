import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/remote_entities.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_places.dart';
import 'package:folders/core/services/remote/remote_pool.dart';
import 'package:folders/core/services/remote/remote_secrets_store.dart';
import 'package:folders/features/remote/remote_open.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_remote.dart';
import '../support/themed_app.dart';

/// Files on a place open from a downloaded copy, and what an editor
/// changed is offered back.
void main() {
  late FakeRemoteServer server;
  late Directory cache;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    RemoteProtocols.clear();
    server = FakeRemoteServer()..addFile('/Docs/plan.txt', 'first draft');
    registerFakeProtocol({'': server});
    RemotePlaces.instance.reset(secretStore: MemoryRemoteSecretStore());
    RemotePool.instance = RemotePool(closeIdle: false);
    await RemotePlaces.instance.save(
      const RemoteConnection(id: 'nas', protocol: RemoteProtocol.sftp, name: 'NAS', host: 'nas.local'),
      secrets: {'password': 'secret'},
    );
    cache = await Directory.systemTemp.createTemp('remote_open');
    RemoteOpener.cacheRoot = () async => cache;
  });

  tearDown(() async {
    await RemotePool.instance.closeAll();
    await cache.delete(recursive: true);
  });

  Future<BuildContext> app(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(themedApp(Builder(builder: (c) {
      context = c;
      return const Scaffold(body: SizedBox());
    })));
    return context;
  }

  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 80 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<RemoteFile> remoteFile() async =>
      RemoteFile('nas', await RemotePool.instance.run('nas', (fs) => fs.stat('/Docs/plan.txt')));

  testWidgets('an edited copy is uploaded when the user says so', (tester) async {
    final context = await app(tester);
    final file = await tester.runAsync(remoteFile);
    File? opened;
    String? downloaded;
    bool? result;
    var finished = false;
    RemoteOpener.openThrough(context, file!, (local) async {
      opened = local;
      downloaded = local.readAsStringSync();
      // The editor saves.
      await local.writeAsString('second draft, longer');
      return null;
    }).then((r) {
      result = r;
      finished = true;
    });
    await settle(tester, () => find.text('Upload the changes?').evaluate().isNotEmpty);
    expect(p.isWithin(cache.path, opened!.path), isTrue, reason: 'downloaded to the cache');
    expect(downloaded, 'first draft');
    expect(find.textContaining('Save the changes back to NAS?'), findsOneWidget);
    await tester.tap(find.text('Upload'));
    await settle(tester, () => finished);
    expect(result, isTrue);
    expect(server.text('/Docs/plan.txt'), 'second draft, longer');
  });

  testWidgets('kept here only: nothing is uploaded; unchanged: nothing is asked', (tester) async {
    final context = await app(tester);
    final file = await tester.runAsync(remoteFile);
    var finished = false;
    RemoteOpener.openThrough(context, file!, (local) async {
      await local.writeAsString('my own copy');
      return null;
    }).then((_) => finished = true);
    await settle(tester, () => find.text('Keep here only').evaluate().isNotEmpty);
    await tester.tap(find.text('Keep here only'));
    await settle(tester, () => finished);
    expect(server.text('/Docs/plan.txt'), 'first draft');

    finished = false;
    RemoteOpener.openThrough(context, file, (local) async => null).then((_) => finished = true);
    await settle(tester, () => finished);
    expect(find.text('Upload the changes?'), findsNothing);
  });

  testWidgets('a copy saved beside it is added to the folder', (tester) async {
    final context = await app(tester);
    final file = await tester.runAsync(remoteFile);
    var finished = false;
    RemoteOpener.openThrough(context, file!, (local) async {
      await File(p.join(local.parent.path, 'plan (edited).txt')).writeAsString('a copy');
      return true;
    }).then((_) => finished = true);
    await settle(tester, () => find.text('Upload').evaluate().isNotEmpty);
    expect(find.textContaining('was saved beside it'), findsOneWidget);
    await tester.tap(find.text('Upload'));
    await settle(tester, () => finished);
    expect(server.text('/Docs/plan (edited).txt'), 'a copy');
    expect(server.text('/Docs/plan.txt'), 'first draft');
  });
}
