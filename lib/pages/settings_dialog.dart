import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/hotkey_spec.dart';
import '../sync/sync_config.dart';

/// 设置弹窗：快速记录快捷键、笔记数据目录与 WebDAV 同步。
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.currentHotkey,
    required this.onApply,
    this.currentDataDir,
    this.onChooseDataDir,
    this.syncConfig = const SyncConfig(),
    this.currentSyncPassword = '',
    this.onApplySync,
    this.onTestSync,
  });

  final HotkeySpec currentHotkey;

  /// 返回 null 表示成功，返回字符串表示失败原因（弹窗保持打开）。
  final Future<String?> Function(HotkeySpec spec) onApply;

  final String? currentDataDir;

  /// 返回新目录路径；null 表示用户取消。抛异常表示失败。
  final Future<String?> Function()? onChooseDataDir;

  final SyncConfig syncConfig;
  final String currentSyncPassword;

  /// 保存 WebDAV 设置；返回 null 表示成功。
  final Future<String?> Function(SyncConfig config, String password)?
  onApplySync;

  /// 测试 WebDAV 连接；返回 null 表示成功。
  final Future<String?> Function(SyncConfig config, String password)?
  onTestSync;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late HotkeySpec _pending;
  late String _dataDir;
  final FocusNode _recordFocus = FocusNode();
  late final TextEditingController _syncUrl;
  late final TextEditingController _syncUser;
  late final TextEditingController _syncPassword;
  late final TextEditingController _syncDir;
  late bool _syncEnabled;
  late bool _syncAudio;
  late int _syncAutoMinutes;
  bool _recording = false;
  bool _saving = false;
  bool _changingDir = false;
  bool _testingSync = false;
  String? _error;
  String? _dataError;
  String? _syncError;
  String? _syncNotice;

  bool get _showSync => widget.onApplySync != null || widget.onTestSync != null;

  @override
  void initState() {
    super.initState();
    _pending = widget.currentHotkey;
    _dataDir = widget.currentDataDir ?? '';
    final sync = widget.syncConfig;
    _syncUrl = TextEditingController(text: sync.baseUrl);
    _syncUser = TextEditingController(text: sync.username);
    _syncPassword = TextEditingController(text: widget.currentSyncPassword);
    _syncDir = TextEditingController(text: sync.remoteDir);
    _syncEnabled = sync.enabled;
    _syncAudio = sync.audioEnabled;
    _syncAutoMinutes = sync.autoSyncMinutes;
  }

  @override
  void dispose() {
    _recordFocus.dispose();
    _syncUrl.dispose();
    _syncUser.dispose();
    _syncPassword.dispose();
    _syncDir.dispose();
    super.dispose();
  }

  SyncConfig get _pendingSync => SyncConfig(
    baseUrl: _syncUrl.text.trim(),
    username: _syncUser.text.trim(),
    remoteDir: SyncConfig.normalizeRemoteDir(_syncDir.text),
    enabled: _syncEnabled,
    audioEnabled: _syncAudio,
    autoSyncMinutes: _syncAutoMinutes,
  );

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
    final sync = _pendingSync;
    if (_showSync && sync.enabled && !sync.isConfigured) {
      setState(() => _syncError = '启用同步需要填写 WebDAV 地址与账号');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _syncError = null;
      _syncNotice = null;
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
    final syncHandler = widget.onApplySync;
    if (syncHandler != null) {
      final syncError = await syncHandler(sync, _syncPassword.text);
      if (!mounted) return;
      if (syncError != null) {
        setState(() {
          _saving = false;
          _syncError = syncError;
        });
        return;
      }
    }
    Navigator.of(context).pop();
  }

  Future<void> _testSync() async {
    final handler = widget.onTestSync;
    if (handler == null || _testingSync) return;
    final sync = _pendingSync;
    if (!sync.isConfigured) {
      setState(() {
        _syncError = '请先填写 WebDAV 地址与账号';
        _syncNotice = null;
      });
      return;
    }
    setState(() {
      _testingSync = true;
      _syncError = null;
      _syncNotice = null;
    });
    final error = await handler(sync, _syncPassword.text);
    if (!mounted) return;
    setState(() {
      _testingSync = false;
      if (error == null) {
        _syncNotice = '连接成功，远端目录可用';
      } else {
        _syncError = error;
      }
    });
  }

  Future<void> _chooseDataDir() async {
    final handler = widget.onChooseDataDir;
    if (handler == null || _changingDir) return;
    setState(() {
      _changingDir = true;
      _dataError = null;
    });
    try {
      final path = await handler();
      if (!mounted) return;
      if (path != null) setState(() => _dataDir = path);
    } catch (error) {
      if (!mounted) return;
      setState(() => _dataError = error.toString());
    } finally {
      if (mounted) setState(() => _changingDir = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('设置'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
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
                                color: _recording
                                    ? theme.colorScheme.primary
                                    : null,
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
              const SizedBox(height: 18),
              const Divider(height: 1),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(
                    '数据位置',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _changingDir || widget.onChooseDataDir == null
                        ? null
                        : _chooseDataDir,
                    child: Text(_changingDir ? '处理中…' : '更改…'),
                  ),
                ],
              ),
              Text(
                '笔记与图片存放的文件夹，切换后立即生效；现有数据会复制到新目录，原目录保留。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.8,
                    ),
                  ),
                ),
                child: Tooltip(
                  message: _dataDir,
                  child: Text(
                    _dataDir,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
              if (_dataError != null) ...[
                const SizedBox(height: 10),
                Text(
                  _dataError!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              if (_showSync) ...[
                const SizedBox(height: 18),
                const Divider(height: 1),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text(
                      'WebDAV 同步',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Switch(
                      value: _syncEnabled,
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _syncEnabled = value),
                    ),
                  ],
                ),
                Text(
                  '与手机端共用一个 WebDAV 目录；启动、改动后、按设置的间隔以及手动点击都会同步。'
                  '手机 App 目前只能看到新增的笔记，桌面端的修改与删除不会回写手机。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _syncUrl,
                  enabled: !_saving && _syncEnabled,
                  decoration: const InputDecoration(
                    labelText: 'WebDAV 地址',
                    hintText: 'https://dav.example.com/remote.php/dav/files/me',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _syncUser,
                        enabled: !_saving && _syncEnabled,
                        decoration: const InputDecoration(
                          labelText: '账号',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _syncPassword,
                        enabled: !_saving && _syncEnabled,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: '密码 / 应用密码',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _syncDir,
                  enabled: !_saving && _syncEnabled,
                  decoration: const InputDecoration(
                    labelText: '远端目录',
                    hintText: SyncConfig.defaultRemoteDir,
                    helperText: '与手机端保持一致，默认 /shengwuji_sync',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '同步录音',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '关闭时只保留“这条笔记有录音”的信息；开启后会从云端下载 audio/ 里的录音文件。',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _syncAudio,
                      onChanged: _saving || !_syncEnabled
                          ? null
                          : (value) => setState(() => _syncAudio = value),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '自动检查云端',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '按间隔检查云端变化；没有变化时只发少量元信息请求，不上传文件。',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    DropdownButton<int>(
                      value: _syncAutoMinutes,
                      isDense: true,
                      underline: const SizedBox.shrink(),
                      onChanged: _saving || !_syncEnabled
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() => _syncAutoMinutes = value);
                              }
                            },
                      items: [
                        for (final minutes in SyncConfig.autoSyncOptions)
                          DropdownMenuItem(
                            value: minutes,
                            child: Text(minutes == 0 ? '关闭' : '$minutes 分钟'),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _testingSync || _saving || !_syncEnabled
                          ? null
                          : _testSync,
                      icon: _testingSync
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_outlined, size: 17),
                      label: Text(_testingSync ? '正在连接…' : '测试连接'),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '密码保存在系统凭据管理器，不写入设置文件。',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.75,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_syncError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _syncError!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                if (_syncNotice != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _syncNotice!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ],
            ],
          ),
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
