import 'package:folders/core/services/remote/cloud/dropbox_fs.dart';
import 'package:folders/core/services/remote/cloud/google_drive_fs.dart';
import 'package:folders/core/services/remote/cloud/onedrive_fs.dart';
import 'package:folders/core/services/remote/ftp/ftp_fs.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:folders/core/services/remote/sftp/sftp_fs.dart';
import 'package:folders/core/services/remote/shizuku/shizuku_setup.dart';
import 'package:folders/core/services/remote/smb/smb_remote.dart';
import 'package:folders/core/services/remote/webdav/webdav_fs.dart';

/// Registers every remote protocol this build has with [RemoteProtocols].
/// Called once at startup, before anything lists saved places. Each
/// protocol's file adds one line here.
void registerRemoteProtocols() {
  if (RemoteProtocols.all.isNotEmpty) return;
  RemoteProtocols.register(smbProtocolInfo);
  RemoteProtocols.register(sftpProtocol);
  RemoteProtocols.register(ftpProtocol);
  RemoteProtocols.register(ftpsProtocol);
  RemoteProtocols.register(webdavProtocol);
  RemoteProtocols.register(GoogleDriveFileSystem.info);
  RemoteProtocols.register(OneDriveFileSystem.info);
  RemoteProtocols.register(DropboxFileSystem.info);
  registerShizuku();
}
