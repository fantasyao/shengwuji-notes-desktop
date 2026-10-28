import 'package:flutter/material.dart';

/// 窗口内容首次挂载时的淡入上浮。
///
/// 速记窗与主界面共用同一套时长、曲线和位移，从一个窗口切到另一个时
/// 观感一致。窗口只是隐藏再显示时不会重建内容，因此不会反复播放。
class WindowEntrance extends StatelessWidget {
  const WindowEntrance({super.key, required this.child});

  static const Duration duration = Duration(milliseconds: 160);
  static const Curve curve = Curves.easeOutCubic;
  static const double rise = 8;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: curve,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * rise),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
