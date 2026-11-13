import 'package:flutter/widgets.dart';

/// A row a browser adds to a menu built elsewhere ("Copy to other pane"):
/// what it says and does.
class PaneMenuAction {
  const PaneMenuAction({required this.label, required this.icon, required this.run, this.shortcut});

  final String label;
  final IconData icon;
  final String? shortcut;
  final VoidCallback run;
}

/// A layout switch for the header's buttons and its View menu: dual pane,
/// the preview pane, or (with [on] null) an action such as Swap panes.
class PaneToggle {
  const PaneToggle({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.on,
    this.shortcut,
    this.button = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  /// Whether it's switched on; null for an action.
  final bool? on;
  final String? shortcut;

  /// Also a button in the header (else only in the View menu).
  final bool button;
}
