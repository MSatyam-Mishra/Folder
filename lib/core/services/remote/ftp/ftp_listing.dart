import 'package:folders/core/services/remote/remote_fs.dart';

/// An FTP server's answer: its code and its lines (the last one's text
/// first in [message]).
class FtpReply {
  const FtpReply(this.code, this.lines);

  final int code;
  final List<String> lines;

  bool get isPreliminary => code >= 100 && code < 200;
  bool get isOk => code >= 200 && code < 300;
  bool get isIntermediate => code >= 300 && code < 400;
  bool get isError => code >= 400;

  /// The text after the code, all lines.
  String get message => lines
      .map((l) => l.length > 4 && RegExp(r'^\d{3}[ -]').hasMatch(l) ? l.substring(4) : l.trimLeft())
      .join('\n')
      .trim();

  @override
  String toString() => '$code $message';
}

/// MLSD and MLST facts (`type=file;size=12;modify=20240101120000; name`):
/// the entry in [folder], or null for `.`, `..` and what isn't a file or
/// folder.
RemoteEntry? parseMlsdLine(String line, String folder) {
  final space = line.indexOf(' ');
  if (space < 0) return null;
  final facts = <String, String>{};
  for (final fact in line.substring(0, space).split(';')) {
    final eq = fact.indexOf('=');
    if (eq > 0) facts[fact.substring(0, eq).toLowerCase()] = fact.substring(eq + 1);
  }
  final name = line.substring(space + 1);
  final type = facts['type']?.toLowerCase() ?? '';
  if (name.isEmpty || type == 'cdir' || type == 'pdir' || name == '.' || name == '..') return null;
  final isDirectory = type == 'dir' || type.startsWith('os.unix=slink') && facts['size'] == null;
  if (!isDirectory && type != 'file' && !type.startsWith('os.unix=slink')) return null;
  // MLST gives a whole path; MLSD a name.
  final path = name.startsWith('/') ? RemotePaths.normalize(name) : RemotePaths.join(folder, name);
  return RemoteEntry(
    path: path,
    isDirectory: isDirectory,
    size: isDirectory ? 0 : int.tryParse(facts['size'] ?? '') ?? 0,
    modified: parseFtpTime(facts['modify']),
  );
}

/// `20240101120000` or `20240101120000.123` (UTC), as MDTM and MLSD give.
DateTime? parseFtpTime(String? value) {
  if (value == null) return null;
  final m = RegExp(r'^(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)').firstMatch(value.trim());
  if (m == null) return null;
  int at(int i) => int.parse(m.group(i)!);
  return DateTime.utc(at(1), at(2), at(3), at(4), at(5), at(6)).toLocal();
}

const _months = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

final _unix = RegExp(
  r'^([\-dlbcps])[\-rwxsStTl]{9}[+@.]?\s+\d+\s+(?:\S+\s+){1,2}?(\d+)\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{1,2}:\d{2}|\d{4})\s(.*)$',
);
final _dos = RegExp(r'^(\d{2})-(\d{2})-(\d{2,4})\s+(\d{1,2}):(\d{2})\s*([AaPp][Mm])?\s+(<DIR>|\d+)\s+(.*)$');

/// One line of LIST, Unix (`drwxr-xr-x 2 me me 4096 Jan 5 12:00 name`) or
/// Windows (`01-05-24  12:00PM  <DIR>  name`) style: the entry in [folder],
/// or null for `.`, `..`, totals and what can't be read.
RemoteEntry? parseListLine(String line, String folder, {DateTime? now}) {
  final unix = _unix.firstMatch(line);
  if (unix != null) {
    final kind = unix.group(1)!;
    var name = unix.group(6)!;
    final isLink = kind == 'l';
    if (isLink) {
      final arrow = name.indexOf(' -> ');
      if (arrow >= 0) name = name.substring(0, arrow);
    }
    if (name == '.' || name == '..' || name.isEmpty) return null;
    final isDirectory = kind == 'd';
    if (!isDirectory && kind != '-' && !isLink) return null;
    final month = _months[unix.group(3)!.toLowerCase()];
    final day = int.parse(unix.group(4)!);
    final timeOrYear = unix.group(5)!;
    DateTime? modified;
    if (month != null) {
      if (timeOrYear.contains(':')) {
        // This year, unless that would be in the future: then last year.
        final today = now ?? DateTime.now();
        final parts = timeOrYear.split(':');
        var date = DateTime(today.year, month, day, int.parse(parts[0]), int.parse(parts[1]));
        if (date.isAfter(today.add(const Duration(days: 1)))) {
          date = DateTime(today.year - 1, month, day, date.hour, date.minute);
        }
        modified = date;
      } else {
        modified = DateTime(int.parse(timeOrYear), month, day);
      }
    }
    return RemoteEntry(
      path: RemotePaths.join(folder, name),
      isDirectory: isDirectory,
      size: isDirectory ? 0 : int.tryParse(unix.group(2)!) ?? 0,
      modified: modified,
    );
  }
  final dos = _dos.firstMatch(line);
  if (dos != null) {
    final name = dos.group(8)!;
    if (name == '.' || name == '..') return null;
    var year = int.parse(dos.group(3)!);
    if (year < 100) year += year < 70 ? 2000 : 1900;
    var hour = int.parse(dos.group(4)!);
    final half = dos.group(6)?.toLowerCase();
    if (half == 'pm' && hour < 12) hour += 12;
    if (half == 'am' && hour == 12) hour = 0;
    final isDirectory = dos.group(7) == '<DIR>';
    return RemoteEntry(
      path: RemotePaths.join(folder, name),
      isDirectory: isDirectory,
      size: isDirectory ? 0 : int.tryParse(dos.group(7)!) ?? 0,
      modified: DateTime(year, int.parse(dos.group(1)!), int.parse(dos.group(2)!), hour, int.parse(dos.group(5)!)),
    );
  }
  return null;
}

/// The port of `229 Entering Extended Passive Mode (|||6446|)`.
int? parseEpsv(String message) {
  final m = RegExp(r'\(([^\d\s])\1\1(\d+)\1\)').firstMatch(message);
  return m == null ? null : int.tryParse(m.group(2)!);
}

/// The address and port of `227 Entering Passive Mode (192,168,1,5,19,137)`.
(String, int)? parsePasv(String message) {
  final m = RegExp(r'(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)').firstMatch(message);
  if (m == null) return null;
  final n = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  return ('${n[0]}.${n[1]}.${n[2]}.${n[3]}', n[4] * 256 + n[5]);
}
