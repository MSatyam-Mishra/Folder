import Cocoa
import FlutterMacOS
import macos_window_utils

@main
class AppDelegate: FlutterAppDelegate {
  /// Files and folders Finder asked Folders to open ("Open With", or
  /// dropped on the Dock icon) before Dart took them with `takeInitial`.
  private var pendingPaths: [String] = []
  /// Set once Dart has taken the launch items; later ones go straight to it.
  private var dartTookInitial = false
  /// Set once launching has finished. AppKit hands over Finder's launch
  /// items just before that, while Dart may already be running.
  private var launched = false
  /// Dart's `takeInitial` call, held until launching has finished.
  private var pendingTake: FlutterResult?
  private var openFilesChannel: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)
    // The main nib (with the window and its Flutter view) is loaded by now,
    // and Finder's launch items only arrive after this.
    setUpOpenFilesChannel()
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // FlutterAppDelegate doesn't implement this one (Flutter 3.44); pass it
    // on only if a later version does.
    if FlutterAppDelegate.instancesRespond(to: #selector(applicationDidFinishLaunching(_:))) {
      super.applicationDidFinishLaunching(notification)
    }
    launched = true
    if let take = pendingTake {
      pendingTake = nil
      giveInitial(take)
    }
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    super.application(application, open: urls)
    let paths = urls.filter { $0.isFileURL }.map { $0.path }
    if paths.isEmpty { return }
    setUpOpenFilesChannel()
    if dartTookInitial, let channel = openFilesChannel {
      channel.invokeMethod("open", arguments: ["paths": paths])
    } else {
      pendingPaths.append(contentsOf: paths)
    }
  }

  /// `explorer/open_files`: Dart calls `takeInitial` once at start-up for
  /// the launch items (see lib/core/platform/macos_open_files.dart), and is
  /// answered once launching has finished; later items are sent to it as
  /// `open` {paths}.
  private func setUpOpenFilesChannel() {
    if openFilesChannel != nil { return }
    guard let messenger = flutterViewController()?.engine.binaryMessenger else { return }
    let channel = FlutterMethodChannel(name: "explorer/open_files", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, call.method == "takeInitial" else {
        result(FlutterMethodNotImplemented)
        return
      }
      if self.launched {
        self.giveInitial(result)
      } else {
        self.pendingTake = result
      }
    }
    openFilesChannel = channel
  }

  /// Answers `takeInitial` with the items kept so far.
  private func giveInitial(_ result: FlutterResult) {
    dartTookInitial = true
    result(pendingPaths)
    pendingPaths.removeAll()
  }

  /// The Flutter view, hosted by macos_window_utils (see MainFlutterWindow).
  private func flutterViewController() -> FlutterViewController? {
    let content = mainFlutterWindow?.contentViewController
    if let utils = content as? MacOSWindowUtilsViewController {
      return utils.flutterViewController
    }
    return content as? FlutterViewController
  }
}

import flutter_inappwebview_macos

extension InAppWebView {
    @objc public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        if window != nil {
            print("InAppWebView moved to window, enforcing transparency")
            self.setValue(false, forKey: "opaque")
            self.setValue(false, forKey: "drawsBackground")
            self.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
