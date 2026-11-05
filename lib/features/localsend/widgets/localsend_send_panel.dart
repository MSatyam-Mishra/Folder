import 'dart:io';

import 'package:folder/core/services/localsend/localsend.dart';
import 'package:folder/features/localsend/localsend_controller.dart';
import 'package:folder/features/localsend/widgets/localsend_common.dart';
import 'package:folder/features/localsend/widgets/localsend_dialogs.dart';
import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/shared/file_icons/file_icons.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Files to send, nearby devices and the running send transfer.
class LsSendPanel extends StatelessWidget {
  const LsSendPanel({
    super.key,
    required this.controller,
    required this.padding,
  });

  final LocalSendController controller;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final session = controller.sendSession;
    return ListView(
      padding: padding,
      children: [
        _FilesSection(controller: controller),
        if (session != null)
          _SendProgressSection(controller: controller, session: session),
        _DevicesSection(controller: controller),
      ],
    );
  }
}

class _FilesSection extends StatelessWidget {
  const _FilesSection({required this.controller});

  final LocalSendController controller;

  Future<void> _pickFiles(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths = result?.files.map((f) => f.path).whereType<String>().toList();
    if (paths == null || paths.isEmpty) return;
    controller.addItems(paths.map(File.new));
  }

  Future<void> _pickFolder(BuildContext context) async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    controller.addItems([Directory(path)]);
  }

  @override
  Widget build(BuildContext context) {
    final items = controller.items;
    final files = controller.sendFiles;
    final busy =
        controller.sendSession != null && !controller.sendSession!.isDone;
    return LsSection(
      title: 'Files to send',
      icon: LucideIcons.fileUp,
      subtitle: items.isNotEmpty && files != null
          ? '${files.length} ${files.length == 1 ? 'file' : 'files'} · '
              '${lsSize(controller.sendTotalBytes)}'
          : null,
      trailing: items.isEmpty || busy
          ? null
          : TextButton(
              onPressed: controller.clearItems,
              child: const Text('Clear'),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (items.isEmpty)
            const LsHint(
              'Pick files or folders, then tap a device below. Folders keep '
              'their structure.',
              icon: LucideIcons.info,
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final e = items[i];
                  final isDir = e is Directory;
                  final (count, bytes) = controller.statsFor(e);
                  final name = p.basename(p.normalize(e.path));
                  return ListRow(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                    leading: isDir
                        ? const FolderIcon(size: 40)
                        : FileIcon(path: name, size: 40),
                    title: name,
                    subtitle: files == null
                        ? 'Counting…'
                        : isDir
                        ? 'Folder · $count ${count == 1 ? 'file' : 'files'} · ${lsSize(bytes)}'
                        : (count == 0 ? 'Not readable' : lsSize(bytes)),
                    trailing: busy
                        ? null
                        : ToolButton(
                            icon: LucideIcons.x,
                            tooltip: 'Remove',
                            onPressed: () => controller.removeItem(e),
                          ),
                  );
                },
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : () => _pickFiles(context),
                icon: const Icon(LucideIcons.filePlus2, size: 16),
                label: const Text('Add files'),
              ),
              if (!Platform.isIOS)
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _pickFolder(context),
                  icon: const Icon(LucideIcons.folderPlus, size: 16),
                  label: const Text('Add folder'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DevicesSection extends StatelessWidget {
  const _DevicesSection({required this.controller});

  final LocalSendController controller;

  Future<void> _addByIp(BuildContext context) async {
    final address = await showLsAddressDialog(context);
    if (address == null || address.isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text('Connecting to $address…')));
    try {
      final device = await controller.addByAddress(address);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Added ${device.alias}')));
    } on LsException catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text('Could not add $address: ${e.message}')),
        );
    }
  }

  void _send(BuildContext context, LsDevice device) {
    final error = controller.sendTo(device);
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final devices = controller.devices;
    final scanning = controller.scanning;
    return LsSection(
      title: 'Nearby devices',
      icon: LucideIcons.radar,
      subtitle: devices.isEmpty
          ? null
          : '${devices.length} found · tap one to send',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (scanning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ToolButton(
            icon: LucideIcons.link,
            tooltip: 'Add by IP',
            onPressed: controller.service == null
                ? null
                : () => _addByIp(context),
          ),
          ToolButton(
            icon: LucideIcons.refreshCw,
            tooltip: 'Refresh',
            onPressed: controller.service == null ? null : controller.refresh,
          ),
        ],
      ),
      child: devices.isEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LsHint(
                  scanning
                      ? 'Scanning the network…'
                      : 'Looking for devices… Open LocalSend on the other device '
                            'and make sure both are on the same Wi-Fi.',
                  icon: LucideIcons.wifi,
                ),
                if (controller.multicastError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Automatic discovery is limited here (${controller.multicastError}). '
                      'Use "Scan network" or add the device by IP.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    "Can't see it? "
                    '${controller.localAddresses.isEmpty ? '' : 'This device is ${controller.localAddresses.first}. '}'
                    'On Windows, allow LocalSend through the firewall for '
                    'private networks (Windows Security → Firewall → Allow an '
                    'app). Guest Wi-Fi often blocks devices from seeing each '
                    'other. You can also add a device by its IP.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: scanning || controller.service == null
                        ? null
                        : controller.scan,
                    icon: const Icon(LucideIcons.radar, size: 16),
                    label: const Text('Scan network'),
                  ),
                ),
              ],
            )
          : Column(
              children: [
                for (final d in devices)
                  ListRow(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                    leading: IconBox(lsDeviceIcon(d.info.deviceType)),
                    title: d.alias,
                    subtitle: [
                      if (d.info.deviceModel != null) d.info.deviceModel!,
                      d.ip,
                      if (d.protocol == LsProtocol.http) 'HTTP',
                    ].join(' · '),
                    trailing: Tooltip(
                      message: 'Send to ${d.alias}',
                      child: Icon(
                        LucideIcons.send,
                        size: 18,
                        color: colors.primary,
                      ),
                    ),
                    onTap: () => _send(context, d),
                  ),
              ],
            ),
    );
  }
}

class _SendProgressSection extends StatelessWidget {
  const _SendProgressSection({required this.controller, required this.session});

  final LocalSendController controller;
  final LsSendSession session;

  String _stateText() => switch (session.state) {
    LsSendState.preparing => 'Preparing…',
    LsSendState.waitingForPin => 'Waiting for the PIN…',
    LsSendState.waitingForAcceptance =>
      'Waiting for ${session.target.alias} to accept…',
    LsSendState.sending => 'Sending… ${lsSpeed(session.speed)}',
    LsSendState.finished => 'Sent',
    LsSendState.finishedWithErrors => 'Finished with errors',
    LsSendState.declined => 'Declined by ${session.target.alias}',
    LsSendState.failed => session.error?.message ?? 'Failed',
    LsSendState.cancelled => 'Cancelled',
    LsSendState.cancelledByReceiver =>
      '${session.target.alias} cancelled the transfer',
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final total = session.totalBytes;
    final sent = session.sentBytes;
    final done = session.isDone;
    final ok = session.state == LsSendState.finished;
    final files = session.files.values.toList();
    final waiting =
        session.state == LsSendState.waitingForAcceptance ||
        session.state == LsSendState.preparing;
    return LsSection(
      title: 'To ${session.target.alias}',
      icon: lsDeviceIcon(session.target.info.deviceType),
      trailing: done
          ? TextButton(
              onPressed: controller.dismissSend,
              child: const Text('Done'),
            )
          : TextButton(
              style: TextButton.styleFrom(
                foregroundColor: context.colors.destructive,
              ),
              onPressed: controller.cancelSend,
              child: const Text('Cancel'),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LsProgress(
            status: _stateText(),
            tone: !done
                ? Tone.neutral
                : ok
                ? Tone.success
                : Tone.destructive,
            value: waiting
                ? null
                : (total == 0 ? (done ? 1 : 0) : sent / total),
            detail:
                '${lsSize(sent)} / ${lsSize(total)} · ${files.where((f) => f.status == LsSendFileStatus.done).length}/${files.length} files',
          ),
          if (done &&
              !ok &&
              session.state == LsSendState.failed &&
              session.error?.detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(session.error!.detail!, style: text.bodySmall),
            ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: files.length,
              itemBuilder: (context, i) {
                final f = files[i];
                final size = f.file.size;
                return ListRow(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  leading: LsFileIcon(f.file.fileName, size: 32),
                  title: f.file.fileName,
                  subtitleWidget: switch (f.status) {
                    LsSendFileStatus.sending => LinearProgressIndicator(
                      value: size == 0 ? null : f.sent / size,
                    ),
                    LsSendFileStatus.failed => LsErrorText(f.error ?? 'Failed'),
                    _ => null,
                  },
                  subtitle: switch (f.status) {
                    LsSendFileStatus.skipped => 'Skipped by receiver',
                    _ => lsSize(size),
                  },
                  trailing: LsFileState(
                    done: f.status == LsSendFileStatus.done,
                    failed: f.status == LsSendFileStatus.failed,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
