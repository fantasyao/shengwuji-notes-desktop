import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/hotkey_spec.dart';
import '../services/system_fonts.dart';
import '../sync/sync_config.dart';
import '../sync/webdav_request_counter.dart';
import '../theme/app_theme.dart';
import '../widgets/font_picker.dart';

/// 设置弹窗：外观与字体、快速记录快捷键与速记窗位置、笔记数据目录与 WebDAV 同步。
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.currentHotkey,
    required this.onApply,
    this.rememberQuickPosition = false,
    this.onApplyQuickPosition,
    this.themeChoice = AppThemeChoice.system,
    this.onApplyTheme,
    this.fontFamily = '',
    this.fontFamilies = const <SystemFont>[],
    this.onApplyFont,
    this.currentDataDir,
    this.onChooseDataDir,
    this.syncConfig = const SyncConfig(),
    this.currentSyncPassword = '',
    this.onApplySync,
    this.onTestSync,
    this.requestCounter,
  });

  final HotkeySpec currentHotkey;

  /// 返回 null 表示成功，返回字符串表示失败原因（弹窗保持打开）。
  final Future<String?> Function(HotkeySpec spec) onApply;

  final bool rememberQuickPosition;

  /// 保存「记住速记窗位置」；返回 null 表示成功。
  final Future<String?> Function(bool remember)? onApplyQuickPosition;

  final AppThemeChoice themeChoice;

  /// 保存外观设置；返回 null 表示成功。
  final Future<String?> Function(AppThemeChoice theme)? onApplyTheme;

  /// 当前字体家族名；空字符串表示默认的微软雅黑。
  final String fontFamily;

  /// 本机已安装的字体，供选择框展示。
  final List<SystemFont> fontFamilies;

  /// 保存字体设置；返回 null 表示成功。
  final Future<String?> Function(String family)? onApplyFont;

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

  /// 本机 WebDAV 请求计数；为空时不显示额度行。
  final WebDavRequestCounter? requestCounter;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late HotkeySpec _pending;
  late String _dataDir;
  late bool _rememberQuickPosition;
  late AppThemeChoice _themeChoice;
  late String _fontFamily;
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
  String? _themeError;
  String? _fontError;

  bool get _showSync => widget.onApplySync != null || widget.onTestSync != null;

  @override
  void initState() {
    super.initState();
    _pending = widget.currentHotkey;
    _dataDir = widget.currentDataDir ?? '';
    _rememberQuickPosition = widget.rememberQuickPosition;
    _themeChoice = widget.themeChoice;
    _fontFamily = widget.fontFamily;
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
      _themeError = null;
      _fontError = null;
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
    final quickPositionHandler = widget.onApplyQuickPosition;
    if (quickPositionHandler != null) {
      final positionError = await quickPositionHandler(_rememberQuickPosition);
      if (!mounted) return;
      if (positionError != null) {
        setState(() {
          _saving = false;
          _error = positionError;
        });
        return;
      }
    }
    final themeHandler = widget.onApplyTheme;
    if (themeHandler != null) {
      final themeError = await themeHandler(_themeChoice);
      if (!mounted) return;
      if (themeError != null) {
        setState(() {
          _saving = false;
          _themeError = themeError;
        });
        return;
      }
    }
    final fontHandler = widget.onApplyFont;
    if (fontHandler != null) {
      final fontError = await fontHandler(_fontFamily);
      if (!mounted) return;
      if (fontError != null) {
        setState(() {
          _saving = false;
          _fontError = fontError;
        });
        return;
      }
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

  String get _fontLabel {
    if (_fontFamily.isEmpty) return kDefaultFontLabel;
    for (final font in widget.fontFamilies) {
      if (font.family == _fontFamily) return font.label;
    }
    return _fontFamily;
  }

  String get _fontDetail {
    if (_fontFamily.isEmpty) return '默认 · 系统字体';
    for (final font in widget.fontFamilies) {
      if (font.family == _fontFamily) return font.family;
    }
    return '$_fontFamily（本机未找到，将使用备用字体）';
  }

  Future<void> _chooseFont() async {
    if (_saving) return;
    final family = await showFontPicker(
      context,
      fonts: widget.fontFamilies,
      currentFamily: _fontFamily,
    );
    if (!mounted || family == null) return;
    setState(() {
      _fontFamily = family;
      _fontError = null;
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
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '外观',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '深色用深灰底色，适合夜间；跟随系统会随 Windows 的浅色 / 深色自动切换。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<AppThemeChoice>(
                  segments: [
                    for (final choice in AppThemeChoice.values)
                      ButtonSegment(value: choice, label: Text(choice.label)),
                  ],
                  selected: {_themeChoice},
                  showSelectedIcon: false,
                  expandedInsets: EdgeInsets.zero,
                  onSelectionChanged: _saving
                      ? null
                      : (selection) => setState(() {
                          _themeChoice = selection.first;
                          _themeError = null;
                        }),
                ),
              ),
              if (_themeError != null) ...[
                const SizedBox(height: 10),
                Text(
                  _themeError!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                '字体',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '使用本机已安装的字体显示界面和笔记正文；只读取字体文件，不联网。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 10),
              InkWell(
                key: const ValueKey('font-picker-field'),
                onTap: _saving ? null : _chooseFont,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.8,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _fontLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                fontFamily: _fontFamily.isEmpty
                                    ? null
                                    : _fontFamily,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _fontDetail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '选择…',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Icon(
                        Icons.expand_more_rounded,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                    ],
                  ),
                ),
              ),
              if (_fontError != null) ...[
                const SizedBox(height: 10),
                Text(
                  _fontError!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              const Divider(height: 1),
              const SizedBox(height: 14),
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
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '记住速记窗位置',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '关闭时每次都在主屏右下角呼出；开启后会记住你把速记窗拖到的位置，'
                          '方便在多个屏幕上记东西。',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  _SmallSwitch(
                    value: _rememberQuickPosition,
                    onChanged: _saving
                        ? null
                        : (value) =>
                              setState(() => _rememberQuickPosition = value),
                  ),
                ],
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
                    _SmallSwitch(
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
                    filled: false,
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
                          filled: false,
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
                          filled: false,
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
                    filled: false,
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
                    _SmallSwitch(
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
                if (widget.requestCounter != null) ...[
                  _WebDavBudgetLine(counter: widget.requestCounter!),
                  const SizedBox(height: 10),
                ],
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
                    _rememberQuickPosition = false;
                    _themeChoice = AppThemeChoice.system;
                    _themeError = null;
                    _fontFamily = '';
                    _fontError = null;
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

/// 设置页信息密集，默认 52×32 的开关显得偏大，整体缩一档向右对齐。
class _SmallSwitch extends StatelessWidget {
  const _SmallSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: 0.85,
      alignment: Alignment.centerRight,
      child: Switch(
        value: value,
        onChanged: onChanged,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

/// 最近 30 分钟的 WebDAV 请求消耗；数字随请求实时刷新。
class _WebDavBudgetLine extends StatelessWidget {
  const _WebDavBudgetLine({required this.counter});

  final WebDavRequestCounter counter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: counter,
      builder: (context, _) {
        final used = counter.recentCount;
        final limit = counter.limit;
        final remaining = used >= limit ? 0 : limit - used;
        final nearLimit = limit > 0 && used * 5 >= limit * 4;
        final color = nearLimit
            ? theme.colorScheme.error
            : theme.colorScheme.onSurfaceVariant;
        final message = nearLimit
            ? '最近 30 分钟：这台电脑已发出 $used 次请求，接近坚果云免费版上限 '
                  '$limit 次，建议降低自动检查频率或暂停同步。'
            : '最近 30 分钟：这台电脑发出 $used 次请求，按免费版估算还剩 '
                  '$remaining 次。';
        final expiry = nearLimit ? counter.untilNextExpiry : null;
        final seconds = expiry?.inSeconds;
        final minutes = seconds == null
            ? null
            : ((seconds + 59) ~/ 60).clamp(1, 30).toInt();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(Icons.speed_rounded, size: 15, color: color),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    minutes == null
                        ? message
                        : '$message最早一批约 $minutes 分钟后滑出窗口。',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: color,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '按坚果云免费版 $limit 次估算，付费版上限 1500 次；'
              '只统计这台电脑，手机端和其它客户端不计入。',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.75,
                ),
                height: 1.5,
              ),
            ),
          ],
        );
      },
    );
  }
}
