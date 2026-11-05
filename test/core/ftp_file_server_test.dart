import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:folder/core/services/file_server/ftp_file_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// One server reply, with every line of a multi-line reply.
class _Reply {
  _Reply(this.lines) : code = int.parse(lines.first.substring(0, 3));

  final int code;
  final List<String> lines;

  /// The first line without the code.
  String get text => lines.first.length > 4 ? lines.first.substring(4) : '';

  @override
  String toString() => lines.join(r'\n');
}

/// A tiny FTP client on raw sockets.
class _FtpClient {
  _FtpClient._(this._socket) {
    _socket.listen(_onData, onError: (Object _) => _onDone(), onDone: _onDone);
  }

  static Future<_FtpClient> connect(int port) async {
    final client = _FtpClient._(
      await Socket.connect(InternetAddress.loopbackIPv4, port),
    );
    client.greeting = await client.read();
    return client;
  }

  final Socket _socket;
  final _bytes = <int>[];
  final _lines = <String>[];
  Completer<void>? _waiter;
  bool _closed = false;
  late _Reply greeting;

  bool get isClosed => _closed;

  void _onData(Uint8List data) {
    for (final byte in data) {
      if (byte == 0x0a) {
        var line = utf8.decode(_bytes);
        if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
        _lines.add(line);
        _bytes.clear();
      } else {
        _bytes.add(byte);
      }
    }
    _wake();
  }

  void _onDone() {
    _closed = true;
    _wake();
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  Future<String> _line() async {
    while (_lines.isEmpty) {
      if (_closed) throw StateError('Connection closed');
      final waiter = _waiter = Completer<void>();
      await waiter.future.timeout(const Duration(seconds: 20));
    }
    return _lines.removeAt(0);
  }

  /// Reads the next reply.
  Future<_Reply> read() async {
    final lines = [await _line()];
    if (lines.first.length > 3 && lines.first[3] == '-') {
      final end = '${lines.first.substring(0, 3)} ';
      while (!lines.last.startsWith(end)) {
        lines.add(await _line());
      }
    }
    return _Reply(lines);
  }

  void sendRaw(String text) => _socket.add(utf8.encode(text));

  void send(String command) => sendRaw('$command\r\n');

  Future<_Reply> cmd(String command) {
    send(command);
    return read();
  }

  Future<void> login([String user = 'anonymous', String pass = 'guest']) async {
    expect((await cmd('USER $user')).code, 331);
    expect((await cmd('PASS $pass')).code, 230);
  }

  Future<String> pwd() async {
    final reply = await cmd('PWD');
    expect(reply.code, 257, reason: '$reply');
    return RegExp(r'^"((?:[^"]|"")*)"').firstMatch(reply.text)![1]!;
  }

  Future<Socket> pasv() async {
    final reply = await cmd('PASV');
    expect(reply.code, 227, reason: '$reply');
    final m = RegExp(
      r'\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)',
    ).firstMatch(reply.text)!;
    final host = [m[1], m[2], m[3], m[4]].join('.');
    final port = int.parse(m[5]!) * 256 + int.parse(m[6]!);
    return Socket.connect(host, port);
  }

  Future<Socket> epsv() async {
    final reply = await cmd('EPSV');
    expect(reply.code, 229, reason: '$reply');
    final port = int.parse(
      RegExp(r'\(\|\|\|(\d+)\|\)').firstMatch(reply.text)![1]!,
    );
    return Socket.connect(InternetAddress.loopbackIPv4, port);
  }

  /// Runs [command] over a passive data connection; returns the last reply
  /// and the bytes that came over the data connection.
  Future<(_Reply, List<int>)> download(
    String command, {
    bool extended = false,
  }) async {
    final data = extended ? await epsv() : await pasv();
    final received = _collect(data);
    final first = await cmd(command);
    if (first.code != 150) {
      data.destroy();
      received.ignore();
      return (first, const <int>[]);
    }
    final bytes = await received;
    data.destroy();
    return (await read(), bytes);
  }

  /// The text of a listing or file that must transfer fine.
  Future<String> text(String command, {bool extended = false}) async {
    final (reply, bytes) = await download(command, extended: extended);
    expect(reply.code, 226, reason: '$command: $reply');
    return utf8.decode(bytes);
  }

  /// Sends [content] with [command] over a passive data connection;
  /// returns the last reply.
  Future<_Reply> upload(String command, List<int> content) async {
    final data = await pasv();
    final first = await cmd(command);
    if (first.code != 150) {
      data.destroy();
      return first;
    }
    data.add(content);
    await data.close();
    data.destroy();
    return read();
  }

  void close() => _socket.destroy();
}

Future<List<int>> _collect(Stream<List<int>> stream) =>
    stream.fold(<int>[], (all, chunk) => all..addAll(chunk));

List<String> _lines(String listing) {
  expect(listing, anyOf(isEmpty, endsWith('\r\n')));
  return listing.split('\r\n')..removeLast();
}

/// Waits until [condition] holds (or fails after a few seconds).
Future<void> _eventually(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue);
}

void main() {
  late Directory temp;
  late Directory shared;
  late FtpFileServer server;
  final clients = <_FtpClient>[];

  Future<_FtpClient> connect({bool login = true}) async {
    final client = await _FtpClient.connect(server.port!);
    clients.add(client);
    if (login) await client.login();
    return client;
  }

  String sharedPath(String relative) =>
      p.joinAll([shared.path, ...relative.split('/')]);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ftp_server_test');
    shared = await Directory(p.join(temp.path, 'Shared')).create();
    await File(p.join(temp.path, 'secret.txt')).writeAsString('secret');
    await File(sharedPath('hello.txt')).writeAsString('hello world');
    await File(sharedPath('my notes.txt')).writeAsString('notes');
    await Directory(sharedPath('Sub folder/empty')).create(recursive: true);
    await File(sharedPath('Sub folder/ünïcode 文件.md')).writeAsString('# hi');

    server = FtpFileServer();
    await server.start(shared.path, port: 0);
  });

  tearDown(() async {
    for (final client in clients) {
      client.close();
    }
    clients.clear();
    await server.stop();
    // Windows may hold on to a just-closed file for a moment.
    for (var i = 0; ; i++) {
      try {
        await temp.delete(recursive: true);
        break;
      } on FileSystemException {
        if (i == 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  test('reports where it runs and falls back to a free port', () async {
    expect(server.isRunning, isTrue);
    expect(server.url, 'ftp://${Uri.parse(server.url!).host}:${server.port}');
    expect(server.urls, isNotEmpty);
    expect(server.urls.first, server.url);

    final taken = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(taken.close);
    await server.start(shared.path, port: taken.port);
    expect(server.port, isNot(taken.port));
    expect((await connect()).greeting.code, 220);

    await server.stop();
    expect(server.isRunning, isFalse);
    expect(server.url, isNull);
    expect(server.port, isNull);
  });

  test('greets and accepts an anonymous login', () async {
    final c = await connect(login: false);
    expect(c.greeting.lines.single, '220 Folder FTP server ready');
    expect((await c.cmd('USER anonymous')).code, 331);
    expect((await c.cmd('PASS')).code, 230);
    expect(
      (await c.cmd('PWD')).lines.single,
      '257 "/" is the current directory',
    );
    expect(server.clients.value, 1);

    // Any name and password will do.
    await c.login('someone', 'anything');
    expect((await c.cmd('NOOP')).code, 200);
  });

  test('only allows a few commands before login', () async {
    final c = await connect(login: false);
    for (final command in [
      'PWD',
      'CWD Sub folder',
      'LIST',
      'RETR hello.txt',
      'PASV',
      'EPSV',
      'STOR x.txt',
      'SIZE hello.txt',
      'MKD x',
      'STAT',
    ]) {
      expect((await c.cmd(command)).lines.single, '530 Please log in');
    }
    expect((await c.cmd('PASS x')).code, 503);
    expect((await c.cmd('SYST')).lines.single, '215 UNIX Type: L8');
    final feat = await c.cmd('FEAT');
    expect(feat.code, 211);
    expect(
      feat.lines,
      containsAll([
        ' UTF8',
        ' MLST type*;size*;modify*;perm*;',
        ' MLSD',
        ' SIZE',
        ' MDTM',
        ' REST STREAM',
        ' EPSV',
        ' PASV',
      ]),
    );
    expect(feat.lines.last, '211 End');
    expect((await c.cmd('OPTS UTF8 ON')).code, 200);
    expect((await c.cmd('NOOP')).code, 200);
    expect((await c.cmd('HELP')).code, 214);
    expect((await c.cmd('AUTH TLS')).code, 502);
    expect((await c.cmd('AUTH SSL')).code, 502);
    expect(File(sharedPath('x')).existsSync(), isFalse);
  });

  test('checks the password when a login is set', () async {
    await server.start(
      shared.path,
      port: 0,
      username: 'alice',
      password: 's3cret',
    );
    final c = await connect(login: false);
    expect((await c.cmd('USER alice')).code, 331);
    final watch = Stopwatch()..start();
    expect((await c.cmd('PASS wrong')).lines.single, '530 Login incorrect');
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(900));
    expect((await c.cmd('PWD')).code, 530);
    expect((await c.cmd('USER bob')).code, 331);
    expect((await c.cmd('PASS s3cret')).code, 530);

    await c.login('alice', 's3cret');
    expect((await c.cmd('PWD')).code, 257);

    // A new password signs out sessions that used the old one.
    server.password = 'changed';
    expect((await c.cmd('PWD')).code, 530);
    await c.login('alice', 'changed');
    expect((await c.cmd('PWD')).code, 257);

    // Without a login anyone may come in again.
    server.username = null;
    final anonymous = await connect();
    expect((await anonymous.cmd('PWD')).code, 257);
  });

  test('changes folders without ever leaving the shared folder', () async {
    final c = await connect();
    expect((await c.cmd('CWD Sub folder')).code, 250);
    expect(
      (await c.cmd('PWD')).lines.single,
      '257 "/Sub folder" is the current directory',
    );
    expect((await c.cmd('CWD empty')).code, 250);
    expect(await c.pwd(), '/Sub folder/empty');
    expect((await c.cmd('CDUP')).code, 250);
    expect(await c.pwd(), '/Sub folder');
    expect((await c.cmd('XCUP')).code, 250);
    expect(await c.pwd(), '/');
    expect((await c.cmd('CWD ..')).code, 250);
    expect(await c.pwd(), '/');
    expect((await c.cmd('CWD ../..')).code, 250);
    expect(await c.pwd(), '/');
    expect((await c.cmd('XCWD /Sub folder/../Sub folder/./empty/')).code, 250);
    expect((await c.cmd('XPWD')).text, startsWith('"/Sub folder/empty"'));
    expect((await c.cmd('CWD /')).code, 250);
    expect((await c.cmd('CWD missing')).code, 550);
    expect((await c.cmd('CWD hello.txt')).code, 550);
    expect((await c.cmd(r'CWD ..\..')).code, 550);
    expect(await c.pwd(), '/');
  });

  test('LIST sends ls -l lines', () async {
    await File(sharedPath('hello.txt')).setLastModified(DateTime(2020, 3, 3));
    final c = await connect();
    final lines = _lines(await c.text('LIST'));
    expect(lines, hasLength(3));
    final pattern = RegExp(
      r'^([-d])[-rwx]{9} +\d+ +\S+ +\S+ +(\d+) +([A-Z][a-z]{2}) +(\d{1,2}) +'
      r'(\d{2}:\d{2}|\d{4}) (.+)$',
    );
    final byName = {
      for (final line in lines) pattern.firstMatch(line)![6]!: line,
    };
    expect(
      byName.keys,
      containsAll(['Sub folder', 'hello.txt', 'my notes.txt']),
    );
    expect(byName['Sub folder'], startsWith('d'));
    expect(byName['hello.txt'], startsWith('-r--r--r--'));
    expect(pattern.firstMatch(byName['hello.txt']!)![2], '11');
    expect(byName['hello.txt'], contains(' Mar  3  2020 hello.txt'));
    expect(pattern.firstMatch(byName['my notes.txt']!)![2], '5');
    expect(
      pattern.firstMatch(byName['my notes.txt']!)![5],
      matches(r'^\d\d:\d\d$'),
    );

    // Options are ignored; names with spaces and Unicode survive.
    final sub = _lines(await c.text('LIST -la Sub folder'));
    expect(sub, hasLength(2));
    expect(sub.first, startsWith('d'));
    expect(sub.first, endsWith(' empty'));
    expect(sub.last, startsWith('-'));
    expect(pattern.firstMatch(sub.last)![2], '4');
    expect(sub.last, endsWith(' ünïcode 文件.md'));

    // A file lists just itself.
    final single = _lines(await c.text('LIST my notes.txt'));
    expect(single.single, startsWith('-'));
    expect(single.single, endsWith(' my notes.txt'));

    expect((await c.download('LIST missing')).$1.code, 550);

    server.allowChanges = true;
    expect(await c.text('LIST'), contains('-rw-r--r--'));
  });

  test('MLSD and MLST give RFC 3659 facts', () async {
    await File(
      sharedPath('hello.txt'),
    ).setLastModified(DateTime.utc(2024, 1, 2, 3, 4, 5));
    final c = await connect();
    final lines = _lines(await c.text('MLSD'));
    expect(lines, hasLength(3));
    expect(
      lines,
      contains('type=file;size=11;modify=20240102030405;perm=r; hello.txt'),
    );
    expect(
      lines.singleWhere((line) => line.endsWith(' Sub folder')),
      matches(r'^type=dir;modify=\d{14};perm=el; Sub folder$'),
    );
    final sub = _lines(await c.text('MLSD Sub folder'));
    expect(sub.last, endsWith('; ünïcode 文件.md'));
    expect(sub.last, startsWith('type=file;size=4;'));

    final mlst = await c.cmd('MLST hello.txt');
    expect(mlst.lines, [
      '250-Listing /hello.txt',
      ' type=file;size=11;modify=20240102030405;perm=r; /hello.txt',
      '250 End',
    ]);
    expect((await c.cmd('MLST')).lines[1], startsWith(' type=dir;'));
    expect((await c.cmd('MLST missing')).code, 550);
    expect((await c.download('MLSD hello.txt')).$1.code, 501);
    expect((await c.cmd('OPTS MLST type;size;')).code, 200);

    server.allowChanges = true;
    final writable = await c.text('MLSD');
    expect(
      writable,
      contains('type=file;size=11;modify=20240102030405;perm=rwadf; hello.txt'),
    );
    expect(
      writable,
      matches(RegExp(r'type=dir;modify=\d{14};perm=el\w*c\w*;')),
    );
  });

  test('NLST lists names', () async {
    final c = await connect();
    expect(_lines(await c.text('NLST')).toSet(), {
      'Sub folder',
      'hello.txt',
      'my notes.txt',
    });
    expect(_lines(await c.text('NLST -a Sub folder')).toSet(), {
      'empty',
      'ünïcode 文件.md',
    });
    expect(_lines(await c.text('NLST Sub folder/empty')), isEmpty);
  });

  test('shares only the chosen items, read-only', () async {
    await server.start(shared.path, port: 0, only: [sharedPath('Sub folder')]);
    server.allowChanges = true;
    final c = await connect();
    expect(_lines(await c.text('NLST')), ['Sub folder']);
    expect(await c.text('LIST'), isNot(contains('hello.txt')));
    expect((await c.download('RETR hello.txt')).$1.code, 550);
    expect((await c.download('RETR Sub folder/ünïcode 文件.md')).$1.code, 226);
    expect((await c.upload('STOR new.txt', [1])).code, 550);
    expect(File(sharedPath('new.txt')).existsSync(), isFalse);
  });

  test('RETR streams files, also from a REST offset', () async {
    final big = Uint8List.fromList(
      List.generate(700 * 1024 + 13, (i) => (i * 31 + i ~/ 256) & 0xff),
    );
    await File(sharedPath('big.bin')).writeAsBytes(big);
    final c = await connect();
    expect((await c.cmd('TYPE I')).code, 200);

    var (reply, bytes) = await c.download('RETR hello.txt');
    expect(reply.lines.single, '226 Transfer complete');
    expect(utf8.decode(bytes), 'hello world');

    expect((await c.cmd('REST 6')).lines.single, '350 Restarting at 6');
    (reply, bytes) = await c.download('RETR hello.txt');
    expect(reply.code, 226);
    expect(utf8.decode(bytes), 'world');

    // REST applies to one transfer only.
    expect(await c.text('RETR hello.txt'), 'hello world');

    (reply, bytes) = await c.download('RETR big.bin');
    expect(reply.code, 226);
    expect(bytes, big);

    expect((await c.cmd('REST 100000')).code, 350);
    (reply, bytes) = await c.download('RETR /big.bin', extended: true);
    expect(reply.code, 226);
    expect(bytes, big.sublist(100000));

    expect(await c.text('RETR Sub folder/ünïcode 文件.md'), '# hi');
    expect((await c.cmd('REST 12')).code, 350);
    expect((await c.download('RETR hello.txt')).$1.code, 554);
    expect((await c.download('RETR missing.txt')).$1.code, 550);
    expect((await c.download('RETR Sub folder')).$1.code, 550);
    expect((await c.cmd('REST x')).code, 501);
    // No PASV/PORT first.
    expect((await c.cmd('RETR hello.txt')).code, 425);
  });

  test('SIZE and MDTM', () async {
    await File(
      sharedPath('hello.txt'),
    ).setLastModified(DateTime.utc(2023, 12, 31, 23, 59, 58));
    final c = await connect();
    expect((await c.cmd('SIZE hello.txt')).lines.single, '213 11');
    expect(
      (await c.cmd('SIZE /Sub folder/ünïcode 文件.md')).lines.single,
      '213 4',
    );
    expect((await c.cmd('SIZE Sub folder')).code, 550);
    expect((await c.cmd('SIZE missing')).code, 550);
    expect((await c.cmd('MDTM hello.txt')).lines.single, '213 20231231235958');
    expect((await c.cmd('MDTM missing')).code, 550);
  });

  test('a read-only share refuses changes and writes nothing', () async {
    final c = await connect();
    expect(
      (await c.upload('STOR new.txt', [1, 2, 3])).lines.single,
      '550 Permission denied: this share is read-only',
    );
    expect((await c.upload('APPE hello.txt', [1])).code, 550);
    expect((await c.upload('STOU', [1])).code, 550);
    expect((await c.cmd('DELE hello.txt')).code, 550);
    expect((await c.cmd('MKD New')).code, 550);
    expect((await c.cmd('RMD Sub folder/empty')).code, 550);
    expect((await c.cmd('RNFR hello.txt')).code, 550);
    expect((await c.cmd('RNTO renamed.txt')).code, 550);

    expect(File(sharedPath('new.txt')).existsSync(), isFalse);
    expect(File(sharedPath('hello.txt')).readAsStringSync(), 'hello world');
    expect(Directory(sharedPath('New')).existsSync(), isFalse);
    expect(Directory(sharedPath('Sub folder/empty')).existsSync(), isTrue);
    expect(shared.listSync(), hasLength(3));
  });

  test('with allowChanges clients upload and organise files', () async {
    final c = await connect();
    // Can be switched on while running.
    server.allowChanges = true;
    final received = <String>[];
    final subscription = server.received.listen(received.add);
    addTearDown(subscription.cancel);

    final uploaded = sharedPath('up load.txt');
    expect(
      (await c.upload('STOR up load.txt', utf8.encode('first'))).code,
      226,
    );
    expect(File(uploaded).readAsStringSync(), 'first');
    await _eventually(() => received.isNotEmpty);
    expect(p.equals(received.single, uploaded), isTrue);

    expect(
      (await c.upload('APPE up load.txt', utf8.encode(' second'))).code,
      226,
    );
    expect(File(uploaded).readAsStringSync(), 'first second');

    // A resumed upload keeps the first REST bytes.
    expect((await c.cmd('REST 3')).code, 350);
    expect((await c.upload('STOR up load.txt', utf8.encode('ST!'))).code, 226);
    expect(File(uploaded).readAsStringSync(), 'firST!');

    // STOR replaces.
    expect((await c.upload('STOR hello.txt', utf8.encode('new'))).code, 226);
    expect(File(sharedPath('hello.txt')).readAsStringSync(), 'new');

    final big = Uint8List.fromList(
      List.generate(1024 * 1024 + 7, (i) => (i * 7 + i ~/ 1000) & 0xff),
    );
    expect((await c.upload('STOR /Sub folder/big.bin', big)).code, 226);
    expect(File(sharedPath('Sub folder/big.bin')).readAsBytesSync(), big);

    expect((await c.upload('STOU hello.txt', utf8.encode('u'))).code, 226);
    expect(File(sharedPath('hello (1).txt')).readAsStringSync(), 'u');

    await _eventually(() => received.length == 6);
    expect(p.equals(received[4], sharedPath('Sub folder/big.bin')), isTrue);

    expect(
      (await c.cmd('MKD New folder')).lines.single,
      '257 "/New folder" created',
    );
    expect(Directory(sharedPath('New folder')).existsSync(), isTrue);
    expect((await c.cmd('XMKD New folder')).code, 550);
    expect((await c.cmd('MKD missing/child')).code, 550);

    expect((await c.cmd('RNFR up load.txt')).code, 350);
    expect((await c.cmd('RNTO New folder/moved.txt')).code, 250);
    expect(File(uploaded).existsSync(), isFalse);
    expect(
      File(sharedPath('New folder/moved.txt')).readAsStringSync(),
      'firST!',
    );

    expect((await c.cmd('RNFR hello.txt')).code, 350);
    expect((await c.cmd('RNTO my notes.txt')).code, 550);
    expect((await c.cmd('RNTO other.txt')).code, 503);
    expect((await c.cmd('RNFR missing.txt')).code, 550);
    expect((await c.cmd('RNFR /')).code, 550);

    expect((await c.cmd('RNFR New folder')).code, 350);
    expect((await c.cmd('RNTO New folder/inside')).code, 550);
    expect((await c.cmd('RNFR New folder')).code, 350);
    expect((await c.cmd('RNTO Renamed folder')).code, 250);
    expect(Directory(sharedPath('Renamed folder')).existsSync(), isTrue);
    expect(Directory(sharedPath('New folder')).existsSync(), isFalse);

    expect((await c.cmd('RMD Renamed folder')).lines.single, startsWith('550'));
    expect((await c.cmd('DELE Renamed folder')).code, 550);
    expect((await c.cmd('DELE Renamed folder/moved.txt')).code, 250);
    expect(File(sharedPath('Renamed folder/moved.txt')).existsSync(), isFalse);
    expect((await c.cmd('XRMD Renamed folder')).code, 250);
    expect(Directory(sharedPath('Renamed folder')).existsSync(), isFalse);
    expect((await c.cmd('RMD /')).code, 550);
    expect((await c.cmd('DELE missing.txt')).code, 550);
    expect(shared.existsSync(), isTrue);

    // And back off again.
    server.allowChanges = false;
    expect((await c.cmd('DELE hello.txt')).code, 550);
    expect(File(sharedPath('hello.txt')).existsSync(), isTrue);
  });

  test('nothing outside the shared folder can be reached', () async {
    server.allowChanges = true;
    final c = await connect();
    for (final path in [
      '../secret.txt',
      '/../secret.txt',
      '../../secret.txt',
      r'..\secret.txt',
      r'/..\secret.txt',
      'Sub folder/../../secret.txt',
      '%2e%2e/secret.txt',
    ]) {
      final (reply, bytes) = await c.download('RETR $path');
      expect(reply.code, 550, reason: path);
      expect(bytes, isEmpty);
      expect((await c.cmd('SIZE $path')).code, 550, reason: path);
      expect((await c.cmd('DELE $path')).code, 550, reason: path);
      expect((await c.cmd('RNFR $path')).code, 550, reason: path);
    }
    expect((await c.cmd('CWD ../..')).code, 250);
    expect(await c.pwd(), '/');
    expect((await c.download('RETR secret.txt')).$1.code, 550);
    expect(await c.text('NLST'), isNot(contains('secret')));
    expect(await c.text('LIST ..'), isNot(contains('secret')));
    expect(await c.text('LIST ..'), contains('hello.txt'));

    // Writes with .. land inside the shared folder.
    expect((await c.upload('STOR ../escaped.txt', [1])).code, 226);
    expect(File(p.join(temp.path, 'escaped.txt')).existsSync(), isFalse);
    expect(File(sharedPath('escaped.txt')).existsSync(), isTrue);
    expect((await c.cmd('MKD ../../outside')).code, 257);
    expect(Directory(p.join(temp.path, 'outside')).existsSync(), isFalse);
    expect(File(p.join(temp.path, 'secret.txt')).readAsStringSync(), 'secret');
  });

  test('symlinks leading out of the shared folder are refused', () async {
    try {
      await Link(sharedPath('escape')).create(temp.path);
    } on FileSystemException {
      markTestSkipped('Links cannot be created here');
      return;
    }
    var fileLink = true;
    try {
      await Link(
        sharedPath('secret-link.txt'),
      ).create(p.join(temp.path, 'secret.txt'));
    } on FileSystemException {
      fileLink = false;
    }
    server.allowChanges = true;
    final c = await connect();
    expect((await c.cmd('CWD escape')).code, 550);
    expect((await c.download('RETR escape/secret.txt')).$1.code, 550);
    expect((await c.download('LIST escape')).$1.code, 550);
    expect((await c.upload('STOR escape/new.txt', [1])).code, 553);
    expect((await c.cmd('MKD escape/new')).code, 550);
    expect(File(p.join(temp.path, 'new.txt')).existsSync(), isFalse);
    expect(Directory(p.join(temp.path, 'new')).existsSync(), isFalse);
    expect(await c.text('NLST'), isNot(contains('escape')));
    if (fileLink) {
      expect((await c.download('RETR secret-link.txt')).$1.code, 550);
      expect((await c.upload('STOR secret-link.txt', [1])).code, 553);
      expect(
        File(p.join(temp.path, 'secret.txt')).readAsStringSync(),
        'secret',
      );
    }
  });

  test('EPSV, PORT and EPRT data connections work', () async {
    final c = await connect();
    expect(await c.text('LIST', extended: true), contains(' hello.txt'));

    Future<String> active(String Function(int port) command) async {
      final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final incoming = listener.first;
      expect((await c.cmd(command(listener.port))).code, 200);
      expect((await c.cmd('RETR hello.txt')).code, 150);
      final socket = await incoming.timeout(const Duration(seconds: 10));
      final bytes = await _collect(socket);
      socket.destroy();
      expect((await c.read()).code, 226);
      return utf8.decode(bytes);
    }

    expect(
      await active((port) => 'PORT 127,0,0,1,${port ~/ 256},${port % 256}'),
      'hello world',
    );
    expect(await active((port) => 'EPRT |1|127.0.0.1|$port|'), 'hello world');

    // Never connects to anyone but the client.
    expect((await c.cmd('PORT 10,1,2,3,40,1')).code, 500);
    expect((await c.cmd('PORT 127,0,0,1,0,21')).code, 500);
    expect((await c.cmd('PORT nonsense')).code, 501);
    expect((await c.cmd('EPRT |1|10.1.2.3|5000|')).code, 500);
    expect((await c.cmd('EPRT |2|::1|5000|')).code, 522);
    expect((await c.cmd('EPSV 2')).code, 522);
  });

  test('ABOR stops a running download and the session carries on', () async {
    await File(sharedPath('huge.bin')).writeAsBytes(Uint8List(16 << 20));
    final c = await connect();
    final data = await c.pasv();
    expect((await c.cmd('RETR huge.bin')).code, 150);
    // Not reading: flow control stalls the transfer.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    c.send('ABOR');
    final codes = [(await c.read()).code, (await c.read()).code];
    expect(codes.first, anyOf(426, 226));
    expect(codes.last, 226);
    data.destroy();
    expect((await c.cmd('NOOP')).code, 200);
    expect(await c.text('RETR hello.txt'), 'hello world');
  });

  test('clients vanishing mid-transfer do not hurt the server', () async {
    await File(sharedPath('huge.bin')).writeAsBytes(Uint8List(8 << 20));
    server.allowChanges = true;

    final downloader = await connect();
    final down = await downloader.pasv();
    expect((await downloader.cmd('RETR huge.bin')).code, 150);
    await down.first;
    down.destroy();
    downloader.close();

    final uploader = await connect();
    final up = await uploader.pasv();
    expect((await uploader.cmd('STOR partial.bin')).code, 150);
    up.add(List.filled(100000, 1));
    await up.flush();
    up.destroy();
    uploader.close();

    await _eventually(() => server.clients.value == 0);
    final c = await connect();
    expect(await c.text('NLST'), contains('hello.txt'));
    expect(await c.text('RETR hello.txt'), 'hello world');
    expect(server.clients.value, 1);
  });

  test('QUIT, stop and the client count', () async {
    final first = await connect();
    final second = await connect(login: false);
    expect(server.clients.value, 2);
    expect((await first.cmd('QUIT')).code, 221);
    await _eventually(() => first.isClosed);
    await _eventually(() => server.clients.value == 1);

    final port = server.port!;
    await server.stop();
    expect(server.clients.value, 0);
    await expectLater(second.read(), throwsStateError);
    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, port),
      throwsA(isA<SocketException>()),
    );
  });

  test('other commands and line handling', () async {
    final c = await connect();
    expect((await c.cmd('XYZZY')).lines.single, '502 Command not implemented');
    expect((await c.cmd('SITE CHMOD 777 hello.txt')).code, 502);
    expect((await c.cmd('PBSZ 0')).code, 502);
    expect((await c.cmd('PROT P')).code, 502);
    expect((await c.cmd('TYPE A')).code, 200);
    expect((await c.cmd('TYPE L 8')).code, 200);
    expect((await c.cmd('TYPE X')).code, 504);
    expect((await c.cmd('MODE S')).code, 200);
    expect((await c.cmd('STRU F')).code, 200);
    expect((await c.cmd('ALLO 100')).code, 202);
    final stat = await c.cmd('STAT');
    expect(stat.code, 211);
    expect(stat.lines.length, greaterThan(2));
    final statFile = await c.cmd('STAT hello.txt');
    expect(statFile.code, 213);
    expect(statFile.lines.join('\n'), contains(' hello.txt'));
    expect((await c.cmd('EPSV ALL')).code, 200);

    // Case-insensitive, bare LF, several commands in one packet.
    expect((await c.cmd('pwd')).code, 257);
    c.sendRaw('NOOP\n');
    expect((await c.read()).code, 200);
    c.sendRaw('NOOP\r\nSYST\r\nCWD Sub folder\r\nPWD\r\n');
    expect((await c.read()).code, 200);
    expect((await c.read()).code, 215);
    expect((await c.read()).code, 250);
    expect((await c.read()).text, startsWith('"/Sub folder"'));
    expect((await c.cmd('')).code, 500);
  });
}
