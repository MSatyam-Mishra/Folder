import 'dart:io';

import 'package:folder/core/services/localsend/localsend.dart';
import 'package:folder/features/localsend/localsend_controller.dart';
import 'package:folder/features/localsend/widgets/localsend_dialogs.dart';
import 'package:folder/features/localsend/widgets/localsend_receive_panel.dart';
import 'package:folder/features/localsend/widgets/localsend_send_panel.dart';
import 'package:folder/features/localsend/widgets/localsend_settings_sheet.dart';
import 'package:folder/features/viewer_kit/viewer_kit.dart';
import 'package:folder/shared/widgets/docked_glossy_top_bar.dart';
import 'package:folder/shared/widgets/explorer_scaffold.dart';
import 'package:flutter/material.dart';

/// Nearby sharing over the LocalSend protocol: send [initialItems] (files and
/// folders) to, or receive files from, devices running LocalSend on the same
/// network. The receiver and discovery run only while this screen is open.
class LocalSendScreen extends StatefulWidget {
  const LocalSendScreen({
    super.key,
    this.initialItems = const [],
    @visibleForTesting this.controller,
  });

  final List<FileSystemEntity> initialItems;

  /// Replaces the screen's own controller (tests and screenshots).
  final LocalSendController? controller;

  @override
  State<LocalSendScreen> createState() => _LocalSendScreenState();
}

class _LocalSendScreenState extends State<LocalSendScreen>
    with SingleTickerProviderStateMixin {
  late final LocalSendController _controller =
      widget.controller ??
      LocalSendController(initialItems: widget.initialItems);
  late final TabController _tabs;
  String? _shownReceiveSession;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialItems.isEmpty ? 1 : 0,
    );
    _controller
      ..incomingHandler = _askIncoming
      ..pinPrompt = _askPin
      ..addListener(_onControllerChanged);
    _controller.start();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _tabs.dispose();
    super.dispose();
  }

  /// Jump to the receive tab when an incoming transfer starts (phones).
  void _onControllerChanged() {
    final session = _controller.receiveSession;
    if (session != null && session.id != _shownReceiveSession) {
      _shownReceiveSession = session.id;
      if (_tabs.index != 1) _tabs.animateTo(1);
    }
  }

  Future<LsReceiveDecision> _askIncoming(LsIncomingRequest request) async {
    if (!mounted) return const LsReceiveDecision.decline();
    final fingerprint = request.sender.fingerprint.toUpperCase();
    final answer = await showLsIncomingDialog(
      context,
      request,
      alreadyTrusted: _controller.trusted.containsKey(fingerprint),
    );
    if (answer.accept && answer.trust) await _controller.trust(request.sender);
    return answer.accept
        ? const LsReceiveDecision.accept()
        : const LsReceiveDecision.decline();
  }

  Future<String?> _askPin({required bool invalid}) async {
    if (!mounted) return null;
    final alias = _controller.sendSession?.target.alias ?? 'receiver';
    return showLsPinDialog(context, deviceAlias: alias, invalid: invalid);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => PopScope(
        canPop: !_transferRunning,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          if (await _confirmLeave() && context.mounted) {
            Navigator.of(context).pop();
          }
        },
        child: _scaffold(context),
      ),
    );
  }

  bool get _transferRunning =>
      (_controller.sendSession != null && !_controller.sendSession!.isDone) ||
      (_controller.receiveSession?.isActive ?? false);

  Future<bool> _confirmLeave() async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Stop the transfer?'),
        content: const Text(
          'Leaving this screen cancels the running transfer and stops nearby sharing.',
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: dialogContext.colors.destructive,
              foregroundColor: dialogContext.colors.destructiveForeground,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Stop and leave'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  Widget _scaffold(BuildContext context) => ExplorerScaffold(
    title: 'Nearby share',
    trailing: Padding(
      padding: const EdgeInsets.only(right: 4),
      child: AppIconButton(
        icon: const Icon(LucideIcons.settings),
        tooltip: 'Settings',
        onPressed: _controller.settings == null
            ? null
            : () => showLsSettingsSheet(context, _controller),
      ),
    ),
    body: _body(context),
  );

  Widget _body(BuildContext context) {
    final top = DockedGlossyTopBar.contentTopInset(context);
    final bottom = 16 + MediaQuery.paddingOf(context).bottom;
    if (_controller.starting) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: const ViewerLoading(label: 'Starting nearby sharing…'),
      );
    }
    final error = _controller.startupError;
    if (error != null) {
      return ViewerMessage(
        icon: LucideIcons.wifiOff,
        title: "Nearby sharing couldn't start",
        message: error,
        padding: EdgeInsets.fromLTRB(24, top + 24, 24, bottom),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 840) {
          // Tablet / desktop: send and receive side by side.
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: LsSendPanel(
                      controller: _controller,
                      padding: EdgeInsets.fromLTRB(16, top + 16, 8, bottom),
                    ),
                  ),
                  Expanded(
                    child: LsReceivePanel(
                      controller: _controller,
                      padding: EdgeInsets.fromLTRB(8, top + 16, 16, bottom),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return Column(
          children: [
            SizedBox(height: top + 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: _SegmentTabs(
                controller: _tabs,
                tabs: const [
                  (LucideIcons.upload, 'Send'),
                  (LucideIcons.download, 'Receive'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  LsSendPanel(
                    controller: _controller,
                    padding: EdgeInsets.fromLTRB(12, 12, 12, bottom),
                  ),
                  LsReceivePanel(
                    controller: _controller,
                    padding: EdgeInsets.fromLTRB(12, 12, 12, bottom),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// shadcn Tabs: a muted track with the selected tab raised.
class _SegmentTabs extends StatelessWidget {
  const _SegmentTabs({required this.controller, required this.tabs});

  final TabController controller;
  final List<(IconData, String)> tabs;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 40,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.muted,
        borderRadius: BorderRadius.circular(10),
      ),
      child: TabBar(
        controller: controller,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(7),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: context.isDarkMode ? 0.3 : 0.08),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        labelColor: colors.foreground,
        unselectedLabelColor: colors.mutedForeground,
        labelStyle: Theme.of(context).textTheme.labelLarge,
        splashBorderRadius: BorderRadius.circular(7),
        tabs: [
          for (final (icon, label) in tabs)
            Tab(
              height: 32,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16),
                  const SizedBox(width: 8),
                  Text(label),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
