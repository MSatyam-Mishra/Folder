import 'package:folders/core/services/remote/remote_fs.dart';

/// Registers every remote protocol this build has with [RemoteProtocols].
/// Called once at startup, before anything lists saved places. Each
/// protocol's file adds one line here.
void registerRemoteProtocols() {
  if (RemoteProtocols.all.isNotEmpty) return;
}
