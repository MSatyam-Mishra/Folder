import 'dart:async';
import 'dart:io';

import 'package:folders/core/services/localsend/localsend.dart';
import 'package:folders/core/services/video_downloader/downloader_backend.dart';
import 'package:folders/core/services/video_downloader/video_downloader_controller.dart';
import 'package:folders/features/localsend/localsend_controller.dart';
import 'package:folders/features/localsend/screens/localsend_screen.dart';
import 'package:folders/features/video_downloader/screens/video_downloader_screen.dart';
import 'package:folders/features/video_downloader/screens/video_downloader_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/screenshots.dart';
import '../video_downloader/video_downloader_screen_test.dart' show FakeBackend;
import 'viewer_shot_helpers.dart';

/// Nearby sharing without sockets: fixed settings, devices and history.
class _FakeLsController extends LocalSendController {
  _FakeLsController(List<FileSystemEntity> items) : super(initialItems: items);

  @override
  Future<void> start() async {
    starting = false;
    received.add(LsReceivedItem(
      path: p.join(Directory.systemTemp.path, 'Invoice March.pdf'),
      fileName: 'Invoice March.pdf',
      size: 182000,
      from: 'Office PC',
      at: DateTime(2026, 10, 21, 9, 30),
    ));
    addItems(const []);
  }

  @override
  LsSettings? get settings => const LsSettings(
        alias: 'Satyam’s Pixel',
        destination: '/storage/emulated/0/Download/LocalSend',
        httpFingerprint: 'x',
        deviceType: LsDeviceType.mobile,
        pin: '1234',
        autoAcceptTrusted: true,
      );

  @override
  List<LsDevice> get devices => [
        for (final (alias, model, type, ip) in [
          ('Office PC', 'Windows', LsDeviceType.desktop, '192.168.1.31'),
          ('Asha’s iPhone', 'iPhone 15', LsDeviceType.mobile, '192.168.1.44'),
        ])
          LsDevice(
            ip: ip,
            info: LsDeviceInfo(
              alias: alias,
              version: '2.1',
              fingerprint: alias,
              port: 53317,
              protocol: LsProtocol.https,
              deviceModel: model,
              deviceType: type,
            ),
            lastSeen: DateTime(2026),
            source: LsDiscoverySource.multicast,
          ),
      ];

  @override
  List<String> get localAddresses => const ['192.168.1.23'];

  @override
  int? get serverPort => 53317;

  @override
  String? get fingerprint => '3F:A2:91:0C:7E:55:D1:08:B4:6A:21:9F';
}

void main() {
  late Directory dir;

  setUpAll(() async {
    if (!screenshotsEnabled) return;
    await loadAppFonts();
    dir = await Directory.systemTemp.createTemp('viewer_share_shots_');
    await File(p.join(dir.path, 'Holiday.jpg')).writeAsBytes(List.filled(240000, 1));
    await Directory(p.join(dir.path, 'Project')).create();
    for (final n in ['a.dart', 'b.dart', 'README.md']) {
      await File(p.join(dir.path, 'Project', n)).writeAsString('x' * 3000);
    }
  });

  tearDownAll(() async {
    if (screenshotsEnabled) {
      await dir.delete(recursive: true).catchError((_) => dir);
    }
  });

  viewerShots('localsend', (tester, shot) async {
    final controller = _FakeLsController([
      File(p.join(dir.path, 'Holiday.jpg')),
      Directory(p.join(dir.path, 'Project')),
    ]);
    await shot.open(LocalSendScreen(controller: controller));
    await settle(tester, rounds: 8);
    if (shot.tablet) {
      await shot.shot('localsend_send');
    } else {
      // Without items passed in, phones open on the Receive tab.
      await shot.shot('localsend_receive');
      await tester.tap(find.text('Send').first);
      await settle(tester);
      await shot.shot('localsend_send');
    }
    await tester.tap(find.byTooltip('Settings'));
    await settle(tester);
    await shot.shot('localsend_settings');
  });

  viewerShots('video downloader', (tester, shot) async {
    final backend = FakeBackend();
    VideoDownloaderController.instance = VideoDownloaderController(backend);
    await shot.open(
      const VideoDownloaderScreen(initialUrl: 'https://example.com/watch/abc'),
    );
    await settle(tester);
    await shot.shot('downloader_notice');
    await tester.tap(find.text('I understand'));
    await settle(tester, rounds: 8);
    await shot.shot('downloader_fetched');

    await tester.tap(find.text('720p'));
    await settle(tester);
    final panel = find
        .descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable))
        .first;
    final download = find.widgetWithText(FilledButton, 'Download');
    await tester.scrollUntilVisible(download, 100, scrollable: panel);
    await tester.tap(download);
    await settle(tester);
    if (!shot.tablet) {
      await tester.tap(find.text('Downloads (1)'));
      await settle(tester);
    }
    await shot.shot('downloader_queue');

    await shot.open(VideoDownloaderSettingsScreen(
      controller: VideoDownloaderController.instance,
    ));
    await settle(tester);
    await shot.shot('downloader_settings');
  });

  viewerShots('video downloader engine', (tester, shot) async {
    final backend = FakeBackend()
      ..engine = const EngineInfo(installed: false, downloadBytes: 49930835, diskBytes: 119773698)
      ..holdDownload = Completer<void>();
    VideoDownloaderController.instance = VideoDownloaderController(backend);
    await shot.open(const VideoDownloaderScreen());
    await settle(tester);
    await tester.tap(find.text('I understand'));
    await settle(tester);
    await shot.shot('downloader_engine_ask');
    await tester.tap(find.text('Not now'));
    await settle(tester);
    await shot.shot('downloader_engine_needed');
    await tester.tap(find.text('Download (50 MB)'));
    await settle(tester);
    await shot.shot('downloader_engine_progress');
  });
}
