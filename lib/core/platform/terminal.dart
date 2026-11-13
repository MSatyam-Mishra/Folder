import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:folders/core/platform/desktop.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/remote/remote_fs.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart'
    show CloseHandle, CREATE_NEW_CONSOLE, CreateProcess, GetLastError, PROCESS_INFORMATION, STARTUPINFO;

/// A terminal program, and how it starts in a folder.
@immutable
class TerminalCommand {
  const TerminalCommand(this.executable, this.arguments, {required this.workingDirectory, this.newConsole = false});

  final String executable;
  final List<String> arguments;
  final String workingDirectory;

  /// Windows: a console program, which needs a console window of its own.
  final bool newConsole;

  @override
  String toString() => '$executable ${arguments.join(' ')} (in $workingDirectory)';
}

/// Open in Terminal, on computers: Windows Terminal or else PowerShell on
/// Windows, the user's terminal on Linux, Terminal on a Mac.
abstract final class Terminal {
  static bool get supported => Desktop.isDesktop;

  /// Whether a terminal can open in [path]: a folder on this computer, not
  /// a virtual or remote one.
  static bool canOpen(String path) =>
      supported && !ExplorerPaths.isVirtual(path) && !RemotePaths.isRemote(path) && ExplorerPaths.isOnDisk(path);

  /// Starts [command]; tests replace it.
  @visibleForTesting
  static Future<void> Function(TerminalCommand command) launcher = _launch;

  /// Linux terminals in the order they're tried after `$TERMINAL`, each with
  /// how it's told the folder (all also start in it).
  static const linuxTerminals = <(String, List<String> Function(String))>[
    ('x-terminal-emulator', _none),
    ('gnome-terminal', _workingDirectoryEquals),
    ('konsole', _workdir),
    ('xfce4-terminal', _workingDirectoryEquals),
    ('kitty', _directory),
    ('alacritty', _workingDirectory),
    ('foot', _workingDirectoryEquals),
    ('wezterm', _wezterm),
    ('tilix', _workingDirectoryEquals),
    ('terminator', _workingDirectoryEquals),
    ('xterm', _none),
  ];

  static List<String> _none(String _) => const [];
  static List<String> _workingDirectoryEquals(String folder) => ['--working-directory=$folder'];
  static List<String> _workingDirectory(String folder) => ['--working-directory', folder];
  static List<String> _workdir(String folder) => ['--workdir', folder];
  static List<String> _directory(String folder) => ['--directory', folder];
  static List<String> _wezterm(String folder) => ['start', '--cwd', folder];

  /// How to open a terminal in [folder] here; null when there's none.
  /// [system], [environment] and [find] (a program's path, or null) stand
  /// in for this computer in tests.
  static TerminalCommand? commandFor(
    String folder, {
    String? system,
    Map<String, String>? environment,
    String? Function(String program)? find,
  }) {
    final os = system ?? Platform.operatingSystem;
    final env = environment ?? Platform.environment;
    final which = find ?? ((program) => _which(program, env, os));
    switch (os) {
      case 'windows':
        final wt = which('wt.exe');
        // "-d ." with the folder as its working folder: a path ending in a
        // backslash (C:\) would escape the closing quote.
        if (wt != null) return TerminalCommand(wt, const ['-d', '.'], workingDirectory: folder);
        return TerminalCommand('powershell.exe', const ['-NoExit'], workingDirectory: folder, newConsole: true);
      case 'macos':
        return TerminalCommand('/usr/bin/open', ['-a', 'Terminal', folder], workingDirectory: folder);
      case 'linux':
        final chosen = env['TERMINAL']?.trim();
        if (chosen != null && chosen.isNotEmpty) {
          final parts = chosen.split(RegExp(r'\s+'));
          final path = which(parts.first);
          if (path != null) {
            final known = [for (final t in linuxTerminals) if (t.$1 == p.basename(parts.first)) t.$2].firstOrNull;
            return TerminalCommand(path, [...parts.skip(1), ...?known?.call(folder)], workingDirectory: folder);
          }
        }
        for (final (name, args) in linuxTerminals) {
          final path = which(name);
          if (path != null) return TerminalCommand(path, args(folder), workingDirectory: folder);
        }
        return null;
    }
    return null;
  }

  /// Where [program] is on the PATH (and, on Windows, among the app aliases
  /// in WindowsApps, where Windows Terminal is).
  static String? _which(String program, Map<String, String> env, String os) {
    if (p.isAbsolute(program)) return _isThere(program) ? program : null;
    final windows = os == 'windows';
    final dirs = (env[windows ? 'Path' : 'PATH'] ?? env['PATH'] ?? '').split(windows ? ';' : ':');
    if (windows) {
      final local = env['LOCALAPPDATA'];
      if (local != null) dirs.add(p.join(local, 'Microsoft', 'WindowsApps'));
    }
    for (final dir in dirs) {
      if (dir.trim().isEmpty) continue;
      final path = p.join(dir.trim(), program);
      if (_isThere(path)) return path;
    }
    return null;
  }

  // App aliases are links that don't resolve outside a package's start.
  static bool _isThere(String path) => FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;

  /// Opens a terminal in [folder]; false if none could be started.
  static Future<bool> open(String folder) async {
    final command = commandFor(folder);
    if (command == null) return false;
    try {
      await launcher(command);
      return true;
    } catch (_) {
      // Windows Terminal there but refusing: PowerShell then.
      if (Platform.isWindows && !command.newConsole) {
        try {
          await launcher(TerminalCommand('powershell.exe', const ['-NoExit'], workingDirectory: folder, newConsole: true));
          return true;
        } catch (_) {}
      }
      return false;
    }
  }

  /// [open], saying so if it couldn't.
  static Future<void> openFrom(BuildContext context, String folder) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (await open(folder)) return;
    messenger?.showSnackBar(SnackBar(
      content: Text(Platform.isLinux
          ? "Couldn't find a terminal. Set TERMINAL to the one you use."
          : "Couldn't open a terminal"),
    ));
  }

  static Future<void> _launch(TerminalCommand command) async {
    if (Platform.isWindows && command.newConsole) return _startInNewConsole(command);
    await Process.start(
      command.executable,
      command.arguments,
      workingDirectory: command.workingDirectory,
      mode: ProcessStartMode.detached,
    );
  }

  /// A console program in a window of its own: Dart's detached processes
  /// have no console, so PowerShell would run unseen.
  static void _startInNewConsole(TerminalCommand command) {
    String quote(String s) => s.contains(' ') ? '"$s"' : s;
    final line = [command.executable, ...command.arguments].map(quote).join(' ').toNativeUtf16();
    final dir = command.workingDirectory.toNativeUtf16();
    final startup = calloc<STARTUPINFO>()..ref.cb = sizeOf<STARTUPINFO>();
    final info = calloc<PROCESS_INFORMATION>();
    try {
      final ok = CreateProcess(nullptr, line, nullptr, nullptr, 0, CREATE_NEW_CONSOLE, nullptr, dir, startup, info);
      if (ok == 0) {
        throw ProcessException(command.executable, command.arguments, "Couldn't start it", GetLastError());
      }
      CloseHandle(info.ref.hProcess);
      CloseHandle(info.ref.hThread);
    } finally {
      calloc.free(line);
      calloc.free(dir);
      calloc.free(startup);
      calloc.free(info);
    }
  }
}
