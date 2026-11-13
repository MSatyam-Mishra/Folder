import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/features/file_explorere/bloc/file_explorer_bloc.dart';
import 'package:folders/features/network/screens/file_server_screen.dart';
import 'package:flutter/material.dart';

/// Opens Wi-Fi sharing on [navigator], as the drawer and the Toolbox do: at
/// the folder [explorer] shows, or the user's own folder when it shows none
/// (or a virtual one, like This PC). Once it closes, the folder shows what
/// other devices uploaded.
Future<void> openWifiSharing(NavigatorState navigator, {FileExplorerBloc? explorer}) async {
  final current = explorer?.state;
  final folder = current is FileExplorerLoaded && ExplorerPaths.isLocal(current.path)
      ? current.path
      : ExplorerPaths.userFolder;
  await navigator.push(
    MaterialPageRoute<void>(builder: (_) => FileServerScreen(initialFolder: folder)),
  );
  if (explorer == null || explorer.isClosed) return;
  final now = explorer.state;
  if (now is FileExplorerLoaded) explorer.add(LoadDirectory(now.path));
}
