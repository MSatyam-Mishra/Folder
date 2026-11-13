import 'dart:io';

import '../remote_fs.dart';
import 'smb_connection.dart';
import 'smb_constants.dart';
import 'smb_rpc.dart';

/// Turns what the SMB client throws into [RemoteException]s with plain words.
RemoteException smbError(Object e, {required String host, int? port, String? share, bool guest = false}) {
  if (e is RemoteException) return e;
  final where = port == null || port == 445 ? host : '$host:$port';
  if (e is SmbStatusException) return _status(e, where: where, share: share ?? e.detail, guest: guest);
  if (e is SmbConnectionException) {
    if (e.refused) {
      return RemoteException(
        RemoteErrorKind.network,
        'Couldn\'t connect to $where. Check the address, and that file sharing is on there.',
      );
    }
    if (e.timedOut) return RemoteException(RemoteErrorKind.network, '$where didn\'t answer in time.');
    return RemoteException(RemoteErrorKind.network, 'The connection to $where broke. (${e.message})');
  }
  if (e is SmbProtocolException) {
    switch (e.kind) {
      case SmbProblem.smb1Only:
        return const RemoteException(
          RemoteErrorKind.unsupported,
          'This server speaks only SMB 1, an old version Folders doesn\'t use because it isn\'t safe. '
          'Turn on SMB 2 or 3 on the server.',
        );
      case SmbProblem.encryptionUnavailable:
        return RemoteException(
          RemoteErrorKind.unsupported,
          'SMB encryption is needed here (by the share, or by this place\'s settings), '
          'but Folders and this server couldn\'t agree on it. (${e.message})',
        );
      case SmbProblem.badSignature:
        return RemoteException(
          RemoteErrorKind.network,
          'A reply from $where failed its security check, so Folders stopped. '
          'Something on the network may be changing the traffic. (${e.message})',
        );
      case SmbProblem.noCommonDialect:
        return RemoteException(RemoteErrorKind.unsupported, 'Folders and $where have no SMB version in common.');
      case SmbProblem.guestBlocked:
        return const RemoteException(RemoteErrorKind.auth, 'This server doesn\'t let guests in. Sign in with a user name and password.');
      case SmbProblem.other:
        return RemoteException(RemoteErrorKind.other, 'Something went wrong talking to $where: ${e.message}');
    }
  }
  if (e is SocketException) {
    return RemoteException(RemoteErrorKind.network, 'Couldn\'t reach $where: ${e.osError?.message ?? e.message}');
  }
  if (e is RpcException) {
    return RemoteException(RemoteErrorKind.other, 'Couldn\'t get the list of shares: ${e.message}');
  }
  if (e is FormatException) {
    return RemoteException(RemoteErrorKind.other, '$where sent something Folders couldn\'t read: ${e.message}');
  }
  return RemoteException(RemoteErrorKind.other, '$e');
}

RemoteException _status(SmbStatusException e, {required String where, String? share, required bool guest}) {
  final s = e.status;
  final cmd = e.command;
  switch (s) {
    case NtStatus.logonFailure:
    case NtStatus.wrongPassword:
      return RemoteException(
        RemoteErrorKind.auth,
        guest ? '$where doesn\'t let guests in. Sign in with a user name and password.' : 'The user name or password was refused.',
      );
    case NtStatus.accountDisabled:
      return const RemoteException(RemoteErrorKind.auth, 'This account is turned off on the server.');
    case NtStatus.accountLockedOut:
      return const RemoteException(RemoteErrorKind.auth, 'This account is locked after too many wrong passwords.');
    case NtStatus.passwordExpired:
    case NtStatus.passwordMustChange:
      return const RemoteException(RemoteErrorKind.auth, 'The password has expired. Change it on the server first.');
    case NtStatus.accountExpired:
      return const RemoteException(RemoteErrorKind.auth, 'This account has expired.');
    case NtStatus.accountRestriction:
      return const RemoteException(
        RemoteErrorKind.auth,
        'This account can\'t sign in over the network. Windows refuses accounts with an empty password there.',
      );
    case NtStatus.invalidLogonHours:
    case NtStatus.invalidWorkstation:
      return const RemoteException(RemoteErrorKind.auth, 'This account isn\'t allowed to sign in now, or from this device.');
    case NtStatus.accessDenied:
    case NtStatus.networkAccessDenied:
    case NtStatus.privilegeNotHeld:
      if (cmd == SmbCommand.sessionSetup) {
        return RemoteException(
          RemoteErrorKind.auth,
          guest ? '$where doesn\'t let guests in. Sign in with a user name and password.' : 'The server refused this sign-in.',
        );
      }
      if (cmd == SmbCommand.treeConnect) {
        return RemoteException(
          RemoteErrorKind.permission,
          guest
              ? 'The share ${share ?? ''} doesn\'t let guests in. Sign in with a user name and password.'
              : 'This account may not open the share ${share ?? ''}.',
        );
      }
      return const RemoteException(RemoteErrorKind.permission, 'Access was refused.');
    case NtStatus.badNetworkName:
      return RemoteException(RemoteErrorKind.notFound, 'There\'s no share called ${share ?? 'that'} on $where.');
    case NtStatus.objectNameNotFound:
    case NtStatus.objectPathNotFound:
    case NtStatus.noSuchFile:
    case NtStatus.notFound:
    case NtStatus.noSuchDevice:
      return const RemoteException(RemoteErrorKind.notFound, 'It isn\'t there any more.');
    case NtStatus.notADirectory:
      return const RemoteException(RemoteErrorKind.notFound, 'That\'s a file, not a folder.');
    case NtStatus.fileIsADirectory:
      return const RemoteException(RemoteErrorKind.other, 'That\'s a folder, not a file.');
    case NtStatus.objectNameCollision:
      return const RemoteException(RemoteErrorKind.alreadyExists, 'Something with that name is already there.');
    case NtStatus.directoryNotEmpty:
      return const RemoteException(RemoteErrorKind.other, 'The folder isn\'t empty.');
    case NtStatus.sharingViolation:
      return const RemoteException(RemoteErrorKind.other, 'Another program on the server is using this file.');
    case NtStatus.deletePending:
      return const RemoteException(RemoteErrorKind.notFound, 'This is being deleted.');
    case NtStatus.cannotDelete:
      return const RemoteException(RemoteErrorKind.permission, 'The server won\'t delete this (it may be read-only or in use).');
    case NtStatus.diskFull:
    case NtStatus.quotaExceeded:
      return const RemoteException(RemoteErrorKind.other, 'There\'s no room left on the share.');
    case NtStatus.mediaWriteProtected:
      return const RemoteException(RemoteErrorKind.permission, 'This share is read-only.');
    case NtStatus.notSameDevice:
      return const RemoteException(RemoteErrorKind.unsupported, 'Moving between shares can\'t be done in one step.');
    case NtStatus.objectNameInvalid:
    case NtStatus.objectPathSyntaxBad:
    case NtStatus.objectPathInvalid:
      return const RemoteException(RemoteErrorKind.other, 'The server doesn\'t allow that name.');
    case NtStatus.pathNotCovered:
      return const RemoteException(RemoteErrorKind.unsupported, 'This is a DFS link to another server, which Folders can\'t follow yet.');
    case NtStatus.notSupported:
    case NtStatus.notImplemented:
    case NtStatus.invalidDeviceRequest:
      return const RemoteException(RemoteErrorKind.unsupported, 'The server can\'t do that.');
    case NtStatus.insufficientResources:
    case NtStatus.tooManyOpenedFiles:
    case NtStatus.requestNotAccepted:
      return const RemoteException(RemoteErrorKind.other, 'The server is too busy right now. Try again in a moment.');
    case NtStatus.networkNameDeleted:
    case NtStatus.userSessionDeleted:
    case NtStatus.networkSessionExpired:
    case NtStatus.ioTimeout:
      return RemoteException(RemoteErrorKind.network, 'The connection to $where was reset. Try again.');
    case NtStatus.cancelled:
      return const RemoteException(RemoteErrorKind.cancelled, 'Cancelled.');
  }
  return RemoteException(RemoteErrorKind.other, 'The server answered with error ${NtStatus.hex(s)}.');
}

/// Errors after which a fresh connection may well succeed.
bool smbShouldReconnect(Object e) {
  if (e is SmbConnectionException) return true;
  if (e is SocketException) return true;
  if (e is SmbStatusException) {
    return e.status == NtStatus.userSessionDeleted ||
        e.status == NtStatus.networkSessionExpired ||
        e.status == NtStatus.networkNameDeleted ||
        e.status == NtStatus.invalidHandle ||
        e.status == NtStatus.fileClosed;
  }
  return false;
}
