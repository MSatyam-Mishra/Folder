import 'dart:io';

import 'package:folder/core/services/folder_prefs_service.dart';
import 'package:folder/features/file_explorere/widgets/entity_meta.dart';
import 'package:path/path.dart' as p;

/// How [groupBy] is named in menus.
String groupByLabel(GroupBy groupBy) => switch (groupBy) {
      GroupBy.none => 'None',
      GroupBy.name => 'Name',
      GroupBy.date => 'Date modified',
      GroupBy.type => 'Type',
      GroupBy.size => 'Size',
    };

/// Items under one heading of a grouped folder.
class EntityGroup {
  const EntityGroup(this.label, this.entities);

  final String label;
  final List<FileSystemEntity> entities;
}

/// [entities], kept in their sorted order, under headings like File
/// Explorer's: first letters, dates ("Today", "Last week"…), kinds, or size
/// ranges. [stat] gives modified times and sizes; [nameOf] display names.
/// macOS packages group by kind among the files ("Application"), and by
/// size under "Size not known", as their size isn't added up.
Future<List<EntityGroup>> groupEntities(
  List<FileSystemEntity> entities,
  GroupBy by, {
  required Future<FileStat?> Function(FileSystemEntity entity) stat,
  String Function(FileSystemEntity entity)? nameOf,
  DateTime? now,
}) async {
  if (by == GroupBy.none || entities.isEmpty) return const [];
  final needsStat = by == GroupBy.date || by == GroupBy.size;
  final stats = needsStat ? await Future.wait(entities.map(stat)) : null;
  final groups = <String, List<FileSystemEntity>>{};
  final ranks = <String, int>{};
  for (var i = 0; i < entities.length; i++) {
    final entity = entities[i];
    final (label, rank) = switch (by) {
      GroupBy.name => _byName(nameOf?.call(entity) ?? p.basename(entity.path)),
      GroupBy.date => _byDate(stats![i]?.modified, now ?? DateTime.now()),
      GroupBy.type => entity is Directory && !EntityFormat.isPackage(entity)
          ? ('Folder', -1)
          : (EntityFormat.kind(entity), 0),
      GroupBy.size => EntityFormat.isPackage(entity)
          ? ('Size not known', 1)
          : _bySize(entity is Directory ? null : stats![i]?.size),
      GroupBy.none => ('', 0),
    };
    (groups[label] ??= []).add(entity);
    ranks[label] = rank;
  }
  final labels = groups.keys.toList()
    ..sort((a, b) {
      final byRank = ranks[a]!.compareTo(ranks[b]!);
      return byRank != 0 ? byRank : a.toLowerCase().compareTo(b.toLowerCase());
    });
  return [for (final label in labels) EntityGroup(label, groups[label]!)];
}

(String, int) _byName(String name) {
  if (name.isEmpty) return ('#', 2);
  final first = String.fromCharCode(name.runes.first).toUpperCase();
  if (RegExp(r'^[0-9]$').hasMatch(first)) return ('0–9', 0);
  if (RegExp(r'^\p{L}$', unicode: true).hasMatch(first)) return (first, 1);
  return ('#', 2);
}

(String, int) _byDate(DateTime? modified, DateTime now) {
  if (modified == null) return ('A long time ago', 7);
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(modified.year, modified.month, modified.day);
  if (!day.isBefore(today)) return ('Today', 0);
  if (day == today.subtract(const Duration(days: 1))) return ('Yesterday', 1);
  final week = today.subtract(Duration(days: today.weekday - 1)); // Monday
  if (!day.isBefore(week)) return ('Earlier this week', 2);
  if (!day.isBefore(week.subtract(const Duration(days: 7)))) return ('Last week', 3);
  final month = DateTime(now.year, now.month);
  if (!day.isBefore(month)) return ('Earlier this month', 4);
  if (!day.isBefore(DateTime(now.year, now.month - 1))) return ('Last month', 5);
  if (!day.isBefore(DateTime(now.year))) return ('Earlier this year', 6);
  return ('A long time ago', 7);
}

/// File Explorer's size ranges; folders on their own (rank 1 is macOS
/// packages, whose size isn't known either).
(String, int) _bySize(int? bytes) {
  const kb = 1024, mb = 1024 * kb, gb = 1024 * mb;
  return switch (bytes) {
    null => ('Folders', 0),
    0 => ('Empty', 2),
    < 16 * kb => ('Tiny (under 16 KB)', 3),
    < mb => ('Small (16 KB – 1 MB)', 4),
    < 128 * mb => ('Medium (1 – 128 MB)', 5),
    < gb => ('Large (128 MB – 1 GB)', 6),
    < 4 * gb => ('Huge (1 – 4 GB)', 7),
    _ => ('Gigantic (over 4 GB)', 8),
  };
}
