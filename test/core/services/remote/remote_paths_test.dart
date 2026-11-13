import 'package:flutter_test/flutter_test.dart';
import 'package:folders/core/services/remote/remote_fs.dart';

void main() {
  test('remote paths go there and back, with odd names', () {
    final path = RemotePaths.build('nas', '/Photos/2026/a b#%?.jpg');
    expect(path, 'explorer://remote/nas/Photos/2026/a%20b%23%25%3F.jpg');
    expect(RemotePaths.parse(path), ('nas', '/Photos/2026/a b#%?.jpg'));
    expect(RemotePaths.parse('explorer://remote/nas'), ('nas', '/'));
    expect(RemotePaths.parse('explorer://remote/nas/'), ('nas', '/'));
    expect(RemotePaths.parse('C:/Users'), isNull);
  });

  test('normalize, join, parent and name', () {
    expect(RemotePaths.normalize(r'a\b/./c/../d/'), '/a/b/d');
    expect(RemotePaths.normalize(''), '/');
    expect(RemotePaths.join('/a', 'b'), '/a/b');
    expect(RemotePaths.parentOf('/a/b'), '/a');
    expect(RemotePaths.parentOf('/a'), '/');
    expect(RemotePaths.nameOf('/a/b.txt'), 'b.txt');
    expect(RemotePaths.nameOf('/'), '');
  });

  test('connections survive JSON, and unknown protocols are skipped', () {
    const c = RemoteConnection(
      id: 'nas',
      protocol: RemoteProtocol.smb,
      name: 'NAS',
      host: '192.168.1.5',
      port: 445,
      rootPath: '/Public',
      username: 'me',
      options: {'domain': 'WORKGROUP'},
    );
    final back = RemoteConnection.fromJson(c.toJson())!;
    expect(back.toJson(), c.toJson());
    expect(RemoteConnection.fromJson({'id': 'x', 'protocol': 'gopher'}), isNull);
  });
}
