import 'package:flutter/foundation.dart';

enum TaskStatus { running, done, failed, cancelled }

/// What a task does, for the icon of its notification.
enum TaskKind { work, copy, download, upload }

/// Work that goes on while the app is used (or hidden): conversions,
/// resizes, copies. Listen to it for progress.
class BackgroundTask extends ChangeNotifier {
  BackgroundTask._(this.id, this.title, this.message, this._onCancel, this.headline, this.kind);

  final int id;
  String title;
  String message;

  /// Over a notification's bar, like "Copy in progress"; [title] without one.
  final String? headline;
  final TaskKind kind;

  /// How far along in its own terms, like "231.6 MB/252.5 MB".
  String detail = '';

  /// 0–1, or null when it can't be measured.
  double? progress;
  TaskStatus status = TaskStatus.running;

  /// Files the task made, to open or show when it's done.
  final outputs = <String>[];
  final started = DateTime.now();
  DateTime? finished;
  final VoidCallback? _onCancel;
  bool _cancelRequested = false;

  bool get isRunning => status == TaskStatus.running;
  bool get canCancel => _onCancel != null && isRunning;
  bool get cancelRequested => _cancelRequested;

  void update({String? message, double? progress, String? title, String? detail}) {
    if (!isRunning) return;
    if (message != null) this.message = message;
    if (title != null) this.title = title;
    if (detail != null) this.detail = detail;
    this.progress = progress ?? this.progress;
    notifyListeners();
  }

  void cancel() {
    if (!canCancel || _cancelRequested) return;
    _cancelRequested = true;
    message = 'Stopping…';
    notifyListeners();
    _onCancel!();
  }

  void _end(TaskStatus status, String message) {
    if (!isRunning) return;
    this.status = status;
    this.message = message;
    if (status == TaskStatus.done) progress = 1;
    finished = DateTime.now();
    notifyListeners();
  }
}

/// The app's [BackgroundTask]s, newest first; shown in the progress dock and
/// the Tasks view (what's left when the window is closed while work runs).
class BackgroundTasks extends ChangeNotifier {
  BackgroundTasks._();

  static final instance = BackgroundTasks._();

  final _tasks = <BackgroundTask>[];
  var _nextId = 0;

  List<BackgroundTask> get all => List.unmodifiable(_tasks);
  List<BackgroundTask> get running => [for (final t in _tasks) if (t.isRunning) t];
  bool get hasRunning => _tasks.any((t) => t.isRunning);

  BackgroundTask start(
    String title, {
    String message = '',
    VoidCallback? onCancel,
    String? headline,
    TaskKind kind = TaskKind.work,
  }) {
    final task = BackgroundTask._(_nextId++, title, message, onCancel, headline, kind)..addListener(notifyListeners);
    _tasks.insert(0, task);
    // Finished tasks are kept for the Tasks view, a few dozen at most.
    while (_tasks.length > 50) {
      final old = _tasks.lastWhere((t) => !t.isRunning, orElse: () => _tasks.last);
      if (old.isRunning) break;
      _tasks.remove(old);
    }
    notifyListeners();
    return task;
  }

  void finish(BackgroundTask task, {String message = 'Done'}) => task._end(TaskStatus.done, message);
  void fail(BackgroundTask task, String error) => task._end(TaskStatus.failed, error);
  void cancelled(BackgroundTask task) => task._end(TaskStatus.cancelled, 'Cancelled');

  void clearFinished() {
    _tasks.removeWhere((t) => !t.isRunning);
    notifyListeners();
  }

  @visibleForTesting
  void reset() {
    _tasks.clear();
    notifyListeners();
  }
}
