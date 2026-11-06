import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:folders/shared/file_icons/file_icons.dart';
import 'package:folders/shared/layout/adaptive_layout.dart';
import 'package:folders/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folders/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:filesize/filesize.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart' show LucideIcons;
import 'package:folders/core/services/root_service.dart';
import 'package:folders/core/services/usb_host_service.dart';
import 'package:folders/core/services/usb_boot_service.dart';

class UsbBootScreen extends StatefulWidget {
  const UsbBootScreen({super.key});

  @override
  State<UsbBootScreen> createState() => _UsbBootScreenState();
}

class _UsbBootScreenState extends State<UsbBootScreen> {
  final _rootService = RootService();
  final _usbRootService = UsbBootService();
  final _usbHostService = UsbHostService();

  bool _isLoading = true;
  bool _useRoot = false; // Default to Rootless if possible
  String? _isoPath;
  int? _isoSize;

  // Union type for selection (Root BlockDevice or Rootless UsbDeviceWrapper)
  dynamic _selectedDevice;
  List<dynamic> _devices = [];

  bool _isFlashing = false;
  double _progress = 0.0;
  String _progressStatus = '';
  Process? _flashProcess;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _usbHostService.init();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() => _isLoading = true);
    _devices = [];
    _selectedDevice = null;

    try {
      if (_useRoot) {
        // Root Logic
        bool rooted = await _rootService.isRooted();
        if (!rooted) rooted = await _rootService.requestRootAccess();

        if (rooted) {
          final devices = await _usbRootService.getConnectableDevices();
          if (mounted) {
            setState(() {
              _devices = devices;
              if (devices.isNotEmpty) _selectedDevice = devices.first;
            });
          }
        }
      } else {
        // Rootless Logic
        final devices = await _usbHostService.getDeviceList();
        if (mounted) {
          setState(() {
            _devices = devices;
            if (devices.isNotEmpty) _selectedDevice = devices.first;
          });
        }
      }
    } catch (e) {
      debugPrint("Error loading devices: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickIso() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      final file = File(path);
      final size = await file.length();
      setState(() {
        _isoPath = path;
        _isoSize = size;
      });
    }
  }

  Future<void> _startFlashing() async {
    if (_isoPath == null || _selectedDevice == null) return;

    // Safety check
    final deviceName = _deviceLabel(_selectedDevice);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final colors = ctx.colors;
        return AlertDialog(
          title: Text('Erase "$deviceName"?'),
          content: Text(
            'Everything on this drive will be permanently erased and '
            "replaced with ${p.basename(_isoPath!)}. This can't be undone.",
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colors.destructive,
                foregroundColor: colors.destructiveForeground,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Erase and write'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    setState(() {
      _isFlashing = true;
      _progress = 0.0;
      _progressStatus = "Starting...";
    });

    try {
      if (_useRoot) {
        // Root Flash (dd)
        _flashProcess = await _usbRootService.flashIsoToDevice(
          _isoPath!,
          (_selectedDevice as BlockDevice).path,
        );
        _flashProcess!.stderr.transform(utf8.decoder).listen((data) {
          // Parse dd progress (same as before)
          final regex = RegExp(r'(\d+) bytes');
          final match = regex.firstMatch(data);
          if (match != null && _isoSize != null) {
            final bytes = int.parse(match.group(1)!);
            if (mounted) {
              setState(() {
                _progress = (bytes / _isoSize!).clamp(0.0, 1.0);
                _progressStatus = "${filesize(bytes)} / ${filesize(_isoSize)}";
              });
            }
          }
        });
        await _flashProcess!.exitCode;
      } else {
        // Rootless Flash
        final wrapper = _selectedDevice as UsbDeviceWrapper;

        // Request Permission
        bool hasPerm = await _usbHostService.hasPermission(wrapper);
        if (!hasPerm) {
          hasPerm = await _usbHostService.requestPermission(wrapper);
        }

        if (!hasPerm) {
          throw Exception("USB Permission Denied");
        }

        await _usbHostService.flashIsoToDevice(
          File(_isoPath!),
          wrapper,
          onProgress: (pct) {
            if (mounted) {
              setState(() {
                _progress = pct;
                _progressStatus = "${(pct * 100).toStringAsFixed(1)}%";
              });
            }
          },
        );
      }

      if (mounted) {
        setState(() {
          _isFlashing = false;
          _progress = 1.0;
          _progressStatus = "Done. The drive is ready to boot.";
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("Image written to the drive")));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isFlashing = false;
          _progressStatus = "Error: $e";
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Error: $e")));
      }
    }
  }

  @override
  void dispose() {
    _flashProcess?.kill();
    _usbHostService.dispose();
    super.dispose();
  }

  String _deviceLabel(dynamic device) => _useRoot
      ? (device as BlockDevice).name
      : (device as UsbDeviceWrapper).name;

  String _deviceDetail(dynamic device) => _useRoot
      ? '${(device as BlockDevice).sizeHumanReadable} · ${device.path}'
      : 'USB device · ID ${(device as UsbDeviceWrapper).productId}';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    final top = DockedGlossyTopBar.contentTopInset(context);
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final side = wide ? 24.0 : 16.0;
    final iso = _isoPath;
    final canFlash = iso != null && _selectedDevice != null && !_isFlashing;

    return ExplorerScaffold(
      title: 'Bootable USB',
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          side,
          top + 20,
          side,
          MediaQuery.paddingOf(context).bottom + 24,
        ),
        child: ReadableWidth(
          maxWidth: 640,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Write a disk image to a USB drive to make it bootable.',
                style: text.bodyMedium?.copyWith(color: colors.mutedForeground),
              ),
              const SizedBox(height: 16),
              _Card(
                child: Row(
                  children: [
                    _IconTile(
                      _useRoot ? LucideIcons.shieldCheck : LucideIcons.usb,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Root mode', style: text.titleSmall),
                          const SizedBox(height: 2),
                          Text(
                            _useRoot
                                ? 'Writes with dd. Needs a rooted device.'
                                : "Off: uses Android's USB host API through "
                                    'an OTG adapter. No root needed.',
                            style: text.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Switch(
                      value: _useRoot,
                      onChanged: _isFlashing
                          ? null
                          : (v) {
                              setState(() => _useRoot = v);
                              _loadDevices();
                            },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _StepCard(
                step: 1,
                title: 'Disk image',
                description: 'An .iso or .img file to write.',
                child: iso == null
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _isFlashing ? null : _pickIso,
                          icon: const Icon(LucideIcons.folderOpen, size: 16),
                          label: const Text('Choose image'),
                        ),
                      )
                    : _SelectedRow(
                        leading: FileIcon(path: iso, size: 36),
                        title: p.basename(iso),
                        subtitle: _isoSize == null ? '' : filesize(_isoSize),
                        trailing: TextButton(
                          onPressed: _isFlashing ? null : _pickIso,
                          child: const Text('Change'),
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              _StepCard(
                step: 2,
                title: 'Target drive',
                description: 'Everything on this drive will be erased.',
                trailing: AppIconButton(
                  icon: const Icon(LucideIcons.refreshCw, size: 16),
                  tooltip: 'Refresh drives',
                  onPressed: _isFlashing || _isLoading ? null : _loadDevices,
                ),
                child: _buildDevices(context),
              ),
              const SizedBox(height: 12),
              _StepCard(
                step: 3,
                title: 'Write',
                description: 'Keep the drive connected until writing finishes.',
                child: _isFlashing
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _progressStatus,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodySmall,
                                ),
                              ),
                              Text(
                                '${(_progress * 100).toStringAsFixed(1)}%',
                                style: text.labelMedium?.copyWith(
                                  color: colors.foreground,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: _progress.clamp(0.0, 1.0),
                            minHeight: 8,
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_progressStatus.isNotEmpty) ...[
                            Text(
                              _progressStatus,
                              style: text.bodySmall?.copyWith(
                                color: _progressStatus.startsWith('Error')
                                    ? colors.destructive
                                    : colors.mutedForeground,
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          FilledButton.icon(
                            onPressed: canFlash ? _startFlashing : null,
                            icon: const Icon(LucideIcons.zap, size: 16),
                            label: const Text('Write to drive'),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDevices(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    if (_isLoading) {
      return Row(
        children: [
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text('Looking for drives…', style: text.bodySmall),
        ],
      );
    }
    if (_devices.isEmpty) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: colors.muted.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(LucideIcons.usb, size: 18, color: colors.mutedForeground),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'No USB drives detected',
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      _useRoot
                          ? 'Connect a drive and allow root access, then '
                              'refresh.'
                          : 'Connect a drive with an OTG adapter, then '
                              'refresh.',
                      style: text.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final device in _devices)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _DeviceOption(
              title: _deviceLabel(device),
              subtitle: _deviceDetail(device),
              selected: identical(device, _selectedDevice),
              onTap: _isFlashing
                  ? null
                  : () => setState(() => _selectedDevice = device),
            ),
          ),
      ],
    );
  }
}

/// Bordered surface (shadcn card).
class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: colors.muted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 18, color: colors.foreground),
    );
  }
}

/// A numbered step: heading, description and its controls.
class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.step,
    required this.title,
    required this.description,
    required this.child,
    this.trailing,
  });

  final int step;
  final String title;
  final String description;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.border),
                ),
                child: Text(
                  '$step',
                  style: text.labelMedium?.copyWith(color: colors.foreground),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleSmall),
                    Text(description, style: text.bodySmall),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _SelectedRow extends StatelessWidget {
  const _SelectedRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        leading,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
              if (subtitle.isNotEmpty) Text(subtitle, style: text.bodySmall),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// A selectable drive (radio-card).
class _DeviceOption extends StatelessWidget {
  const _DeviceOption({
    required this.title,
    required this.subtitle,
    required this.selected,
    this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = Theme.of(context).textTheme;
    return Material(
      color: selected ? colors.accent : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: selected ? colors.ring : colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(LucideIcons.hardDrive, size: 18, color: colors.foreground),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(subtitle, style: text.bodySmall),
                  ],
                ),
              ),
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? colors.primary : colors.mutedForeground,
                    width: selected ? 5 : 1.25,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
