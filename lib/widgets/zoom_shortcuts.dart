import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 界面缩放快捷键：Ctrl+= / Ctrl+- 逐档调整，Ctrl+0 回到 100%。
///
/// 用 CallbackShortcuts 跟随焦点树，而不是全局键盘钩子：焦点在输入框或
/// 弹窗里时同样有效，也不会抢走其它软件的按键。
class ZoomShortcuts extends StatelessWidget {
  const ZoomShortcuts({
    super.key,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
    required this.child,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.equal, control: true):
            onZoomIn,
        const SingleActivator(
          LogicalKeyboardKey.equal,
          control: true,
          shift: true,
        ): onZoomIn,
        const SingleActivator(LogicalKeyboardKey.numpadAdd, control: true):
            onZoomIn,
        const SingleActivator(LogicalKeyboardKey.minus, control: true):
            onZoomOut,
        const SingleActivator(LogicalKeyboardKey.numpadSubtract, control: true):
            onZoomOut,
        const SingleActivator(LogicalKeyboardKey.digit0, control: true):
            onReset,
        const SingleActivator(LogicalKeyboardKey.numpad0, control: true):
            onReset,
      },
      child: child,
    );
  }
}
