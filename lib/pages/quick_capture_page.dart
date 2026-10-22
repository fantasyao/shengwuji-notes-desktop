import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// 快速记录窗：主窗口被压缩成 460x400 时展示的紧凑编辑页。
///
/// 设计成“随手写完就走”：Ctrl+Enter 保存并收起，Esc 收起但保留草稿。
class QuickCapturePage extends StatefulWidget {
  const QuickCapturePage({
    super.key,
    required this.initialText,
    required this.hotkeyLabel,
    required this.onChanged,
    required this.onSave,
    required this.onClose,
    required this.onOpenMain,
    this.onDragStart,
  });

  final String initialText;
  final String hotkeyLabel;
  final ValueChanged<String> onChanged;
  final Future<void> Function(String text) onSave;
  final VoidCallback onClose;
  final Future<void> Function(String text) onOpenMain;
  final VoidCallback? onDragStart;

  @override
  State<QuickCapturePage> createState() => _QuickCapturePageState();
}

class _QuickCapturePageState extends State<QuickCapturePage> {
  late final TextEditingController _textController;
  final FocusNode _focusNode = FocusNode();
  bool _busy = false;

  bool get _hasText => _textController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialText)
      ..addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _textController
      ..removeListener(_onTextChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    widget.onChanged(_textController.text);
    setState(() {});
  }

  Future<void> _save() async {
    if (_busy || !_hasText) return;
    setState(() => _busy = true);
    try {
      await widget.onSave(_textController.text);
      _textController.clear();
      if (mounted) setState(() => _busy = false);
    } catch (error) {
      if (!mounted) return;
      _showError('保存失败：$error');
      setState(() => _busy = false);
    }
  }

  Future<void> _openMain() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onOpenMain(_textController.text);
    } catch (error) {
      if (mounted) _showError('保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            builder: (context, value, child) {
              return Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, (1 - value) * 8),
                  child: child,
                ),
              );
            },
            child: Column(
              children: [
                _buildHeader(theme),
                Expanded(child: _buildEditor(theme)),
                _buildFooter(theme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: widget.onDragStart == null
          ? null
          : (_) => widget.onDragStart!(),
      child: Container(
        height: 56,
        padding: const EdgeInsets.only(left: 14, right: 8),
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          border: Border(bottom: BorderSide(color: AppSurface.border(context))),
        ),
        child: Row(
          children: [
            Icon(
              Icons.drag_indicator_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            const SizedBox(width: 8),
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF26A69A), Color(0xFF00796B)],
                ),
              ),
              child: const Icon(
                Icons.bolt_rounded,
                color: Colors.white,
                size: 18,
              ),
            ),
            const SizedBox(width: 8),
            Text('快速记录', style: theme.textTheme.titleMedium),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                widget.hotkeyLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: '打开主界面',
              visualDensity: VisualDensity.compact,
              onPressed: _busy ? null : _openMain,
              icon: const Icon(Icons.open_in_full_rounded, size: 18),
            ),
            IconButton(
              tooltip: '收起 (Esc)',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onClose,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditor(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: TextField(
        controller: _textController,
        focusNode: _focusNode,
        autofocus: true,
        expands: true,
        maxLines: null,
        minLines: null,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        style: theme.textTheme.bodyLarge?.copyWith(fontSize: 15, height: 1.7),
        decoration: InputDecoration(
          hintText: '记点什么…\n\nCtrl+V 粘贴文本，Enter 换行。',
          contentPadding: const EdgeInsets.all(14),
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            height: 1.7,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Ctrl+Enter 保存并收起 · Esc 收起且保留草稿',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: _busy || !_hasText ? null : _save,
            icon: _busy
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded, size: 18),
            label: const Text('保存并收起'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }
}
