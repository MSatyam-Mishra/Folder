import 'package:folders/core/theme/app_style.dart';

import 'panes_shots.dart';

/// SCREENSHOTS=1 flutter test test/screenshots/panes_screens_test.dart
/// Dual pane and the preview pane in the styles with Lucide's icons
/// (build/screenshots/panes_*.png).
void main() => panesShots(
      [AppStyle.standard, AppStyle.windows, AppStyle.macos, AppStyle.sweet, AppStyle.dracula],
      more: true,
    );
