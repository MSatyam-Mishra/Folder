"""Local servers for the network places tests
(test/core/services/remote/remote_servers_test.dart): SFTP (asyncssh), FTP
(pyftpdlib), FTPS (mini_ftps.py, on Python's own ssl: pyftpdlib's TLS through
pyOpenSSL crashed on Python 3.14) and WebDAV (wsgidav + cheroot; Basic,
Digest and HTTPS).

  pip install --target <packages dir> pyftpdlib asyncssh wsgidav cheroot cryptography
  python -I -X utf8 tool/remote_servers/remote_test_servers.py <packages dir> <work dir>
  EXPLORER_REMOTE_SERVERS=<work dir>/servers.json flutter test test/core/services/remote/remote_servers_test.dart

Serves <work dir>/<protocol> as each server's root, user "tester", password
"secret123", on 127.0.0.1 only. Writes <work dir>/servers.json with the
ports, a self-signed certificate and the SSH client key (key.pem, passphrase
"keypass"), then runs until stopped (Ctrl+C, or end its process and the two
FTPS ones it prints).
"""
import json
import os
import socket
import sys
import threading

sys.path.insert(0, os.path.abspath(sys.argv[1]))
WORK = os.path.abspath(sys.argv[2])
USER, PASSWORD = 'tester', 'secret123'


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port


def root(name):
    path = os.path.join(WORK, name)
    os.makedirs(path, exist_ok=True)
    return path


def make_cert():
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
    import datetime
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'localhost')])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=30))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName('localhost')]), critical=False)
            .sign(key, hashes.SHA256()))
    cert_path = os.path.join(WORK, 'cert.pem')
    key_path = os.path.join(WORK, 'cert.key')
    with open(cert_path, 'wb') as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    with open(key_path, 'wb') as f:
        f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
                                  serialization.NoEncryption()))
    combined = os.path.join(WORK, 'combined.pem')
    with open(combined, 'wb') as f:
        f.write(open(key_path, 'rb').read() + open(cert_path, 'rb').read())
    return cert_path, key_path, combined


def start_ftp(ports):
    from pyftpdlib.authorizers import DummyAuthorizer
    from pyftpdlib.handlers import FTPHandler
    from pyftpdlib.servers import FTPServer

    auth = DummyAuthorizer()
    auth.add_user(USER, PASSWORD, root('ftp'), perm='elradfmwMT')

    class Handler(FTPHandler):
        pass
    Handler.authorizer = auth
    port = free_port()
    srv = FTPServer(('127.0.0.1', port), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    ports['ftp'] = port


def start_webdav(ports, cert_path, key_path):
    from cheroot import wsgi
    from cheroot.ssl.builtin import BuiltinSSLAdapter
    from wsgidav.wsgidav_app import WsgiDAVApp

    def server(name, digest, tls):
        config = {
            'host': '127.0.0.1',
            'provider_mapping': {'/dav': root(name)},
            'simple_dc': {'user_mapping': {'*': {USER: {'password': PASSWORD}}}},
            'http_authenticator': {
                'domain_controller': None,
                'accept_basic': not digest,
                'accept_digest': digest,
                'default_to_digest': digest,
            },
            'verbose': 0,
            'logging': {'enable': False},
            'lock_storage': True,
        }
        app = WsgiDAVApp(config)
        port = free_port()
        srv = wsgi.Server(('127.0.0.1', port), app)
        if tls:
            srv.ssl_adapter = BuiltinSSLAdapter(cert_path, key_path)
        threading.Thread(target=srv.safe_start, daemon=True).start()
        return port

    ports['webdavBasic'] = server('webdav', False, False)
    ports['webdavDigest'] = server('webdav', True, False)
    ports['webdavHttps'] = server('webdav', False, True)


def start_sftp(ports):
    import asyncio
    import asyncssh

    host_key = asyncssh.generate_private_key('ssh-ed25519')
    client_key = asyncssh.generate_private_key('ssh-rsa', key_size=2048)
    client_key.write_private_key(os.path.join(WORK, 'key.pem'), format_name='openssh', passphrase='keypass')
    client_key.write_private_key(os.path.join(WORK, 'key_plain.pem'), format_name='openssh')
    authorized = asyncssh.import_authorized_keys(client_key.export_public_key().decode())
    sftp_root = root('sftp')
    port = free_port()

    class Server(asyncssh.SSHServer):
        def begin_auth(self, username):
            return True

        def password_auth_supported(self):
            return True

        def validate_password(self, username, password):
            return username == USER and password == PASSWORD

        def public_key_auth_supported(self):
            return True

        def validate_public_key(self, username, key):
            return username == USER and authorized.validate(key, '127.0.0.1', '127.0.0.1') is not None

    class SFTP(asyncssh.SFTPServer):
        def __init__(self, chan):
            super().__init__(chan, chroot=sftp_root.encode())

    async def run():
        await asyncssh.listen('127.0.0.1', port, server_factory=Server, server_host_keys=[host_key],
                              sftp_factory=SFTP, allow_scp=False)
        await asyncio.Event().wait()

    threading.Thread(target=lambda: asyncio.run(run()), daemon=True).start()
    ports['sftp'] = port


def main():
    os.makedirs(WORK, exist_ok=True)
    cert_path, key_path, _ = make_cert()
    ports = {}
    start_ftp(ports)
    import subprocess
    mini = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mini_ftps.py')
    for key, name, mode in (('ftps', 'ftps', 'explicit'), ('ftpsImplicit', 'ftps_implicit', 'implicit')):
        port = free_port()
        child = subprocess.Popen([sys.executable, '-I', '-X', 'utf8', mini, root(name), cert_path, key_path, str(port), mode])
        ports[key] = port
        print('FTPS server pid', child.pid, flush=True)
    start_webdav(ports, cert_path, key_path)
    start_sftp(ports)
    import time
    time.sleep(1.5)
    info = dict(ports)
    info.update({'user': USER, 'password': PASSWORD, 'work': WORK,
                 'key': os.path.join(WORK, 'key.pem'), 'keyPlain': os.path.join(WORK, 'key_plain.pem'),
                 'keyPassphrase': 'keypass'})
    with open(os.path.join(WORK, 'servers.json'), 'w') as f:
        json.dump(info, f, indent=1)
    print('READY', json.dumps(info), flush=True)
    threading.Event().wait()


if __name__ == '__main__':
    main()
