import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/remote_places.dart';
import 'package:folders/core/services/remote/remote_pool.dart';
import 'package:folders/core/services/remote/remote_secrets_store.dart';
import 'package:folders/features/clipboard/remote_clipboard.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/file_explorere/widgets/inline_rename.dart';
import 'package:folders/features/remote/place_editor.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_remote.dart';
import '../support/themed_app.dart';

/// Network places in the browser: the sidebar's section, browsing, making,
/// renaming and deleting, errors, copying to and from this device, and the
/// "Add a place" form, all on an in-memory server.
void main() {
  late FakeRemoteServer server;
  late MemoryRemoteSecretStore secrets;
  late Directory local;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ExplorerTabs.instance.reset();
    RemoteClipboard.reset();
    RemoteProtocols.clear();
    server = FakeRemoteServer()
      ..addFile('/Docs/a b.txt', 'hello there')
      ..addFile('/Docs/notes.md', '# notes')
      ..addFolder('/Music');
    registerFakeProtocol(
      {'': server},
      usesPrivateKey: true,
      options: const [
        RemoteOptionField(key: 'passive', label: 'Passive mode', defaultValue: 'true'),
        RemoteOptionField(key: 'domain', label: 'Domain', kind: RemoteOptionKind.text, hint: 'WORKGROUP'),
        RemoteOptionField(
          key: 'engine',
          label: 'Engine',
          kind: RemoteOptionKind.choice,
          defaultValue: 'dart',
          choices: {'dart': 'Built in', 'windows': "Windows' own"},
        ),
      ],
      discover: () => Stream.fromIterable(const [RemoteFoundHost(name: 'Attic NAS', host: '192.168.1.40', port: 2200)]),
    );
    secrets = MemoryRemoteSecretStore();
    RemotePlaces.instance.reset(secretStore: secrets);
    RemotePool.instance = RemotePool(closeIdle: false);
    await RemotePlaces.instance.save(
      const RemoteConnection(id: 'nas', protocol: RemoteProtocol.sftp, name: 'Home NAS', host: 'nas.local', username: 'me'),
      secrets: {'password': 'secret'},
    );
    local = await Directory.systemTemp.createTemp('network_places');
  });

  tearDown(() async {
    ExplorerTabs.instance.reset();
    await RemotePool.instance.closeAll();
    await local.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await settle(tester);
    }
    await settle(tester);
  }

  /// Taps [finder] in the form, scrolled into view first.
  Future<void> tapIn(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
  }

  Future<FileExplorerBloc> open(WidgetTester tester, String path, {String waitFor = 'a b.txt'}) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(TabbedExplorer(startFolder: path)));
    await until(tester, () => find.text(waitFor).evaluate().isNotEmpty);
    return BlocProvider.of<FileExplorerBloc>(tester.element(find.text(waitFor).first));
  }

  testWidgets('a place opens in the browser, named, with its files', (tester) async {
    final bloc = await open(tester, RemotePaths.build('nas', '/Docs'));
    expect(find.text('a b.txt'), findsOneWidget, reason: 'names decoded');
    expect(find.text('notes.md'), findsOneWidget);
    // The breadcrumb and the sidebar name the place.
    expect(find.text('Home NAS'), findsWidgets);
    expect(find.text('Network'), findsOneWidget);
    expect(find.text('Add a place'), findsOneWidget);
    // Up from its top goes back home, not into this device's folders.
    bloc.add(LoadDirectory(RemotePaths.build('nas', '/')));
    await until(tester, () => find.text('Music').evaluate().isNotEmpty);
    expect(find.text('Docs'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('New folder makes it on the place and renames it there', (tester) async {
    await open(tester, RemotePaths.build('nas', '/Docs'));
    await tester.tap(find.byIcon(LucideIcons.folderPlus).first, kind: PointerDeviceKind.mouse);
    await until(tester, () => find.byType(InlineRename).evaluate().isNotEmpty);
    expect(server.folders, contains('/Docs/New folder'));
    await tester.enterText(find.descendant(of: find.byType(InlineRename), matching: find.byType(TextField)), 'Trips 2026');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await until(tester, () => find.text('Trips 2026').evaluate().isNotEmpty);
    expect(server.folders, contains('/Docs/Trips 2026'));
    expect(server.folders, isNot(contains('/Docs/New folder')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('F2 renames and Delete deletes, for good, after asking', (tester) async {
    final bloc = await open(tester, RemotePaths.build('nas', '/Docs'));
    final state = bloc.state as FileExplorerLoaded;
    bloc.add(SetSelection({state.entities.firstWhere((e) => e.path.endsWith('notes.md'))}));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
    expect(find.text('Rename file'), findsOneWidget);
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'a b.txt');
    await tester.pump();
    expect(find.text('An item with this name already exists.'), findsOneWidget, reason: "checked against the place's listing");
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'todo.md');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await until(tester, () => find.text('todo.md').evaluate().isNotEmpty);
    expect(server.text('/Docs/todo.md'), '# notes');

    final renamed = (bloc.state as FileExplorerLoaded).entities.firstWhere((e) => e.path.endsWith('todo.md'));
    bloc.add(SetSelection({renamed}));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
    expect(find.textContaining('permanently deleted'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await until(tester, () => find.text('todo.md').evaluate().isEmpty);
    expect(server.exists('/Docs/todo.md'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a refused password shows Edit place', (tester) async {
    server.password = 'changed on the server';
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(themedApp(TabbedExplorer(startFolder: RemotePaths.build('nas', '/Docs'))));
    await until(tester, () => find.text('Edit place').evaluate().isNotEmpty);
    expect(find.text("Can't open this folder"), findsOneWidget);
    expect(find.textContaining('refused the user name or password'), findsOneWidget);
    await tester.tap(find.text('Edit place'));
    await until(tester, () => find.byType(PlaceEditor).evaluate().isNotEmpty);
    expect(find.text('Edit place'), findsWidgets);
    expect(find.widgetWithText(TextField, 'nas.local'), findsOneWidget);
    // The right password, saved: the folder opens.
    await tester.enterText(find.byKey(const ValueKey('field-password')), 'changed on the server');
    await tapIn(tester, find.byKey(const ValueKey('save-place')));
    await until(tester, () => find.text('a b.txt').evaluate().isNotEmpty);
    expect(await secrets.readAll('nas'), {'password': 'changed on the server'});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('copy from a place, paste on this device, and back', (tester) async {
    final bloc = await open(tester, RemotePaths.build('nas', '/Docs'));
    final file = (bloc.state as FileExplorerLoaded).entities.firstWhere((e) => e.path.endsWith('a%20b.txt'));
    bloc.add(SetSelection({file}));
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(RemoteClipboard.held, isNotNull, reason: 'kept in the app, not on the system clipboard');

    bloc.add(LoadDirectory(local.path));
    await until(tester, () => find.text('This folder is empty').evaluate().isNotEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await until(tester, () => File(p.join(local.path, 'a b.txt')).existsSync() && find.text('a b.txt').evaluate().isNotEmpty);
    expect(File(p.join(local.path, 'a b.txt')).readAsStringSync(), 'hello there');

    // And a local file to the place's Music folder.
    // Real file work runs outside the fake clock.
    await tester.runAsync(() => File(p.join(local.path, 'song.mp3')).writeAsString('la la'));
    bloc.add(LoadDirectory(local.path));
    await until(tester, () => find.text('song.mp3').evaluate().isNotEmpty);
    final song = (bloc.state as FileExplorerLoaded).entities.firstWhere((e) => e.path.endsWith('song.mp3'));
    bloc.add(SetSelection({song}));
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    bloc.add(LoadDirectory(RemotePaths.build('nas', '/Music')));
    await until(tester, () => find.text('This folder is empty').evaluate().isNotEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await until(tester, () => server.text('/Music/song.mp3') != null && find.text('song.mp3').evaluate().isNotEmpty);
    expect(server.text('/Music/song.mp3'), 'la la');
    expect(File(p.join(local.path, 'song.mp3')).existsSync(), isFalse, reason: 'cut: moved');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Add a place: the form follows the protocol, tests and saves', (tester) async {
    await open(tester, RemotePaths.build('nas', '/Docs'));
    await tester.tap(find.text('Add a place'));
    await until(tester, () => find.byType(PlaceEditor).evaluate().isNotEmpty);
    expect(find.text('Fake files'), findsOneWidget, reason: 'the protocol, from the registry');
    expect(find.text('Passive mode'), findsOneWidget, reason: "the protocol's own option");
    expect(find.byKey(const ValueKey('choose-key')), findsOneWidget, reason: 'it uses private keys');
    expect(find.text('2222'), findsOneWidget, reason: 'the default port as a hint');

    await tester.enterText(find.byKey(const ValueKey('field-host')), 'backup.lan');
    await tester.enterText(find.byKey(const ValueKey('field-user')), 'admin');
    await tester.enterText(find.byKey(const ValueKey('field-password')), 'wrong');
    await tapIn(tester, find.byKey(const ValueKey('test-connection')));
    await until(tester, () => find.textContaining('refused').evaluate().isNotEmpty);
    expect(find.textContaining('refused the user name or password'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('field-password')), 'secret');
    await tester.enterText(find.byKey(const ValueKey('field-folder')), '/Docs');
    await tapIn(tester, find.byKey(const ValueKey('option-passive')));
    await tester.pump();
    expect(find.text('Built in'), findsOneWidget, reason: 'a choice, at its default');
    await tester.ensureVisible(find.byKey(const ValueKey('option-domain')));
    await tester.enterText(find.byKey(const ValueKey('option-domain')), 'HOME');
    await tapIn(tester, find.byKey(const ValueKey('test-connection')));
    await until(tester, () => find.textContaining('Connected').evaluate().isNotEmpty);
    expect(find.textContaining('2 items in /Docs'), findsOneWidget);

    await tapIn(tester, find.byKey(const ValueKey('save-place')));
    await until(tester, () => find.byType(PlaceEditor).evaluate().isEmpty);
    final saved = RemotePlaces.instance.places.firstWhere((p) => p.host == 'backup.lan');
    expect(saved.name, 'backup.lan');
    expect(saved.username, 'admin');
    expect(saved.rootPath, '/Docs');
    expect(saved.options['passive'], 'false');
    expect(saved.options['domain'], 'HOME');
    expect(saved.options['engine'], 'dart');
    expect(await secrets.readAll(saved.id), {'password': 'secret'});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(RemotePlaces.prefsKey), isNot(contains('secret')));
    // In the sidebar, and opened at its folder.
    await until(tester, () => find.text('backup.lan').evaluate().length > 1);
    expect(find.text('backup.lan'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a service signed in through the browser shows Sign in', (tester) async {
    registerFakeProtocol(
      {'': server},
      protocol: RemoteProtocol.dropbox,
      label: 'Fake cloud',
      signIn: (context) async => const RemoteSignIn(
        name: 'Fake cloud (me@example.com)',
        username: 'me@example.com',
        secrets: {'password': 'secret', 'refreshToken': 'r1'},
      ),
    );
    await open(tester, RemotePaths.build('nas', '/Docs'));
    await tester.tap(find.text('Add a place'));
    await until(tester, () => find.byType(PlaceEditor).evaluate().isNotEmpty);
    await tester.tap(find.text('Fake cloud'));
    await tester.pump();
    expect(find.byKey(const ValueKey('field-host')), findsNothing);
    await tapIn(tester, find.byKey(const ValueKey('sign-in')));
    await until(tester, () => find.byType(PlaceEditor).evaluate().isEmpty);
    final saved = RemotePlaces.instance.places.firstWhere((p) => p.protocol == RemoteProtocol.dropbox);
    expect(saved.name, 'Fake cloud (me@example.com)');
    expect(await secrets.readAll(saved.id), {'password': 'secret', 'refreshToken': 'r1'});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a right-click on a place removes it, after asking', (tester) async {
    await open(tester, RemotePaths.build('nas', '/Docs'));
    await tester.tap(find.byKey(const ValueKey('place-nas')), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await until(tester, () => find.text('Remove').evaluate().isNotEmpty);
    expect(find.text('Rename…'), findsOneWidget);
    expect(find.text('Edit…'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await until(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
    expect(find.textContaining('Nothing on it is deleted'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await until(tester, () => RemotePlaces.instance.places.isEmpty);
    expect(await secrets.readAll('nas'), isEmpty);
    expect(server.files, isNotEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Find on network fills in a server it found', (tester) async {
    await open(tester, RemotePaths.build('nas', '/Docs'));
    await tester.tap(find.text('Add a place'));
    await until(tester, () => find.byType(PlaceEditor).evaluate().isNotEmpty);
    await tapIn(tester, find.byKey(const ValueKey('find-on-network')));
    await until(tester, () => find.text('Attic NAS').evaluate().isNotEmpty);
    expect(find.text('192.168.1.40:2200'), findsOneWidget);
    await tester.tap(find.text('Attic NAS'));
    await tester.pump();
    expect(find.widgetWithText(TextField, '192.168.1.40'), findsOneWidget);
    expect(find.widgetWithText(TextField, '2200'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Attic NAS'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a built-in place shows without the form, and stays', (tester) async {
    var fixed = 0;
    registerFakeProtocol(
      {'': server},
      protocol: RemoteProtocol.shizuku,
      label: 'App folders',
      builtInPlace: () => const RemoteConnection(id: 'shizuku', protocol: RemoteProtocol.shizuku, name: 'App folders'),
      fixAccess: (context) async {
        fixed++;
        return true;
      },
    );
    await open(tester, RemotePaths.build('nas', '/Docs'));
    expect(find.byKey(const ValueKey('place-shizuku')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('place-shizuku')), buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
    await until(tester, () => find.text('Open').evaluate().isNotEmpty);
    expect(find.text('Remove'), findsNothing);
    expect(find.text('Edit…'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await tester.tap(find.text('Add a place'));
    await until(tester, () => find.byType(PlaceEditor).evaluate().isNotEmpty);
    expect(find.text('App folders'), findsOneWidget, reason: 'only in the sidebar, not offered in the form');
    await tapIn(tester, find.text('Cancel'));
    await settle(tester);

    // Refused (it has no password here): "Set up access" runs the
    // protocol's own set-up, then tries again.
    await tester.tap(find.byKey(const ValueKey('place-shizuku')));
    await until(tester, () => find.text('Set up access').evaluate().isNotEmpty);
    expect(find.text('Edit place'), findsNothing);
    await tester.tap(find.text('Set up access'));
    await until(tester, () => fixed > 0);
    expect(fixed, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
