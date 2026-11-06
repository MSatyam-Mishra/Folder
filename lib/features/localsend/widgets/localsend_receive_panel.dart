import 'dart:io';

import 'package:folders/core/router/file_opener.dart';
import 'package:folders/core/platform/explorer_paths.dart';
import 'package:folders/core/services/localsend/localsend.dart';
import 'package:folders/features/localsend/localsend_controller.dart';
import 'package:folders/features/localsend/widgets/localsend_common.dart';
import 'package:folders/features/viewer_kit/viewer_kit.dart';
import 'package:flutter/material.dart';

/// This device's identity, the running incoming transfer and received files.
class LsReceivePanel extends StatelessWidget {
  const LsReceivePanel({
    super.key,
    required this.controller,
    required this.padding,
  });

  final LocalSendController controller;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final history = controller.receiveHistory;
    final current =
        controller.receiveSession ??
        (history.isNotEmpty &&
                DateTime.now().difference(
                      history.first.endedAt ?? DateTime.now(),
                    ) <
                    const Duration(minutes: 10)
            ? history.first
            : null);
    return ListView(
      padding: padding,
      children: [
        _ThisDeviceSection(controller: controller),
        if (current != null)
          _ReceiveProgressSection(controller: controller, session: current),
        _ReceivedSection(controller: controller),
      ],
    );
  }
}

class _ThisDeviceSection extends StatelessWidget {
  const _ThisDeviceSection({required this.controller});

  final LocalSendController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final settings = controller.settings;
    if (settings == null) return const SizedBox.shrink();
    final port = controller.serverPort ?? settings.port;
    final addresses = controller.localAddresses;
    final error = controller.serverError;
    final pin = settings.pin;
    final live = error == null;
    return LsSection(
      title: 'Receive',
      icon: LucideIcons.download,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconBox(lsDeviceIcon(settings.deviceType), size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      settings.alias,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: live
                                ? context.toneColor(Tone.success)
                                : colors.destructive,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            live
                                ? 'Visible to nearby devices while this screen is open'
                                : 'Not receiving',
                            style: text.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (error != null)
            ViewerNotice(
              icon: LucideIcons.circleAlert,
              tone: Tone.destructive,
              margin: EdgeInsets.zero,
              message: error,
              actions: [
                TextButton(
                  onPressed: controller.retryServer,
                  child: const Text('Retry'),
                ),
              ],
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final a in addresses.take(3))
                  StatusBadge(
                    '$a:$port',
                    icon: LucideIcons.network,
                    outline: true,
                  ),
                StatusBadge(
                  settings.https ? 'HTTPS' : 'HTTP',
                  icon: settings.https ? LucideIcons.lock : LucideIcons.lockOpen,
                  outline: true,
                ),
                if (pin != null && pin.isNotEmpty)
                  const StatusBadge(
                    'PIN required',
                    icon: LucideIcons.keyRound,
                    outline: true,
                  ),
                if (settings.autoAcceptTrusted)
                  StatusBadge(
                    'Auto-accept ${controller.trusted.length} trusted',
                    icon: LucideIcons.shieldCheck,
                    outline: true,
                  ),
              ],
            ),
          const SizedBox(height: 12),
          ListRow(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            leading: const IconBox(LucideIcons.folderDown),
            title: 'Save to',
            subtitle: settings.destination,
            trailing: ToolButton(
              icon: LucideIcons.externalLink,
              tooltip: 'Open folder',
              onPressed: () async {
                if (!ExplorerPaths.isOnDisk(settings.destination)) return;
                await Directory(settings.destination).create(recursive: true);
                if (context.mounted) {
                  await lsShowInFolder(context, settings.destination);
                }
              },
            ),
          ),
          if (controller.destinationFallback)
            const ViewerNotice(
              icon: LucideIcons.triangleAlert,
              tone: Tone.warning,
              margin: EdgeInsets.only(top: 8),
              message:
                  'The Download folder is not writable (storage permission?), '
                  'so files go to the app folder above. Change it in settings.',
            ),
          if (controller.multicastError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Other devices may not find this one automatically '
                '(${controller.multicastError}); they can add it by IP.',
                style: text.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

class _ReceiveProgressSection extends StatelessWidget {
  const _ReceiveProgressSection({
    required this.controller,
    required this.session,
  });

  final LocalSendController controller;
  final LsReceiveSession session;

  String _stateText() => switch (session.state) {
    LsReceiveState.receiving => 'Receiving…',
    LsReceiveState.finished =>
      session.failedCount == 0
          ? 'Received ${session.doneCount} ${session.doneCount == 1 ? 'file' : 'files'}'
          : 'Received ${session.doneCount}, ${session.failedCount} failed',
    LsReceiveState.cancelledBySender =>
      '${session.sender.alias} cancelled the transfer',
    LsReceiveState.cancelledByReceiver => 'Cancelled',
    LsReceiveState.stalled => 'The sender stopped responding',
  };

  @override
  Widget build(BuildContext context) {
    final total = session.totalBytes;
    final received = session.receivedBytes;
    final files = session.files.values.toList();
    final active = session.isActive;
    final ok = session.state == LsReceiveState.finished &&
        session.failedCount == 0;
    return LsSection(
      title: 'From ${session.sender.alias}',
      icon: lsDeviceIcon(session.sender.deviceType),
      trailing: active
          ? TextButton(
              style: TextButton.styleFrom(
                foregroundColor: context.colors.destructive,
              ),
              onPressed: controller.cancelReceive,
              child: const Text('Cancel'),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LsProgress(
            status: _stateText(),
            tone: active
                ? Tone.neutral
                : ok
                ? Tone.success
                : Tone.destructive,
            value: total == 0 ? (active ? null : 1) : received / total,
            detail:
                '${lsSize(received)} / ${lsSize(total)} · ${session.doneCount}/${files.length} files',
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: files.length,
              itemBuilder: (context, i) {
                final f = files[i];
                final size = f.dto.size;
                final saved = f.savedPath;
                return ListRow(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  leading: LsFileIcon(f.dto.fileName, size: 32),
                  title: f.dto.fileName,
                  subtitleWidget: switch (f.status) {
                    LsReceiveFileStatus.receiving => LinearProgressIndicator(
                      value: size == 0 ? null : f.received / size,
                    ),
                    LsReceiveFileStatus.failed => LsErrorText(f.error ?? 'Failed'),
                    _ => null,
                  },
                  subtitle: lsSize(size),
                  trailing: LsFileState(
                    done: f.status == LsReceiveFileStatus.done,
                    failed: f.status == LsReceiveFileStatus.failed,
                  ),
                  onTap: saved == null
                      ? null
                      : () => FileOpener.open(context, File(saved)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ReceivedSection extends StatelessWidget {
  const _ReceivedSection({required this.controller});

  final LocalSendController controller;

  @override
  Widget build(BuildContext context) {
    final items = controller.received;
    return LsSection(
      title: 'Received',
      icon: LucideIcons.inbox,
      subtitle: items.isEmpty
          ? null
          : '${items.length} ${items.length == 1 ? 'file' : 'files'}',
      child: items.isEmpty
          ? const LsHint(
              'Files you receive while this screen is open appear here.',
              icon: LucideIcons.inbox,
            )
          : Column(
              children: [
                for (final item in items.take(200))
                  ListRow(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                    leading: LsFileIcon(item.path),
                    title: item.fileName,
                    subtitle: '${lsSize(item.size)} · from ${item.from}',
                    onTap: () => _open(context, item),
                    trailing: MenuIconButton<String>(
                      onSelected: (v) {
                        switch (v) {
                          case 'open':
                            _open(context, item);
                          case 'folder':
                            lsShowInFolder(context, item.path);
                          case 'remove':
                            controller.removeReceived(item);
                        }
                      },
                      itemBuilder: (_) => [
                        menuItem(
                          value: 'open',
                          icon: LucideIcons.fileSearch,
                          label: 'Open',
                        ),
                        menuItem(
                          value: 'folder',
                          icon: LucideIcons.folderOpen,
                          label: 'Show in folder',
                        ),
                        menuItem(
                          value: 'remove',
                          icon: LucideIcons.listX,
                          label: 'Remove from list',
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  void _open(BuildContext context, LsReceivedItem item) {
    final file = File(item.path);
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The file was moved or deleted.')),
      );
      return;
    }
    FileOpener.open(context, file);
  }
}
