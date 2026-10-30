// FILE PATH: lib/main.dart

import 'dart:io';

import 'package:explorer/core/app/app_bloc_observer.dart';
import 'package:explorer/core/app_licenses.dart';
import 'package:explorer/core/platform/background_mode.dart';
import 'package:explorer/core/platform/window_effects.dart';
import 'package:explorer/core/theme/theme_preferences.dart';
import 'package:explorer/core/platform/desktop.dart';
import 'package:explorer/core/platform/explorer_paths.dart';
import 'package:explorer/core/platform/macos_open_files.dart';
import 'package:explorer/shared/widgets/tasks_view.dart';
import 'package:explorer/core/router/file_opener.dart';
import 'package:explorer/core/build_features.dart';
import 'package:explorer/core/services/incoming_files.dart';
import 'package:explorer/core/services/video_downloader/video_downloader_licenses.dart';
import 'package:explorer/core/services/webview_warmup.dart';
import 'package:explorer/core/theme/app_theme.dart';
import 'package:explorer/core/theme/app_theme_settings.dart';
import 'package:explorer/core/theme/theme_cubit.dart';
import 'package:explorer/features/explorer_tabs/explorer_tabs.dart';
import 'package:explorer/features/explorer_tabs/tabbed_explorer.dart';
import 'package:explorer/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:explorer/features/incoming/incoming_file_screen.dart';
import 'package:explorer/features/video_downloader/screens/video_downloader_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  Bloc.observer = const AppBlocObserver();
  registerAppLicenses();
  if (kVideoDownloaderEnabled) registerVideoDownloaderLicenses();
  Desktop.initMedia();
  // Closing the window while work goes on leaves a Tasks view (desktop).
  await BackgroundMode.instance.init();
  // The translucent window (Acrylic, vibrancy), as last chosen.
  await WindowEffects.init(enabled: (await ThemePreferences.load()).windowEffect);
  // Windows: the tabs take the title bar's place.
  await TabbedExplorer.prepareWindow();

  // Desktop: a new window (or the system) can pass a folder to show or a
  // file to open. On macOS, Finder sends them as events instead (Open With,
  // drops on the Dock icon).
  var launch = Desktop.isDesktop
      ? Desktop.parseArgs(args)
      : (folder: null, file: null);
  if (MacosOpenFiles.supported) {
    launch = await MacosOpenFiles.launchTarget(launch);
  }
  ExplorerPaths.startFolder = launch.folder;
  final launchFile = launch.file;
  if (launchFile != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // In the first tab, so closing the file shows its folder.
      final context = ExplorerTabs.instance.active?.navigatorKey.currentContext ??
          _navigatorKey.currentContext;
      if (context != null) FileOpener.open(context, File(launchFile));
    });
  }

  // Launched from another app ("Open with" a file, or "Share" a link): go
  // straight to the viewer or the video downloader.
  final launchItem = await IncomingFiles.takeInitial();
  IncomingFiles.onIncoming.listen((incoming) {
    _navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => _screenFor(incoming, launchedForIt: false),
      ),
    );
  });

  // A notification tap opens its screen on top of the explorer, so Back
  // behaves as usual.
  final startItem = launchItem is IncomingRoute ? null : launchItem;
  runApp(App(launchItem: startItem));
  // macOS: a window opened for a folder or a file (from Finder or another
  // Explorer window) comes to the front once it's up, rather than staying
  // behind the app that asked for it.
  if (Platform.isMacOS &&
      !Platform.environment.containsKey('FLUTTER_TEST') &&
      (launch.folder != null || launch.file != null)) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  if (launchItem is IncomingRoute) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => _screenFor(launchItem, launchedForIt: false),
        ),
      );
    });
  }

  // Load the system WebView engine while idle so the first e-book, web
  // page, Markdown preview or 3D model opens without that cost. A file
  // opened from another app starts its own WebView right away instead.
  if (launchItem == null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 3), WebViewWarmup.warmUp);
    });
  }
}

class App extends StatelessWidget {
  const App({super.key, this.launchItem});

  final IncomingItem? launchItem;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => ThemeCubit(),
      child: BlocBuilder<ThemeCubit, AppThemeSettings>(
        builder: (context, settings) {
          // The window effect follows the setting and light/dark.
          final dark = settings.themeMode == ThemeMode.dark ||
              (settings.themeMode == ThemeMode.system &&
                  MediaQuery.platformBrightnessOf(context) == Brightness.dark);
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => WindowEffects.apply(enabled: settings.windowEffect, dark: dark),
          );
          // shadcn/ui theme; ShadApp derives the Material theme from it,
          // which AppTheme.material completes.
          return ShadApp.custom(
            themeMode: settings.themeMode,
            theme: AppTheme.shad(settings, Brightness.light),
            darkTheme: AppTheme.shad(settings, Brightness.dark),
            appBuilder: (context) => MaterialApp(
              navigatorKey: _navigatorKey,
              title: 'Explorer',
              theme: AppTheme.material(
                Theme.of(context),
                ShadTheme.of(context),
              ),
              debugShowCheckedModeBanner: false,
              supportedLocales: const [Locale('en')],
              localizationsDelegates: const [
                GlobalShadLocalizations.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
              ],
              builder: (context, child) => ShadAppBuilder(
                child: ListenableBuilder(
                  listenable: BackgroundMode.instance,
                  // The app stays as it was behind the Tasks view.
                  builder: (context, _) {
                    final tasksOnly = BackgroundMode.instance.tasksOnly;
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Offstage(
                          offstage: tasksOnly,
                          child: TickerMode(
                            enabled: !tasksOnly,
                            child: child ?? const SizedBox.shrink(),
                          ),
                        ),
                        if (tasksOnly)
                          const Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [WindowTitleBar(), Expanded(child: TasksView())],
                          ),
                      ],
                    );
                  },
                ),
              ),
              home: launchItem != null
                  ? _screenFor(launchItem!, launchedForIt: true)
                  : Desktop.isDesktop
                      ? TabbedExplorer(startFolder: ExplorerPaths.initialPath)
                      : const FileExplorerScreen(),
            ),
          );
        },
      ),
    );
  }
}

/// Where to go for something another app sent. [launchedForIt]: the app was
/// started just for this, so leaving it returns to the sending app.
Widget _screenFor(IncomingItem item, {required bool launchedForIt}) =>
    switch (item) {
      IncomingFile() => IncomingFileScreen(
        incoming: item,
        closeAppWhenDone: launchedForIt,
      ),
      // Builds without the downloader don't register for shared links or
      // post download notifications, so these only arrive with it.
      IncomingLink(:final text, :final url) =>
        kVideoDownloaderEnabled
            ? VideoDownloaderScreen(initialUrl: url ?? text.trim())
            : const FileExplorerScreen(),
      // Only one route so far: download notifications.
      IncomingRoute() =>
        kVideoDownloaderEnabled
            ? const VideoDownloaderScreen()
            : const FileExplorerScreen(),
    };
