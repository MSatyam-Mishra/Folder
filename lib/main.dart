// FILE PATH: lib/main.dart

import 'dart:async';
import 'dart:io';

import 'package:folders/shared/layout/sidebar_width.dart';
import 'package:folders/features/file_explorere/explorer_zoom.dart';
import 'package:folders/core/app/app_bloc_observer.dart';
import 'package:folders/core/app_licenses.dart';
import 'package:folders/core/platform/background_mode.dart';
import 'package:folders/core/platform/window_effects.dart';
import 'package:folders/core/platform/windows_drop_files.dart';
import 'package:folders/core/theme/icon_strokes.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/platform/old_app_data.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/platform/macos_open_files.dart';
import 'package:folders/shared/widgets/tasks_view.dart';
import 'package:folders/core/router/file_opener.dart';
import 'package:folders/core/build_features.dart';
import 'package:folders/core/services/app_shortcuts.dart';
import 'package:folders/core/services/incoming_files.dart';
import 'package:folders/core/services/task_notifications.dart';
import 'package:folders/core/services/video_downloader/video_downloader_licenses.dart';
import 'package:folders/core/services/webview_warmup.dart';
import 'package:folders/core/theme/app_theme.dart';
import 'package:folders/core/theme/app_theme_settings.dart';
import 'package:folders/core/theme/theme_cubit.dart';
import 'package:folders/features/explorer_tabs/explorer_tabs.dart';
import 'package:folders/features/explorer_tabs/tabbed_explorer.dart';
import 'package:folders/features/file_explorere/screens/file_explorer_screen.dart';
import 'package:folders/features/incoming/incoming_file_screen.dart';
import 'package:folders/features/network/screens/file_server_screen.dart';
import 'package:folders/features/toolbox/toolbox_menu.dart';
import 'package:folders/features/video_downloader/screens/video_downloader_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:window_manager/window_manager.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything reads its settings.
  await OldAppData.moveAcross();
  Bloc.observer = const AppBlocObserver();
  registerAppLicenses();
  if (kVideoDownloaderEnabled) registerVideoDownloaderLicenses();
  Desktop.initMedia();
  // Closing the window while work goes on leaves a Tasks view (desktop).
  await BackgroundMode.instance.init();
  // On phones work going on shows in the notification shade.
  TaskNotifications.instance.init();
  // The translucent window (Acrylic, vibrancy), as last chosen.
  await WindowEffects.init();
  await IconStrokes.useLight();
  await ExplorerZoom.instance.load();
  await SidebarWidth.instance.load();
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
      // Never back to the system: if Folders is the file's default app,
      // that would start another Folders for it, and so on.
      if (context != null) FileOpener.open(context, File(launchFile), allowExternal: false);
    });
  }

  // A shortcut on a computer: the tool it's for, in the first tab.
  final shortcutRoute = Desktop.isDesktop ? AppShortcuts.routeIn(args) : null;
  if (shortcutRoute != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = ExplorerTabs.instance.active?.navigatorKey.currentState ?? _navigatorKey.currentState;
      navigator?.push(
        MaterialPageRoute(builder: (_) => _screenFor(IncomingRoute(shortcutRoute), launchedForIt: false)),
      );
    });
  }

  // Launched from another app ("Open with" a file, or "Share" a link): go
  // straight to the viewer or the video downloader.
  final launchItem = await IncomingFiles.takeInitial();
  IncomingFiles.onIncoming.listen((incoming) {
    // Its notification: back to the screen that's sharing, not a second one.
    if (incoming is IncomingRoute &&
        incoming.route == IncomingRoute.fileServer &&
        FileServerScreen.showRunning()) {
      return;
    }
    _openIncoming(incoming);
  });

  // A file opens by itself, and closing it returns to the app that sent it. A
  // shared link or a notification opens on top of the explorer: Back leads to
  // it and its menu, and alone the screen would have neither.
  final startItem = launchItem is IncomingFile ? launchItem : null;
  runApp(App(launchItem: startItem));
  unawaited(WindowsDropFiles.init());
  // macOS: a window opened for a folder or a file (from Finder or another
  // Folders window) comes to the front once it's up, rather than staying
  // behind the app that asked for it.
  if (Platform.isMacOS &&
      !Platform.environment.containsKey('FLUTTER_TEST') &&
      (launch.folder != null || launch.file != null)) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  if (launchItem != null && startItem == null) {
    // In the second frame. The first one's callbacks end with the Navigator
    // saying it has nothing to pop, which would come after a push made there.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openIncoming(launchItem);
      });
      WidgetsBinding.instance.scheduleFrame();
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
          final dark = settings.effectiveThemeMode == ThemeMode.dark ||
              (settings.effectiveThemeMode == ThemeMode.system &&
                  MediaQuery.platformBrightnessOf(context) == Brightness.dark);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            WindowEffects.apply(backdrop: settings.backdrop, dark: dark);
            TaskNotifications.instance.setTheme(
              AppTheme.shad(settings, dark ? Brightness.dark : Brightness.light).colorScheme.primary,
            );
          });
          // shadcn/ui theme; ShadApp derives the Material theme from it,
          // which AppTheme.material completes.
          return ShadApp.custom(
            themeMode: settings.effectiveThemeMode,
            theme: AppTheme.shad(settings, Brightness.light),
            darkTheme: AppTheme.shad(settings, Brightness.dark),
            appBuilder: (context) => MaterialApp(
              navigatorKey: _navigatorKey,
              title: 'Folders',
              // Who handles Back. WidgetsApp's own handler ignores this until
              // it hears of a lifecycle change, which never comes if the app
              // was already resumed when it started: opened by a shortcut, Back
              // would leave the app rather than close the tool.
              onNavigationNotification: (notification) {
                SystemNavigator.setFrameworkHandlesBack(notification.canHandlePop);
                return true;
              },
              theme: AppTheme.material(
                Theme.of(context),
                ShadTheme.of(context),
                style: settings.style,
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
                // With a window effect each page paints the one see-through
                // background; a second one under it would hide the effect.
                backgroundColor: settings.windowEffect && WindowEffects.supported ? Colors.transparent : null,
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
/// Opens [item] over what's showing, unless that's the screen it asks for: a
/// tool's icon pressed again goes back to it, without stacking another.
void _openIncoming(IncomingItem item) {
  final navigator = _navigatorKey.currentState;
  if (navigator == null) return;
  final name = item is IncomingRoute ? item.route : null;
  var showing = false;
  if (name != null) {
    // Only looks: the first route it's given is the top one.
    navigator.popUntil((top) {
      showing = top.settings.name == name;
      return true;
    });
  }
  if (showing) return;
  navigator.push(
    MaterialPageRoute(
      settings: RouteSettings(name: name),
      builder: (_) => _screenFor(item, launchedForIt: false),
    ),
  );
}

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
      // A notification, or a tool's shortcut.
      IncomingRoute(:final route) =>
        route == IncomingRoute.fileServer
            ? FileServerScreen(initialFolder: ExplorerPaths.initialPath)
            : Tool.fromRoute(route)?.screen ??
                (kVideoDownloaderEnabled
                    ? const VideoDownloaderScreen()
                    : const FileExplorerScreen()),
    };
