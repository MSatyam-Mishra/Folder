// Numbers from MS-SMB2, MS-FSCC and MS-ERREF.

abstract final class SmbCommand {
  static const negotiate = 0x00;
  static const sessionSetup = 0x01;
  static const logoff = 0x02;
  static const treeConnect = 0x03;
  static const treeDisconnect = 0x04;
  static const create = 0x05;
  static const close = 0x06;
  static const flush = 0x07;
  static const read = 0x08;
  static const write = 0x09;
  static const lock = 0x0a;
  static const ioctl = 0x0b;
  static const cancel = 0x0c;
  static const echo = 0x0d;
  static const queryDirectory = 0x0e;
  static const changeNotify = 0x0f;
  static const queryInfo = 0x10;
  static const setInfo = 0x11;
  static const oplockBreak = 0x12;
}

abstract final class SmbDialect {
  static const smb202 = 0x0202;
  static const smb210 = 0x0210;
  static const smb300 = 0x0300;
  static const smb302 = 0x0302;
  static const smb311 = 0x0311;
  static const all = [smb202, smb210, smb300, smb302, smb311];

  static String name(int d) => switch (d) {
        smb202 => '2.0.2',
        smb210 => '2.1',
        smb300 => '3.0',
        smb302 => '3.0.2',
        smb311 => '3.1.1',
        _ => '0x${d.toRadixString(16)}',
      };
}

abstract final class SmbFlags {
  static const serverToRedir = 0x00000001;
  static const asyncCommand = 0x00000002;
  static const relatedOperations = 0x00000004;
  static const signed = 0x00000008;
  static const dfsOperations = 0x10000000;
  static const replayOperation = 0x20000000;
}

abstract final class SmbCaps {
  static const dfs = 0x01;
  static const leasing = 0x02;
  static const largeMtu = 0x04;
  static const multiChannel = 0x08;
  static const persistentHandles = 0x10;
  static const directoryLeasing = 0x20;
  static const encryption = 0x40;
}

abstract final class SmbSecurityMode {
  static const signingEnabled = 0x01;
  static const signingRequired = 0x02;
}

abstract final class SmbSessionFlags {
  static const isGuest = 0x0001;
  static const isNull = 0x0002;
  static const encryptData = 0x0004;
}

abstract final class SmbShareFlags {
  static const dfs = 0x00000001;
  static const dfsRoot = 0x00000002;
  static const encryptData = 0x00008000;
}

abstract final class SmbCipher {
  static const aes128Ccm = 0x0001;
  static const aes128Gcm = 0x0002;
  static const aes256Ccm = 0x0003;
  static const aes256Gcm = 0x0004;

  static bool isGcm(int c) => c == aes128Gcm || c == aes256Gcm;
  static int keyBits(int c) => c == aes256Ccm || c == aes256Gcm ? 256 : 128;
}

abstract final class SmbSigningAlgorithm {
  static const hmacSha256 = 0x0000;
  static const aesCmac = 0x0001;
  static const aesGmac = 0x0002;
}

abstract final class FileAccess {
  static const readData = 0x00000001;
  static const writeData = 0x00000002;
  static const appendData = 0x00000004;
  static const readEa = 0x00000008;
  static const writeEa = 0x00000010;
  static const execute = 0x00000020;
  static const deleteChild = 0x00000040;
  static const readAttributes = 0x00000080;
  static const writeAttributes = 0x00000100;
  static const delete = 0x00010000;
  static const readControl = 0x00020000;
  static const synchronize = 0x00100000;
  static const maximumAllowed = 0x02000000;
  static const genericRead = 0x80000000;
  static const genericWrite = 0x40000000;
}

abstract final class FileAttr {
  static const readonly = 0x00000001;
  static const hidden = 0x00000002;
  static const system = 0x00000004;
  static const directory = 0x00000010;
  static const archive = 0x00000020;
  static const normal = 0x00000080;
  static const reparsePoint = 0x00000400;
}

abstract final class ShareAccess {
  static const read = 0x1;
  static const write = 0x2;
  static const delete = 0x4;
  static const all = 0x7;
}

abstract final class CreateDisposition {
  static const supersede = 0;
  static const open = 1;
  static const create = 2;
  static const openIf = 3;
  static const overwrite = 4;
  static const overwriteIf = 5;
}

abstract final class CreateOptions {
  static const directoryFile = 0x00000001;
  static const writeThrough = 0x00000002;
  static const sequentialOnly = 0x00000004;
  static const nonDirectoryFile = 0x00000040;
  static const deleteOnClose = 0x00001000;
  static const openReparsePoint = 0x00200000;
}

/// CREATE's CreateAction.
abstract final class CreateAction {
  static const superseded = 0;
  static const opened = 1;
  static const created = 2;
  static const overwritten = 3;
}

abstract final class InfoType {
  static const file = 1;
  static const fileSystem = 2;
  static const security = 3;
}

abstract final class FileInfoClass {
  static const directory = 1;
  static const fullDirectory = 2;
  static const bothDirectory = 3;
  static const basic = 4;
  static const standard = 5;
  static const rename = 10;
  static const disposition = 13;
  static const allocation = 19;
  static const endOfFile = 20;
  static const idBothDirectory = 37;
  static const fsFullSize = 7;
}

abstract final class Fsctl {
  static const pipeTransceive = 0x0011c017;
  static const validateNegotiateInfo = 0x00140204;
}

abstract final class NtStatus {
  static const success = 0x00000000;
  static const pending = 0x00000103;
  static const bufferOverflow = 0x80000005;
  static const noMoreFiles = 0x80000006;
  static const stoppedOnSymlink = 0x8000002d;
  static const unsuccessful = 0xc0000001;
  static const notImplemented = 0xc0000002;
  static const invalidInfoClass = 0xc0000003;
  static const infoLengthMismatch = 0xc0000004;
  static const invalidHandle = 0xc0000008;
  static const invalidParameter = 0xc000000d;
  static const noSuchDevice = 0xc000000e;
  static const noSuchFile = 0xc000000f;
  static const invalidDeviceRequest = 0xc0000010;
  static const endOfFile = 0xc0000011;
  static const moreProcessingRequired = 0xc0000016;
  static const accessDenied = 0xc0000022;
  static const bufferTooSmall = 0xc0000023;
  static const objectTypeMismatch = 0xc0000024;
  static const objectNameInvalid = 0xc0000033;
  static const objectNameNotFound = 0xc0000034;
  static const objectNameCollision = 0xc0000035;
  static const objectPathInvalid = 0xc0000039;
  static const objectPathNotFound = 0xc000003a;
  static const objectPathSyntaxBad = 0xc000003b;
  static const sharingViolation = 0xc0000043;
  static const quotaExceeded = 0xc0000044;
  static const deletePending = 0xc0000056;
  static const privilegeNotHeld = 0xc0000061;
  static const wrongPassword = 0xc000006a;
  static const logonFailure = 0xc000006d;
  static const accountRestriction = 0xc000006e;
  static const invalidLogonHours = 0xc000006f;
  static const invalidWorkstation = 0xc0000070;
  static const passwordExpired = 0xc0000071;
  static const accountDisabled = 0xc0000072;
  static const diskFull = 0xc000007f;
  static const insufficientResources = 0xc000009a;
  static const mediaWriteProtected = 0xc00000a2;
  static const pipeNotAvailable = 0xc00000ac;
  static const ioTimeout = 0xc00000b5;
  static const fileIsADirectory = 0xc00000ba;
  static const notSupported = 0xc00000bb;
  static const networkNameDeleted = 0xc00000c9;
  static const networkAccessDenied = 0xc00000ca;
  static const badNetworkName = 0xc00000cc;
  static const requestNotAccepted = 0xc00000d0;
  static const notSameDevice = 0xc00000d4;
  static const fileRenamed = 0xc00000d5;
  static const directoryNotEmpty = 0xc0000101;
  static const notADirectory = 0xc0000103;
  static const tooManyOpenedFiles = 0xc000011f;
  static const cancelled = 0xc0000120;
  static const cannotDelete = 0xc0000121;
  static const fileClosed = 0xc0000128;
  static const pipeBroken = 0xc000014b;
  static const invalidDeviceState = 0xc0000184;
  static const accountExpired = 0xc0000193;
  static const userSessionDeleted = 0xc0000203;
  static const passwordMustChange = 0xc0000224;
  static const notFound = 0xc0000225;
  static const accountLockedOut = 0xc0000234;
  static const connectionRefused = 0xc0000236;
  static const hostUnreachable = 0xc000023d;
  static const pathNotCovered = 0xc0000257;
  static const networkSessionExpired = 0xc000035c;

  static String hex(int s) => '0x${s.toRadixString(16).padLeft(8, '0')}';
}
