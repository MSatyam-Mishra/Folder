import 'dart:async';

import 'package:flutter/widgets.dart';

/// Files on other machines and in the cloud (Windows shares, SFTP, FTP,
/// WebDAV, Google Drive, OneDrive, Dropbox) and Android's app folders through
/// Shizuku, opened in the browser like folders on disk.
///
/// Each protocol implements [RemoteFileSystem] and registers itself with
/// [RemoteProtocols.register] (see `remote_registry.dart`); the browser, the
/// copy engine and the viewers only ever talk to this interface.
enum RemoteProtocol {
  smb,
  sftp,
  ftp,
  ftps,
  webdav,
  googleDrive,
  oneDrive,
  dropbox,

  /// Android/data and Android/obb on this phone, through Shizuku.
  shizuku;

  static RemoteProtocol? byName(String name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// A saved place on another machine or in the cloud. Secrets (passwords,
/// private keys, OAuth tokens) are never in here: [RemoteSecrets] keeps them.
@immutable
class RemoteConnection {
  const RemoteConnection({
    required this.id,
    required this.protocol,
    required this.name,
    this.host = '',
    this.port,
    this.rootPath = '/',
    this.username = '',
    this.options = const {},
  });

  /// Stable and unique, used in paths: `explorer://remote/<id>/<path>`.
  /// Letters, digits, `-` and `_` only.
  final String id;
  final RemoteProtocol protocol;

  /// What the sidebar shows ("NAS", "Work laptop", "Google Drive (me@...)").
  final String name;

  /// Host name or IP address; empty for cloud services and Shizuku.
  final String host;

  /// Null for the protocol's default.
  final int? port;

  /// The folder the connection opens at, `/`-separated. For SMB the first
  /// part is the share (`/Public/Photos`); `/` lists the shares.
  final String rootPath;
  final String username;

  /// Protocol-specific settings, as text: `domain` (SMB), `passive` (FTP),
  /// `implicitTls` (FTPS), `path` prefix (WebDAV), `accountEmail` (cloud)...
  final Map<String, String> options;

  RemoteConnection copyWith({
    String? name,
    String? host,
    int? port,
    bool clearPort = false,
    String? rootPath,
    String? username,
    Map<String, String>? options,
  }) =>
      RemoteConnection(
        id: id,
        protocol: protocol,
        name: name ?? this.name,
        host: host ?? this.host,
        port: clearPort ? null : (port ?? this.port),
        rootPath: rootPath ?? this.rootPath,
        username: username ?? this.username,
        options: options ?? this.options,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'protocol': protocol.name,
        'name': name,
        'host': host,
        'port': port,
        'rootPath': rootPath,
        'username': username,
        'options': options,
      };

  /// Null if [json] isn't a connection this version knows.
  static RemoteConnection? fromJson(Map<String, Object?> json) {
    final protocol = RemoteProtocol.byName(json['protocol'] as String? ?? '');
    final id = json['id'] as String?;
    if (protocol == null || id == null || id.isEmpty) return null;
    return RemoteConnection(
      id: id,
      protocol: protocol,
      name: json['name'] as String? ?? id,
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt(),
      rootPath: json['rootPath'] as String? ?? '/',
      username: json['username'] as String? ?? '',
      options: {
        for (final e in ((json['options'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}',
      },
    );
  }
}

/// A file or folder on a remote place.
@immutable
class RemoteEntry {
  const RemoteEntry({
    required this.path,
    required this.isDirectory,
    this.size = 0,
    this.modified,
    this.mimeType,
    this.remoteId,
  });

  /// Absolute within the connection, `/`-separated, starting with `/`
  /// (`/Photos/2026/a.jpg`). Never ends with `/`, except the root itself.
  final String path;
  final bool isDirectory;

  /// In bytes; 0 for folders.
  final int size;
  final DateTime? modified;
  final String? mimeType;

  /// The service's own id (Google Drive's file id...), when paths alone
  /// can't find it again quickly. Opaque to everyone else.
  final String? remoteId;

  String get name => RemotePaths.nameOf(path);
}

enum RemoteErrorKind {
  /// Wrong user name, password, key or expired sign-in.
  auth,
  notFound,
  alreadyExists,
  permission,

  /// The host can't be reached, timed out, or the connection dropped.
  network,

  /// The protocol or server can't do this (renaming on some FTP servers...).
  unsupported,
  cancelled,
  other,
}

class RemoteException implements Exception {
  const RemoteException(this.kind, this.message);

  final RemoteErrorKind kind;

  /// Plain words for the user ("The password was refused").
  final String message;

  @override
  String toString() => 'RemoteException(${kind.name}): $message';
}

/// The server isn't the one seen before: an SFTP host key or a certificate
/// changed, so someone may be listening in between. Nothing was sent. The
/// browser shows [message] with a button that calls [trust], which accepts
/// the new identity ([fingerprint]) for the next try.
class RemoteTrustException extends RemoteException {
  const RemoteTrustException(String message, {required this.fingerprint, required this.trust})
      : super(RemoteErrorKind.permission, message);

  final String fingerprint;
  final Future<void> Function() trust;
}

/// How a [RemoteOptionField] is edited.
enum RemoteOptionKind {
  /// A switch; its value is `true` or `false`.
  toggle,
  text,

  /// One of [RemoteOptionField.choices].
  choice,
}

/// A protocol setting that "Add a place" offers beside the usual fields
/// (FTP's passive mode, FTPS's implicit TLS, WebDAV's HTTPS...), kept in
/// [RemoteConnection.options] under [key].
@immutable
class RemoteOptionField {
  const RemoteOptionField({
    required this.key,
    required this.label,
    this.kind = RemoteOptionKind.toggle,
    this.defaultValue = '',
    this.description,
    this.hint,
    this.choices = const {},
  });

  final String key;
  final String label;
  final RemoteOptionKind kind;

  /// `true`/`false` for a toggle.
  final String defaultValue;

  /// A line under the label.
  final String? description;

  /// Greyed text in an empty text field.
  final String? hint;

  /// For [RemoteOptionKind.choice]: value to label, in order.
  final Map<String, String> choices;

  /// [connection]'s value, or [defaultValue].
  String valueIn(RemoteConnection connection) => connection.options[key] ?? defaultValue;

  /// [connection]'s value of a toggle.
  bool isOnIn(RemoteConnection connection) => valueIn(connection) == 'true';
}

/// One open connection to a remote place. Not safe to share between
/// isolates; one instance may serve several calls at once.
abstract class RemoteFileSystem {
  RemoteConnection get connection;

  /// Connects and signs in. Called once before anything else; calling it
  /// again after [close] reconnects. Throws [RemoteException].
  Future<void> connect();

  /// The folder's contents, without `.` and `..`. Throws [RemoteException]
  /// (notFound if [path] doesn't exist or isn't a folder).
  Future<List<RemoteEntry>> list(String path);

  /// Throws [RemoteException] with [RemoteErrorKind.notFound] if missing.
  Future<RemoteEntry> stat(String path);

  /// The file's bytes from [start] up to, not including, [end] (to the end
  /// when null).
  Stream<List<int>> openRead(String path, {int start = 0, int? end});

  /// Writes [data] to [path], creating the file. Fails with
  /// [RemoteErrorKind.alreadyExists] if it exists, unless [overwrite]. Reports
  /// bytes sent so far through [onProgress]. [length], when known, lets
  /// services that need the size up front (Dropbox, Drive) use it.
  Future<void> write(
    String path,
    Stream<List<int>> data, {
    int? length,
    bool overwrite = false,
    void Function(int sent)? onProgress,
  });

  Future<void> createDirectory(String path);

  /// Deletes a file, or a folder with everything in it.
  Future<void> delete(String path);

  /// Renames or moves within this connection. Fails with alreadyExists if
  /// [to] exists.
  Future<void> rename(String from, String to);

  Future<void> close();
}

/// The secrets of one connection: `password`, `privateKey`, `passphrase`,
/// `accessToken`, `refreshToken`, `tokenExpiry` (ISO 8601)... A protocol may
/// write new ones (a refreshed token) while connected.
abstract class RemoteSecrets {
  Future<String?> read(String key);

  /// Removes the key when [value] is null.
  Future<void> write(String key, String? value);
}

/// Simple [RemoteSecrets] in memory, for tests.
class MemoryRemoteSecrets implements RemoteSecrets {
  MemoryRemoteSecrets([Map<String, String>? values]) : values = {...?values};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

/// What a cloud service's sign-in found out, to make a connection of.
@immutable
class RemoteSignIn {
  const RemoteSignIn({required this.name, required this.secrets, this.username = '', this.options = const {}});

  /// Suggested name for the sidebar ("Google Drive (me@example.com)").
  final String name;
  final String username;
  final Map<String, String> options;

  /// Kept in [RemoteSecrets] (tokens).
  final Map<String, String> secrets;
}

typedef RemoteFileSystemFactory = RemoteFileSystem Function(RemoteConnection connection, RemoteSecrets secrets);

/// What the browser needs to know to offer a protocol in "Add a place".
@immutable
class RemoteProtocolInfo {
  const RemoteProtocolInfo({
    required this.protocol,
    required this.label,
    required this.icon,
    required this.create,
    this.defaultPort,
    this.needsHost = true,
    this.usesPassword = true,
    this.usesPrivateKey = false,
    this.signIn,
    this.isAvailable,
    this.deleteNote,
    this.options = const [],
    this.description,
    this.hostHint,
    this.discover,
    this.builtInPlace,
    this.fixAccess,
  });

  final RemoteProtocol protocol;

  /// "Windows share (SMB)", "SFTP", "Google Drive"...
  final String label;
  final IconData icon;
  final RemoteFileSystemFactory create;
  final int? defaultPort;

  /// False for cloud services and Shizuku, which have no host to type.
  final bool needsHost;
  final bool usesPassword;

  /// SFTP: a private key instead of, or as well as, a password.
  final bool usesPrivateKey;

  /// For services signed in through the browser (OAuth): signs in and
  /// returns what to save, or null when the user gave up. Throws
  /// [RemoteException] on failure.
  final Future<RemoteSignIn?> Function(BuildContext context)? signIn;

  /// Whether it can be used on this system and build (a cloud service
  /// without its client id, Shizuku off Android...). Always when null.
  final bool Function()? isAvailable;

  /// What happens to deleted items, for the delete confirmation, when they
  /// can be brought back ("Deleted items go to Google Drive's trash..."). Null
  /// when they're gone for good.
  final String? deleteNote;

  bool get available => isAvailable?.call() ?? true;

  /// Settings shown after the usual fields, in order.
  final List<RemoteOptionField> options;

  /// One line under the label in the protocol list ("Linux and Mac
  /// computers, NAS").
  final String? description;

  /// Greyed text in the empty host field ("nas.local or 192.168.1.5").
  final String? hostHint;

  /// Servers of this kind found on the network (SMB's), for "Find on
  /// network" in the form; the stream ends when the search does.
  final Stream<RemoteFoundHost> Function()? discover;

  /// A place that's always there, with nothing to fill in (Shizuku's app
  /// folders): shown in the sidebar while [available], never in "Add a
  /// place". Its id must stay the same.
  final RemoteConnection Function()? builtInPlace;

  /// What the error page's "Set up access" does when such a place refuses
  /// (Shizuku's set-up); true to try again.
  final Future<bool> Function(BuildContext context)? fixAccess;
}

/// A server [RemoteProtocolInfo.discover] found.
@immutable
class RemoteFoundHost {
  const RemoteFoundHost({required this.name, required this.host, this.port});

  /// What it calls itself ("NAS").
  final String name;

  /// Its address or host name, for [RemoteConnection.host].
  final String host;
  final int? port;
}

/// The protocols this build knows, filled by `registerRemoteProtocols()`.
abstract final class RemoteProtocols {
  static final Map<RemoteProtocol, RemoteProtocolInfo> _all = {};

  static void register(RemoteProtocolInfo info) => _all[info.protocol] = info;

  static RemoteProtocolInfo? of(RemoteProtocol protocol) => _all[protocol];

  /// In [RemoteProtocol] order.
  static List<RemoteProtocolInfo> get all =>
      [for (final p in RemoteProtocol.values) if (_all[p] case final info?) info];

  @visibleForTesting
  static void clear() => _all.clear();
}

/// Browser paths of remote places: `explorer://remote/<id>/<path>`, the path
/// percent-encoded part by part.
abstract final class RemotePaths {
  static const String prefix = 'explorer://remote/';

  static bool isRemote(String browserPath) => browserPath.startsWith(prefix);

  static String build(String connectionId, String path) {
    final parts = normalize(path).split('/').where((s) => s.isNotEmpty).map(Uri.encodeComponent);
    return '$prefix$connectionId/${parts.join('/')}';
  }

  /// (connection id, remote path), or null if [browserPath] isn't remote.
  static (String, String)? parse(String browserPath) {
    if (!isRemote(browserPath)) return null;
    final rest = browserPath.substring(prefix.length);
    final slash = rest.indexOf('/');
    final id = slash < 0 ? rest : rest.substring(0, slash);
    if (id.isEmpty) return null;
    final tail = slash < 0 ? '' : rest.substring(slash + 1);
    final parts = tail.split('/').where((s) => s.isNotEmpty).map(Uri.decodeComponent);
    return (id, '/${parts.join('/')}');
  }

  /// `/`-separated, starting with `/`, no `.`/`..`/empty parts, no trailing `/`.
  static String normalize(String path) {
    final out = <String>[];
    for (final part in path.replaceAll('\\', '/').split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(part);
    }
    return '/${out.join('/')}';
  }

  static String join(String folder, String name) => normalize('$folder/$name');

  static String parentOf(String path) {
    final n = normalize(path);
    final i = n.lastIndexOf('/');
    return i <= 0 ? '/' : n.substring(0, i);
  }

  static String nameOf(String path) {
    final n = normalize(path);
    return n == '/' ? '' : n.substring(n.lastIndexOf('/') + 1);
  }
}
