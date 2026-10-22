import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/hotkey_spec.dart';

/// 设置弹窗：目前只有快速记录的全局快捷键。
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.currentHotkey,
    required this.onApply,
  });

  final HotkeySpec currentHotkey;

  /// 返回 null 表示成功，返回字符串表示失败原因（弹窗保持打开）。
  final Future<String?> Function(HotkeySpec spec) onApply;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late HotkeySpec _pending;
  final FocusNode _recordFocus = FocusNode();
  bool _recording = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _pending = widget.currentHotkey;
  }

  @override
  void dispose() {
    _recordFocus.dispose();
    super.dispose();
  }

  void _startRecording() {
    setState(() {
      _recording = true;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recordFocus.requestFocus();
    });
  }

  KeyEventResult _onRecordKey(FocusNode node, KeyEvent event) {
    if (!_recording) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      setState(() => _recording = false);
      return KeyEventResult.handled;
    }
    if (_isModifierKey(key)) return KeyEventResult.handled;

    final control = HardwareKeyboard.instance.isControlPressed;
    final alt = HardwareKeyboard.instance.isAltPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final meta = HardwareKeyboard.instance.isMetaPressed;

    if (!control && !alt && !meta) {
      setState(() => _error = '至少包含 Ctrl、Alt 或 Win 之一');
      return KeyEventResult.handled;
    }

    final physical = event.physicalKey;
    if (physical.usbHidUsage == 0) {
      setState(() => _error = '这个按键无法注册，请换一个');
      return KeyEventResult.handled;
    }

    setState(() {
      _pending = HotkeySpec(
        usbHidUsage: physical.usbHidUsage,
        keyLabel: HotkeySpec.labelFor(key),
        control: control,
        alt: alt,
        shift: shift,
        meta: meta,
      );
      _recording = false;
      _error = null;
    });
    return KeyEventResult.handled;
  }

  bool _isModifierKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.control ||
        key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.alt ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.shift ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.meta ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight;
  }

  Future<void> _save() async {
    if (_recording || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.onApply(_pending);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _saving = false;
        _error = error;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('设置'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '快速记录',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '按一次快捷键，在任何软件上方呼出速记窗；关闭主窗口后仍可在托盘常驻。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 14),
            Focus(
              focusNode: _recordFocus,
              onKeyEvent: _onRecordKey,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _recording
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outlineVariant,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _recording
                          ? Icons.keyboard_alt_outlined
                          : Icons.keyboard_rounded,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _recording ? '请按下新的组合键…' : _pending.label,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: _recording ? theme.colorScheme.primary : null,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _recording
                                ? '至少包含 Ctrl / Alt / Win 之一，Esc 取消录制'
                                : '呼出快速记录',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _recording ? null : _startRecording,
                      child: Text(_recording ? '录制中' : '修改'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '快捷键由系统全局注册。若和别的软件冲突，换一个组合即可。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.75,
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving
              ? null
              : () {
                  setState(() {
                    _pending = HotkeySpec.defaultQuick;
                    _recording = false;
                    _error = null;
                  });
                },
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _recording || _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
  }
}
