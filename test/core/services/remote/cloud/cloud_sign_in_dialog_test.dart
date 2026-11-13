import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/cloud/cloud_service.dart';
import 'package:folders/core/services/remote/cloud/cloud_sign_in_dialog.dart';
import 'package:folders/core/services/remote/cloud/google_drive_fs.dart';
import 'package:folders/core/services/remote/remote_fs.dart';

/// Signs in when told to, without a browser or a network.
class _FakeFlow extends CloudSignInFlow {
  _FakeFlow() : super(GoogleDriveService());

  final result = Completer<RemoteSignIn?>();
  bool cancelled = false;

  @override
  Uri? get url => Uri.parse('https://accounts.example/auth?x=1');

  @override
  Future<RemoteSignIn?> run({
    required Future<bool> Function(Uri url) openBrowser,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    await openBrowser(url!);
    return result.future;
  }

  @override
  void cancel() {
    cancelled = true;
    if (!result.isCompleted) result.complete(null);
  }
}

void main() {
  late _FakeFlow flow;
  late List<Uri> opened;
  Object? outcome;
  var finished = false;

  Future<void> start(WidgetTester tester, {bool browserOpens = true}) async {
    flow = _FakeFlow();
    opened = [];
    outcome = null;
    finished = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            try {
              outcome = await showCloudSignIn(context, flow.service, flow: flow, openBrowser: (url) async {
                opened.add(url);
                return browserOpens;
              });
            } on Object catch (e) {
              outcome = e;
            }
            finished = true;
          },
          child: const Text('go'),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('waits for the browser and hands back what it signed in', (tester) async {
    await start(tester);
    expect(find.text('Sign in to Google Drive'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(opened, hasLength(1));

    await tester.tap(find.text('Open again'));
    await tester.pump();
    expect(opened, hasLength(2));

    flow.result.complete(const RemoteSignIn(name: 'Google Drive (me@example.com)', secrets: {'accessToken': 'a'}));
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect((outcome as RemoteSignIn?)?.name, 'Google Drive (me@example.com)');
    expect(find.text('Sign in to Google Drive'), findsNothing);
  });

  testWidgets('Cancel gives up and returns nothing', (tester) async {
    await start(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(flow.cancelled, isTrue);
    expect(finished, isTrue);
    expect(outcome, isNull);
  });

  testWidgets('shows the link when no browser opened, and passes errors on', (tester) async {
    await start(tester, browserOpens: false);
    expect(find.textContaining("Couldn't open a browser"), findsOneWidget);
    expect(find.text('https://accounts.example/auth?x=1'), findsOneWidget);

    flow.result.completeError(const RemoteException(RemoteErrorKind.auth, 'refused'));
    await tester.pumpAndSettle();
    expect(outcome, isA<RemoteException>());
  });
}
