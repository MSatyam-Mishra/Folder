import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:folders/core/services/remote/cloud/cloud_http.dart';
import 'package:folders/core/services/remote/remote_fs.dart';

/// The app ids of the cloud services, given to `flutter build` as
/// `--dart-define`s (see docs/cloud-setup.md). Empty in builds without them,
/// and then the service isn't offered.
abstract final class CloudIds {
  static const googleClientId = String.fromEnvironment('FOLDERS_GOOGLE_CLIENT_ID');

  /// Google calls it a secret, but an app on people's machines can't keep
  /// one; Google knows, and still asks for it.
  static const googleClientSecret = String.fromEnvironment('FOLDERS_GOOGLE_CLIENT_SECRET');
  static const oneDriveClientId = String.fromEnvironment('FOLDERS_ONEDRIVE_CLIENT_ID');
  static const dropboxAppKey = String.fromEnvironment('FOLDERS_DROPBOX_APP_KEY');

  /// The port the browser comes back to after signing in, the same as
  /// rclone's. Dropbox needs it exactly; the others accept any port.
  static const redirectPort = 53682;
}

/// How one service signs in: OAuth 2 with PKCE, back to this machine.
class CloudOAuthConfig {
  const CloudOAuthConfig({
    required this.service,
    required this.authorizeUrl,
    required this.tokenUrl,
    required this.clientId,
    this.clientSecret = '',
    this.scopes = const [],
    this.authorizeParams = const {},
    this.redirectHost = '127.0.0.1',
    this.redirectPort = CloudIds.redirectPort,
    this.exactPort = false,
    this.scopeOnRefresh = false,
  });

  final String service;
  final Uri authorizeUrl;
  final Uri tokenUrl;
  final String clientId;
  final String clientSecret;
  final List<String> scopes;
  final Map<String, String> authorizeParams;

  /// `127.0.0.1` or `localhost`, as the service's app registration has it.
  final String redirectHost;

  /// 0 picks a free port (tests).
  final int redirectPort;

  /// The service accepts only the registered port (Dropbox), so another
  /// program on it is an error rather than a reason to pick another.
  final bool exactPort;

  /// Microsoft wants the scopes again when renewing a token.
  final bool scopeOnRefresh;

  bool get configured => clientId.isNotEmpty;
}

/// What the token endpoint gave.
class CloudTokens {
  const CloudTokens({required this.accessToken, this.refreshToken, this.expiry});

  factory CloudTokens.fromJson(Map<String, Object?> json, {DateTime? now}) {
    final token = json['access_token'];
    if (token is! String || token.isEmpty) {
      throw const RemoteException(RemoteErrorKind.auth, "The sign-in didn't give an access token.");
    }
    final seconds = switch (json['expires_in']) {
      final num n => n.toInt(),
      final String s => int.tryParse(s),
      _ => null,
    };
    final refresh = json['refresh_token'];
    return CloudTokens(
      accessToken: token,
      refreshToken: refresh is String && refresh.isNotEmpty ? refresh : null,
      expiry: seconds == null ? null : (now ?? DateTime.now()).toUtc().add(Duration(seconds: seconds)),
    );
  }

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiry;

  Map<String, String> toSecrets() => {
        'accessToken': accessToken,
        if (refreshToken != null) 'refreshToken': refreshToken!,
        if (expiry != null) 'tokenExpiry': expiry!.toUtc().toIso8601String(),
      };
}

/// The token endpoint and the browser round trip of one service.
class CloudOAuth {
  CloudOAuth(this.config, {CloudSleep? sleep}) : _sleep = sleep;

  final CloudOAuthConfig config;
  final CloudSleep? _sleep;

  /// A fresh access token for [refreshToken].
  Future<CloudTokens> refresh(String refreshToken) => _token({
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        if (config.scopeOnRefresh && config.scopes.isNotEmpty) 'scope': config.scopes.join(' '),
      });

  /// Trades the code the browser brought back for tokens.
  Future<CloudTokens> exchange(String code, {required String verifier, required String redirectUri}) => _token({
        'grant_type': 'authorization_code',
        'code': code,
        'code_verifier': verifier,
        'redirect_uri': redirectUri,
      });

  Future<CloudTokens> _token(Map<String, String> fields) async {
    final http = CloudHttp(service: config.service, errorOf: _tokenError, sleep: _sleep);
    try {
      final body = {
        ...fields,
        'client_id': config.clientId,
        if (config.clientSecret.isNotEmpty) 'client_secret': config.clientSecret,
      };
      final response = await http.send('POST', config.tokenUrl,
          authorized: false,
          headers: {'content-type': 'application/x-www-form-urlencoded', 'accept': 'application/json'},
          body: utf8.encode(Uri(queryParameters: body).query));
      return CloudTokens.fromJson(response.json);
    } finally {
      http.close();
    }
  }

  RemoteException _tokenError(int status, String body) {
    final error = jsonObject(body)['error'];
    if (status == 400 || status == 401) {
      // invalid_grant: the refresh token was withdrawn or has expired.
      return RemoteException(RemoteErrorKind.auth,
          error == 'invalid_grant' || error == 'invalid_token' || error == 'unauthorized_client'
              ? 'Your sign-in to ${config.service} has expired or was withdrawn. Sign in again.'
              : '${config.service} refused the sign-in ($error). Sign in again.');
    }
    return RemoteException(RemoteErrorKind.other, "${config.service}'s sign-in failed (error $status). Try again later.");
  }

  /// Starts listening for the browser's return and gives the address to
  /// open. Throws [RemoteException] when the port is taken and the service
  /// needs that one.
  Future<CloudAuthorization> begin() async {
    final servers = await _listen();
    final port = servers.first.port;
    final redirectUri = 'http://${config.redirectHost}:$port/';
    final verifier = _randomText(64);
    final state = _randomText(24);
    final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final url = config.authorizeUrl.replace(queryParameters: {
      ...config.authorizeUrl.queryParameters,
      'client_id': config.clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri,
      if (config.scopes.isNotEmpty) 'scope': config.scopes.join(' '),
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      ...config.authorizeParams,
    });
    return CloudAuthorization._(this, servers, url, redirectUri, verifier, state);
  }

  Future<List<HttpServer>> _listen() async {
    Future<HttpServer> bind(InternetAddress address, int port) => HttpServer.bind(address, port);
    HttpServer first;
    try {
      first = await bind(InternetAddress.loopbackIPv4, config.redirectPort);
    } on SocketException {
      if (config.exactPort) {
        throw RemoteException(
          RemoteErrorKind.other,
          'Another program on this device is using port ${config.redirectPort} (rclone signing in, perhaps), '
          'and ${config.service} only signs in through that one. Close it and try again.',
        );
      }
      first = await bind(InternetAddress.loopbackIPv4, 0);
    }
    final servers = [first];
    if (config.redirectHost == 'localhost') {
      // Browsers may try ::1 first for localhost.
      try {
        servers.add(await bind(InternetAddress.loopbackIPv6, first.port));
      } on SocketException {
        // No IPv6 here; 127.0.0.1 will do.
      }
    }
    return servers;
  }

  static final _random = Random.secure();

  static String _randomText(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    return String.fromCharCodes(List.generate(length, (_) => chars.codeUnitAt(_random.nextInt(chars.length))));
  }
}

/// One sign-in in progress: the address to open in the browser, and the
/// code it brings back.
class CloudAuthorization {
  CloudAuthorization._(this._oauth, this._servers, this.url, this.redirectUri, this._verifier, this._state) {
    for (final server in _servers) {
      server.listen(_handle, onError: (Object _) {});
    }
  }

  final CloudOAuth _oauth;
  final List<HttpServer> _servers;

  /// What to open in the browser.
  final Uri url;
  final String redirectUri;
  final String _verifier;
  final String _state;
  final _code = Completer<String?>();

  String get _service => _oauth.config.service;

  /// The code, or null when the user declined in the browser or [cancel]
  /// was called.
  Future<String?> get code => _code.future;

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final query = request.uri.queryParameters;
    if (request.method != 'GET' || request.uri.path != '/' || query.isEmpty) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (query['state'] != _state) {
      // A page left open from an earlier try.
      await _page(response, HttpStatus.badRequest, 'This sign-in page is out of date',
          'Go back to Folders and start signing in again.');
      return;
    }
    final error = query['error'];
    if (error != null) {
      final declined = error == 'access_denied';
      await _page(
        response,
        HttpStatus.ok,
        declined ? 'Sign-in cancelled' : "Couldn't sign in",
        declined
            ? 'Folders was not given access to $_service. You can close this tab.'
            : '$_service said: ${query['error_description'] ?? error}. You can close this tab and try again.',
      );
      if (_code.isCompleted) return;
      if (declined) {
        _code.complete(null);
      } else {
        _code.completeError(RemoteException(RemoteErrorKind.auth,
            '$_service refused the sign-in: ${query['error_description'] ?? error}.'));
      }
      return;
    }
    final code = query['code'];
    if (code == null || code.isEmpty) {
      await _page(response, HttpStatus.badRequest, "Couldn't sign in", 'The answer had no code. Try again.');
      return;
    }
    await _page(response, HttpStatus.ok, 'Signed in to $_service',
        'You can close this tab and go back to Folders.');
    if (!_code.isCompleted) _code.complete(code);
  }

  Future<void> _page(HttpResponse response, int status, String title, String text) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..headers.set('cache-control', 'no-store')
      ..write(_html(title, text));
    await response.close();
  }

  static String _html(String title, String text) {
    final t = const HtmlEscape().convert(title);
    final p = const HtmlEscape().convert(text);
    return '<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1"><title>$t</title>'
        '<style>body{font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:90vh;'
        'margin:0 16px;background:#f6f6f7;color:#18181b}main{max-width:420px;text-align:center}'
        'h1{font-size:1.4em;font-weight:600}p{color:#52525b;line-height:1.5}'
        '@media(prefers-color-scheme:dark){body{background:#18181b;color:#fafafa}p{color:#a1a1aa}}</style>'
        '</head><body><main><h1>$t</h1><p>$p</p></main></body></html>';
  }

  /// Gives up waiting: [code] completes with null.
  void cancel() {
    if (!_code.isCompleted) _code.complete(null);
  }

  /// Waits for the code ([timeout] at most), then trades it for tokens.
  /// Null when the user declined or [cancel] was called.
  Future<CloudTokens?> finish({Duration timeout = const Duration(minutes: 10)}) async {
    try {
      final code = await this.code.timeout(timeout, onTimeout: () {
        throw RemoteException(RemoteErrorKind.cancelled,
            'Signing in to $_service took too long. Try again, and finish signing in within ${timeout.inMinutes} minutes.');
      });
      if (code == null) return null;
      return await _oauth.exchange(code, verifier: _verifier, redirectUri: redirectUri);
    } finally {
      await close();
    }
  }

  Future<void> close() async {
    for (final server in _servers) {
      await server.close();
    }
  }
}

/// Keeps a connection's tokens: hands out the access token, renews it with
/// the refresh token when it's about to expire or is refused, and writes the
/// new ones back to [RemoteSecrets].
class CloudTokenStore implements CloudAuth {
  CloudTokenStore(this.secrets, this.oauth, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final RemoteSecrets secrets;
  final CloudOAuth oauth;
  final DateTime Function() _now;

  String? _access;
  String? _refresh;
  DateTime? _expiry;
  bool _loaded = false;
  Future<void>? _renewing;

  String get _service => oauth.config.service;

  Future<void> load() async {
    _access = await secrets.read('accessToken');
    _refresh = await secrets.read('refreshToken');
    final expiry = await secrets.read('tokenExpiry');
    _expiry = expiry == null ? null : DateTime.tryParse(expiry);
    _loaded = true;
    if ((_access ?? '').isEmpty && (_refresh ?? '').isEmpty) {
      throw RemoteException(RemoteErrorKind.auth, 'Not signed in to $_service. Sign in again.');
    }
  }

  @override
  Future<String> accessToken() async {
    if (!_loaded) await load();
    await _renewing;
    final soon = _now().toUtc().add(const Duration(minutes: 1));
    if ((_access ?? '').isEmpty || (_expiry != null && _expiry!.isBefore(soon))) {
      if ((_refresh ?? '').isNotEmpty) await _renew();
    }
    final token = _access;
    if (token == null || token.isEmpty) {
      throw RemoteException(RemoteErrorKind.auth, 'Your sign-in to $_service has expired. Sign in again.');
    }
    return token;
  }

  @override
  Future<void> renew(String used) async {
    await _renewing;
    if (_access != used) return; // Someone renewed it meanwhile.
    if ((_refresh ?? '').isEmpty) {
      throw RemoteException(RemoteErrorKind.auth, 'Your sign-in to $_service has expired. Sign in again.');
    }
    await _renew();
  }

  Future<void> _renew() {
    return _renewing ??= () async {
      try {
        final tokens = await oauth.refresh(_refresh!);
        _access = tokens.accessToken;
        _expiry = tokens.expiry;
        // Microsoft hands out a new refresh token each time; Google keeps the old.
        if (tokens.refreshToken != null) _refresh = tokens.refreshToken;
        await secrets.write('accessToken', _access);
        await secrets.write('tokenExpiry', _expiry?.toUtc().toIso8601String());
        if (tokens.refreshToken != null) await secrets.write('refreshToken', _refresh);
      } finally {
        _renewing = null;
      }
    }();
  }
}
