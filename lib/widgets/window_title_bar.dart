import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 自绘标题栏。
///
/// Windows 10 的原生标题栏只能跟随系统主题色，无法指定底色，
/// 因此启动时用 TitleBarStyle.hidden 去掉它，把顶部区域交给 Flutter 画。
/// 左右与底部的缩放边框仍由系统保留（window_manager 的隐藏实现会留出 8px）。
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({
    super.key,
    this.label,
    this.showMinimize = true,
    this.showMaximize = true,
  });

  final String? label;
  final bool showMinimize;
  final bool showMaximize;

  static const double height = 36;

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _refreshMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => _setMaximized(true);

  @override
  void onWindowUnmaximize() => _setMaximized(false);

  @override
  void onWindowRestore() => _setMaximized(false);

  void _setMaximized(bool value) {
    if (mounted && _maximized != value) setState(() => _maximized = value);
  }

  Future<void> _refreshMaximized() async {
    final maximized = await windowManager.isMaximized();
    _setMaximized(maximized);
  }

  Future<void> _toggleMaximize() async {
    if (_maximized) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> _drag() async {
    if (_maximized) return;
    await windowManager.startDragging();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SizedBox(
        height: WindowTitleBar.height,
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => _drag(),
                onDoubleTap: widget.showMaximize ? _toggleMaximize : null,
                child: widget.label == null
                    ? const SizedBox.expand()
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: Text(
                            widget.label!,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
              ),
            ),
            if (widget.showMinimize)
              _CaptionButton(
                tooltip: '最小化',
                icon: Icons.remove_rounded,
                onPressed: windowManager.minimize,
              ),
            if (widget.showMaximize)
              _CaptionButton(
                tooltip: _maximized ? '还原' : '最大化',
                icon: _maximized
                    ? Icons.web_asset_rounded
                    : Icons.crop_square_rounded,
                onPressed: _toggleMaximize,
              ),
            _CaptionButton(
              tooltip: '关闭',
              icon: Icons.close_rounded,
              prominentHover: true,
              onPressed: windowManager.close,
            ),
          ],
        ),
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.prominentHover = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  /// 关闭按钮悬停时用强调色，和 Windows 的观感一致。
  final bool prominentHover;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final Color hoverColor = widget.prominentHover
        ? (isDark ? const Color(0xFFC42B1C) : const Color(0xFFE81123))
        : theme.colorScheme.onSurface.withValues(alpha: 0.09);
    // 这里不能用 Tooltip：标题栏在 MaterialApp.builder 里，位于 Navigator
    // 的 Overlay 之上，悬停时会因找不到 Overlay 而抛异常。
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Semantics(
        label: widget.tooltip,
        button: true,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 46,
            height: WindowTitleBar.height,
            color: _hovered ? hoverColor : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: 16,
              color: _hovered && widget.prominentHover
                  ? Colors.white
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
