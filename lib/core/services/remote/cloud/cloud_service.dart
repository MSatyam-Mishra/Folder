import 'dart:async';

import 'package:folders/core/services/remote/cloud/cloud_http.dart';
import 'package:folders/core/services/remote/cloud/cloud_oauth.dart';
import 'package:folders/core/services/remote/remote_fs.dart';

/// One cloud service (Google Drive, OneDrive, Dropbox): its addresses, how
/// it signs in and how it words its errors.
abstract class CloudService {
  RemoteProtocol get protocol;

  /// "Google Drive".
  String get label;
  CloudOAuthConfig get oauth;

  /// Whether this build has the service's app id.
  bool get configured => oauth.configured;

  RemoteException errorOf(int status, String body);

  /// Statuses worth trying again besides 429 and 503.
  bool retryIf(int status, String body) => false;

  /// Who signed in: (email, display name), either possibly empty.
  Future<(String, String)> account(CloudHttp http);

  CloudHttp http(CloudAuth auth, {CloudSleep? sleep}) =>
      CloudHttp(service: label, auth: auth, errorOf: errorOf, retryIf: retryIf, sleep: sleep);
}

/// Signs in to [service] through the browser: listens on this device, opens
/// the service's sign-in page, waits for it to come back, trades the code
/// for tokens and asks who signed in.
class CloudSignInFlow {
  CloudSignInFlow(this.service, {this.sleep});

  final CloudService service;
  final CloudSleep? sleep;
  CloudAuthorization? _authorization;
  bool _cancelled = false;

  /// The sign-in page, once [run] has started; to open again or copy.
  Uri? get url => _authorization?.url;

  /// The connection to save, or null when the user declined in the browser
  /// or [cancel] was called. Throws [RemoteException] otherwise.
  Future<RemoteSignIn?> run({
    required Future<bool> Function(Uri url) openBrowser,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    if (!service.configured) {
      throw RemoteException(RemoteErrorKind.unsupported, "This build of Folders can't sign in to ${service.label}.");
    }
    final authorization = await CloudOAuth(service.oauth, sleep: sleep).begin();
    _authorization = authorization;
    if (_cancelled) authorization.cancel();
    // Waits either way: if no browser opened, the link can be copied.
    if (!_cancelled) await openBrowser(authorization.url);
    final tokens = await authorization.finish(timeout: timeout);
    if (tokens == null || _cancelled) return null;

    final http = service.http(FixedCloudAuth(tokens.accessToken), sleep: sleep);
    try {
      final (email, name) = await service.account(http);
      final who = email.isNotEmpty ? email : name;
      return RemoteSignIn(
        name: who.isEmpty ? service.label : '${service.label} ($who)',
        username: email,
        options: {
          if (email.isNotEmpty) 'accountEmail': email,
          if (name.isNotEmpty) 'accountName': name,
        },
        secrets: tokens.toSecrets(),
      );
    } finally {
      http.close();
    }
  }

  void cancel() {
    _cancelled = true;
    _authorization?.cancel();
  }
}

/// What the three cloud file systems share: the connection, its tokens and
/// the HTTP client that uses them.
abstract class CloudFileSystem implements RemoteFileSystem {
  CloudFileSystem(this.connection, this.secrets, {this.sleep});

  @override
  final RemoteConnection connection;
  final RemoteSecrets secrets;
  final CloudSleep? sleep;

  CloudService get service;

  CloudHttp? _http;

  /// Made on first use, so calls before [connect] work too.
  CloudHttp get http =>
      _http ??= service.http(CloudTokenStore(secrets, CloudOAuth(service.oauth, sleep: sleep)), sleep: sleep);

  /// Checks the sign-in still works, with one cheap call.
  Future<void> check();

  @override
  Future<void> connect() async {
    await close();
    final tokens = CloudTokenStore(secrets, CloudOAuth(service.oauth, sleep: sleep));
    await tokens.load();
    _http = service.http(tokens, sleep: sleep);
    await check();
  }

  @override
  Future<void> close() async {
    _http?.close();
    _http = null;
  }
}
