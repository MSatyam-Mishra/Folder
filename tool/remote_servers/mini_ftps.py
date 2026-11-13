"""A small threaded FTPS server on Python's own ssl module, for the FTPS
tests (pyftpdlib's TLS, through pyOpenSSL, is unreliable on Python 3.14).

  python -I -X utf8 mini_ftps.py <root> <cert.pem> <cert.key> <port> [implicit]

Explicit (AUTH TLS) or implicit TLS, PROT P, PASV/EPSV, MLSD/MLST/LIST,
RETR with REST, STOR, MKD, RMD, DELE, RNFR/RNTO, ABOR. User "tester",
password "secret123".
"""
import datetime
import os
import socket
import socketserver
import ssl
import sys
import threading

ROOT = os.path.abspath(sys.argv[1])
CTX = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
CTX.load_cert_chain(sys.argv[2], sys.argv[3])
PORT = int(sys.argv[4])
IMPLICIT = len(sys.argv) > 5 and sys.argv[5] == 'implicit'


def fs_path(cwd, arg):
    path = arg if arg.startswith('/') else cwd.rstrip('/') + '/' + arg
    parts = []
    for p in path.split('/'):
        if p in ('', '.'):
            continue
        if p == '..':
            if parts:
                parts.pop()
            continue
        parts.append(p)
    return '/' + '/'.join(parts), os.path.join(ROOT, *parts)


def facts(name, full):
    st = os.stat(full)
    kind = 'dir' if os.path.isdir(full) else 'file'
    modify = datetime.datetime.fromtimestamp(st.st_mtime, datetime.timezone.utc).strftime('%Y%m%d%H%M%S')
    size = '' if kind == 'dir' else 'size=%d;' % st.st_size
    return 'type=%s;%smodify=%s; %s' % (kind, size, modify, name)


class Handler(socketserver.StreamRequestHandler):
    def setup(self):
        if IMPLICIT:
            self.request = CTX.wrap_socket(self.request, server_side=True)
        super().setup()
        self.cwd = '/'
        self.user = None
        self.logged = False
        self.protect = False
        self.passive = None
        self.rest = 0
        self.rename_from = None

    def reply(self, text):
        self.wfile.write((text + '\r\n').encode('utf-8'))
        self.wfile.flush()

    def data_socket(self):
        listener = self.passive
        self.passive = None
        listener.settimeout(10)
        conn, _ = listener.accept()
        listener.close()
        return conn

    def secure_data(self, conn):
        return CTX.wrap_socket(conn, server_side=True) if self.protect else conn

    def handle(self):
        self.reply('220 mini FTPS ready')
        while True:
            line = self.rfile.readline()
            if not line:
                return
            line = line.decode('utf-8', 'replace').rstrip('\r\n')
            cmd, _, arg = line.partition(' ')
            cmd = cmd.upper()
            try:
                if not self.command(cmd, arg):
                    return
            except (ConnectionError, ssl.SSLError, OSError) as e:
                try:
                    self.reply('451 %s' % e)
                except Exception:
                    return

    def command(self, cmd, arg):
        if cmd == 'AUTH' and not IMPLICIT:
            self.reply('234 AUTH TLS ok')
            self.request = CTX.wrap_socket(self.request, server_side=True)
            self.rfile = self.request.makefile('rb')
            self.wfile = self.request.makefile('wb')
            return True
        if cmd == 'USER':
            self.user = arg
            self.reply('331 password please')
            return True
        if cmd == 'PASS':
            if self.user == 'tester' and arg == 'secret123':
                self.logged = True
                self.reply('230 welcome')
            else:
                self.reply('530 wrong')
            return True
        if cmd == 'QUIT':
            self.reply('221 bye')
            return False
        if not self.logged:
            self.reply('530 sign in first')
            return True
        if cmd == 'PBSZ':
            self.reply('200 PBSZ=0')
        elif cmd == 'PROT':
            self.protect = arg.upper() == 'P'
            self.reply('200 PROT ok')
        elif cmd == 'FEAT':
            self.reply('211-Features:\r\n MLST type*;size*;modify*;\r\n UTF8\r\n EPSV\r\n REST STREAM\r\n211 End')
        elif cmd in ('OPTS', 'TYPE', 'NOOP'):
            self.reply('200 ok')
        elif cmd in ('PASV', 'EPSV'):
            listener = socket.socket()
            listener.bind(('127.0.0.1', 0))
            listener.listen(1)
            self.passive = listener
            port = listener.getsockname()[1]
            if cmd == 'EPSV':
                self.reply('229 Entering Extended Passive Mode (|||%d|)' % port)
            else:
                self.reply('227 Entering Passive Mode (127,0,0,1,%d,%d)' % (port >> 8, port & 255))
        elif cmd == 'CWD':
            virtual, full = fs_path(self.cwd, arg)
            if os.path.isdir(full):
                self.cwd = virtual
                self.reply('250 ok')
            else:
                self.reply('550 no such folder')
        elif cmd == 'MLST':
            virtual, full = fs_path(self.cwd, arg)
            if not os.path.exists(full):
                self.reply('550 not found')
            else:
                self.reply('250-Listing\r\n %s\r\n250 End' % facts(virtual, full))
        elif cmd in ('MLSD', 'LIST'):
            virtual, full = fs_path(self.cwd, arg)
            if not os.path.isdir(full):
                self.reply('550 no such folder')
                return True
            self.reply('150 listing')
            conn = self.secure_data(self.data_socket())
            lines = []
            for name in sorted(os.listdir(full)):
                child = os.path.join(full, name)
                if cmd == 'MLSD':
                    lines.append(facts(name, child))
                else:
                    st = os.stat(child)
                    kind = 'd' if os.path.isdir(child) else '-'
                    when = datetime.datetime.fromtimestamp(st.st_mtime).strftime('%b %d %H:%M')
                    lines.append('%srw-r--r-- 1 owner group %d %s %s' % (kind, st.st_size, when, name))
            conn.sendall(('\r\n'.join(lines) + ('\r\n' if lines else '')).encode('utf-8'))
            self.close_data(conn)
            self.reply('226 done')
        elif cmd == 'REST':
            self.rest = int(arg)
            self.reply('350 restarting at %d' % self.rest)
        elif cmd == 'RETR':
            virtual, full = fs_path(self.cwd, arg)
            if not os.path.isfile(full):
                self.reply('550 not found')
                return True
            start, self.rest = self.rest, 0
            self.reply('150 sending')
            conn = self.secure_data(self.data_socket())
            try:
                with open(full, 'rb') as f:
                    f.seek(start)
                    while True:
                        chunk = f.read(65536)
                        if not chunk:
                            break
                        conn.sendall(chunk)
                self.close_data(conn)
                self.reply('226 sent')
            except (ConnectionError, ssl.SSLError, OSError):
                self.reply('426 transfer aborted')
        elif cmd == 'STOR':
            virtual, full = fs_path(self.cwd, arg)
            self.reply('150 receiving')
            conn = self.secure_data(self.data_socket())
            with open(full, 'wb') as f:
                while True:
                    try:
                        chunk = conn.recv(65536)
                    except ssl.SSLError:
                        break
                    if not chunk:
                        break
                    f.write(chunk)
            self.close_data(conn)
            self.reply('226 stored')
        elif cmd == 'ABOR':
            self.reply('226 abort ok')
        elif cmd == 'MKD':
            virtual, full = fs_path(self.cwd, arg)
            if os.path.exists(full):
                self.reply('550 File exists')
            else:
                os.mkdir(full)
                self.reply('257 "%s" created' % virtual)
        elif cmd == 'RMD':
            _, full = fs_path(self.cwd, arg)
            os.rmdir(full)
            self.reply('250 removed')
        elif cmd == 'DELE':
            _, full = fs_path(self.cwd, arg)
            if not os.path.isfile(full):
                self.reply('550 not found')
            else:
                os.remove(full)
                self.reply('250 deleted')
        elif cmd == 'RNFR':
            _, full = fs_path(self.cwd, arg)
            if os.path.exists(full):
                self.rename_from = full
                self.reply('350 ready')
            else:
                self.reply('550 not found')
        elif cmd == 'RNTO':
            _, full = fs_path(self.cwd, arg)
            os.rename(self.rename_from, full)
            self.reply('250 renamed')
        else:
            self.reply('502 not here')
        return True

    def close_data(self, conn):
        # As most servers do: close_notify, then the connection is closed
        # without waiting long for the client's.
        try:
            if isinstance(conn, ssl.SSLSocket):
                conn.settimeout(0.3)
                conn = conn.unwrap()
        except (ssl.SSLError, OSError):
            pass
        try:
            conn.close()
        except OSError:
            pass


class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


os.makedirs(ROOT, exist_ok=True)
server = Server(('127.0.0.1', PORT), Handler)
print('mini FTPS on', PORT, 'implicit' if IMPLICIT else 'explicit', 'pid', os.getpid(), flush=True)
server.serve_forever()
