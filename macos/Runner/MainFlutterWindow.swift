import Cocoa
import FlutterMacOS
import ImageIO
import Vision
import macos_window_utils

class MainFlutterWindow: NSWindow {
  private var imageText: ImageTextChannel?
  private var fileClipboard: FileClipboardChannel?
  private var systemIcons: SystemIconsChannel?

  override func awakeFromNib() {
    // macos_window_utils (used by flutter_acrylic for the translucent
    // window) hosts the Flutter view and needs the window to work on.
    let windowFrame = self.frame
    let macOSWindowUtilsViewController = MacOSWindowUtilsViewController()
    self.contentViewController = macOSWindowUtilsViewController
    self.setFrame(windowFrame, display: true)

    MainFlutterWindowManipulator.start(mainFlutterWindow: self)

    let flutterViewController = macOSWindowUtilsViewController.flutterViewController
    RegisterGeneratedPlugins(registry: flutterViewController)

    let messenger = flutterViewController.engine.binaryMessenger
    imageText = ImageTextChannel(messenger: messenger)
    fileClipboard = FileClipboardChannel(messenger: messenger)
    systemIcons = SystemIconsChannel(messenger: messenger)

    super.awakeFromNib()
  }
}

/// The icons Finder shows for folders, for the macOS style.
///
/// `icon` {path, size} gives the icon of the file or folder at path, as a
/// PNG size pixels wide.
class SystemIconsChannel {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "explorer/system_icons", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "icon" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String,
        let size = args["size"] as? Int
      else {
        result(nil)
        return
      }
      result(SystemIconsChannel.png(path: path, size: size))
    }
  }

  private static func png(path: String, size: Int) -> FlutterStandardTypedData? {
    let icon = NSWorkspace.shared.icon(forFile: path)
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    icon.draw(
      in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
    return FlutterStandardTypedData(bytes: data)
  }
}

/// Text in images, for selecting it in the image viewer: Apple's Vision
/// text recognition, as Live Text uses.
///
/// `read` {path} gives the size the image was read at and each line with
/// its words' boxes in that image (pixels from the top left), or null.
class ImageTextChannel {
  private let channel: FlutterMethodChannel
  private static let queue = DispatchQueue(label: "explorer.image_text", qos: .userInitiated)

  /// Larger pictures are read scaled down to this many pixels on a side.
  private static let maxSide = 8192

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "explorer/image_text", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "read" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
        result(nil)
        return
      }
      ImageTextChannel.queue.async {
        let text = autoreleasepool { ImageTextChannel.read(path: path) }
        DispatchQueue.main.async { result(text) }
      }
    }
  }

  private static func read(path: String) -> [String: Any]? {
    guard let image = upright(path: path) else { return nil }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if #available(macOS 13.0, *) {
      request.automaticallyDetectsLanguage = true
    }
    do {
      try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
      return nil
    }
    let width = image.width, height = image.height
    var lines: [[String: Any]] = []
    for observation in request.results ?? [] {
      guard let candidate = observation.topCandidates(1).first else { continue }
      let text = candidate.string
      var words: [[String: Any]] = []
      for range in wordRanges(text) {
        // Vision can't always place part of a line; skip that word.
        guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
        words.append(word(String(text[range]), box, width, height))
      }
      if words.isEmpty {
        words.append(word(text, observation.boundingBox, width, height))
      }
      lines.append(["t": text, "words": words])
    }
    return ["w": width, "h": height, "lines": lines]
  }

  /// The image turned the way it's shown (its EXIF orientation), at full
  /// size up to [maxSide].
  private static func upright(path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxSide),
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// Runs of anything but spaces, so punctuation stays with its word as in
  /// the other platforms' results.
  private static func wordRanges(_ text: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var start: String.Index?
    var i = text.startIndex
    while i < text.endIndex {
      if text[i].isWhitespace {
        if let s = start { ranges.append(s..<i) }
        start = nil
      } else if start == nil {
        start = i
      }
      i = text.index(after: i)
    }
    if let s = start { ranges.append(s..<text.endIndex) }
    return ranges
  }

  /// A word and its box: Vision's are 0-1 from the bottom left, the app's
  /// are pixels from the top left.
  private static func word(_ text: String, _ box: CGRect, _ width: Int, _ height: Int) -> [String: Any] {
    let rect = VNImageRectForNormalizedRect(box, width, height)
    return [
      "t": text,
      "x": Double(rect.minX),
      "y": Double(height) - Double(rect.maxY),
      "w": Double(rect.width),
      "h": Double(rect.height),
    ]
  }
}

/// Files on the macOS pasteboard, so they copy and paste to and from Finder
/// and other apps.
///
/// macOS 26 asks the user when an app reads what another app copied, so
/// `peek` tells what's on it from the kinds of data alone: whether it holds
/// files, whether Folder put them there, and whether `read` (the paths)
/// would go ahead without asking. `write` {paths} puts the files on it and
/// gives its change count, `changeCount` tells when it changed, and `clear`
/// empties it if it holds files.
class FileClipboardChannel {
  private let channel: FlutterMethodChannel

  /// Marks files an Folder window put on the pasteboard; the shared file
  /// says which, and whether they were cut.
  private static let explorerFiles = NSPasteboard.PasteboardType("com.synqixlabs.folder.files")

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "explorer/mac_clipboard", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let pasteboard = NSPasteboard.general
      switch call.method {
      case "write":
        let paths = (call.arguments as? [String: Any])?["paths"] as? [String] ?? []
        guard FileClipboardChannel.write(paths, to: pasteboard) else {
          result(FlutterError(code: "write", message: "Couldn't put the files on the pasteboard", details: nil))
          return
        }
        result(pasteboard.changeCount)
      case "peek":
        result(FileClipboardChannel.peek(pasteboard))
      case "read":
        result(FileClipboardChannel.paths(pasteboard))
      case "changeCount":
        result(pasteboard.changeCount)
      case "clear":
        if pasteboard.types?.contains(.fileURL) == true { pasteboard.clearContents() }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Puts the files on the pasteboard, marked as Folder's.
  private static func write(_ paths: [String], to pasteboard: NSPasteboard) -> Bool {
    pasteboard.clearContents()
    let urls = paths.map { NSURL(fileURLWithPath: $0) }
    if urls.isEmpty { return true }
    guard pasteboard.writeObjects(urls) else { return false }
    // On the first file; Finder and other apps ignore it.
    pasteboard.setData(Data(), forType: explorerFiles)
    return true
  }

  /// What's on the pasteboard, from its change count and the kinds of data
  /// on it, which macOS doesn't ask about.
  private static func peek(_ pasteboard: NSPasteboard) -> [String: Any] {
    let types = pasteboard.types ?? []
    return [
      "change": pasteboard.changeCount,
      "files": types.contains(.fileURL),
      "explorer": types.contains(explorerFiles),
      "quiet": readsQuietly(pasteboard),
    ]
  }

  /// Whether reading what another app copied goes ahead without the system
  /// asking the user: from macOS 26 it asks, unless they chose to always
  /// allow Folder in Privacy & Security settings.
  private static func readsQuietly(_ pasteboard: NSPasteboard) -> Bool {
    guard #available(macOS 15.4, *) else { return true }
    switch pasteboard.accessBehavior {
    case .alwaysAllow:
      return true
    case .default:
      if #available(macOS 26.0, *) { return false }
      return true
    default:
      return false
    }
  }

  /// The paths of the files on the pasteboard (Finder may put file
  /// reference URLs there, which filePathURL turns into paths).
  private static func paths(_ pasteboard: NSPasteboard) -> [String] {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] ?? []
    return urls.compactMap { $0.filePathURL?.path }
  }
}
