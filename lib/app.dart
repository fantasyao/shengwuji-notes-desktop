import 'package:flutter/material.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'data/settings_store.dart';
import 'models/hotkey_spec.dart';
import 'pages/notes_page.dart';
import 'pages/quick_capture_page.dart';
import 'pages/settings_dialog.dart';
import 'state/notes_controller.dart';
import 'theme/app_theme.dart';

/// 应用外壳：主界面与速记窗共用同一个原生窗口，只切换尺寸与页面。
///
/// 关闭主窗口只是隐藏到托盘，全局快捷键、托盘菜单仍能把窗口叫回来。
class ShengwujiApp extends StatefulWidget {
  const ShengwujiApp({
    super.key,
    required this.controller,
    required this.settingsStore,
    required this.initialSettings,
  });

  final NotesController controller;
  final SettingsStore settingsStore;
  final AppSettings initialSettings;

  @override
  State<ShengwujiApp> createState() => _ShengwujiAppState();
}

class _ShengwujiAppState extends State<ShengwujiApp>
    with WindowListener, TrayListener {
  static const Size _quickSize = Size(460, 400);
  static const Size _mainMinSize = Size(880, 600);
  static const Size _quickMinSize = Size(460, 400);
  static const double _quickMargin = 24;

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  late AppSettings _settings;
  HotkeySpec get _hotkey => _settings.quickHotkey;

  /// 速记窗是否已占据窗口（隐藏时仍保留，方便草稿与再次呼出）。
  bool _quickMode = false;
  bool _switching = false;
  bool _quitting = false;
  String _draft = '';
  Rect? _mainBounds;
  bool _mainWasMaximized = false;

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initDesktop();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  Future<void> _initDesktop() async {
    await windowManager.setPreventClose(true);
    await _registerHotkey(_hotkey);
    await _initTray();
  }

  Future<void> _initTray() async {
    try {
      await trayManager.setIcon('assets/tray_icon.ico');
      await _refreshTrayMenu();
    } catch (error) {
      debugPrint('托盘图标初始化失败：$error');
    }
  }

  Future<void> _refreshTrayMenu() async {
    final menu = Menu(
      items: [
        MenuItem(
          key: 'quick',
          label: '快速记录 (${_hotkey.label})',
          onClick: (_) => _summonQuick(),
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'main',
          label: '打开主界面',
          onClick: (_) => _openMain(),
        ),
        MenuItem(
          key: 'settings',
          label: '设置…',
          onClick: (_) => _openSettings(),
        ),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出', onClick: (_) => _quit()),
      ],
    );
    try {
      await trayManager.setContextMenu(menu);
    } catch (error) {
      debugPrint('托盘菜单初始化失败：$error');
    }
  }

  Future<void> _registerHotkey(HotkeySpec spec) async {
    await hotKeyManager.register(
      spec.toHotKey(),
      keyDownHandler: (_) => _toggleQuick(),
    );
  }

  Future<void> _toggleQuick() async {
    if (_switching) return;
    if (_quickMode && await windowManager.isVisible()) {
      await _dismissQuick();
      return;
    }
    await _summonQuick();
  }

  /// 把窗口缩成右下角速记窗并置顶显示。
  Future<void> _summonQuick() async {
    if (_switching) return;
    _switching = true;
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      if (!_quickMode) {
        _mainWasMaximized = await windowManager.isMaximized();
        if (_mainWasMaximized) await windowManager.unmaximize();
        _mainBounds = await windowManager.getBounds();
      }
      final display = await screenRetriever.getPrimaryDisplay();
      final origin = display.visiblePosition ?? Offset.zero;
      final area = display.visibleSize ?? display.size;
      final left =
          origin.dx + area.width - _quickSize.width - _quickMargin;
      final top =
          origin.dy + area.height - _quickSize.height - _quickMargin;

      await windowManager.setMinimumSize(_quickMinSize);
      await windowManager.setResizable(false);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(true);
      await windowManager.setBounds(
        Rect.fromLTWH(left, top, _quickSize.width, _quickSize.height),
      );
      if (!mounted) return;
      setState(() => _quickMode = true);
      await windowManager.show();
      await windowManager.focus();
    } finally {
      _switching = false;
    }
  }

  /// 收起速记窗：只隐藏窗口，草稿留在内存里，下次呼出继续写。
  Future<void> _dismissQuick() async {
    await windowManager.hide();
  }

  Future<void> _saveQuickDraft(String text) async {
    final content = text.trim();
    if (content.isEmpty) return;
    final note = widget.controller.createDraft().copyWith(content: content);
    await widget.controller.upsert(note);
    _draft = '';
  }

  /// 回到主界面；速记窗里的文字先存成笔记。
  Future<void> _openMain() async {
    if (!_quickMode) {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
      return;
    }
    if (_switching) return;
    _switching = true;
    try {
      await _saveQuickDraft(_draft);
      await windowManager.setResizable(true);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSkipTaskbar(false);
      await windowManager.setMinimumSize(_mainMinSize);
      final bounds =
          _mainBounds ??
          Rect.fromLTWH(
            0,
            0,
            1180,
            780,
          );
      await windowManager.setBounds(bounds);
      if (_mainWasMaximized) await windowManager.maximize();
      if (!mounted) return;
      setState(() => _quickMode = false);
      await windowManager.show();
      await windowManager.focus();
    } finally {
      _switching = false;
    }
  }

  Future<void> _openSettings() async {
    await _openMain();
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => SettingsDialog(
        currentHotkey: _hotkey,
        onApply: _applyHotkey,
      ),
    );
  }

  Future<String?> _applyHotkey(HotkeySpec spec) async {
    final previous = _hotkey;
    try {
      await hotKeyManager.unregisterAll();
      await _registerHotkey(spec);
    } catch (error) {
      debugPrint('注册快捷键失败：$error');
      try {
        await _registerHotkey(previous);
      } catch (restoreError) {
        debugPrint('恢复旧快捷键失败：$restoreError');
      }
      return '注册失败，换一个组合试试';
    }

    final next = _settings.copyWith(quickHotkey: spec);
    try {
      await widget.settingsStore.save(next);
    } catch (error) {
      debugPrint('保存设置失败：$error');
      return '快捷键已生效，但写入设置文件失败：$error';
    }
    if (mounted) setState(() => _settings = next);
    await _refreshTrayMenu();
    return null;
  }

  Future<void> _quit() async {
    if (_quitting) return;
    _quitting = true;
    await hotKeyManager.unregisterAll();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    if (_quitting) return;
    if (_quickMode) {
      _dismissQuick();
    } else {
      windowManager.hide();
    }
  }

  @override
  void onTrayIconMouseDown() {
    _openMain();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: '声物记电脑版',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: _quickMode
          ? QuickCapturePage(
              key: const ValueKey('quick-capture'),
              initialText: _draft,
              hotkeyLabel: _hotkey.label,
              onChanged: (text) => _draft = text,
              onSave: (text) async {
                await _saveQuickDraft(text);
                await _dismissQuick();
              },
              onClose: _dismissQuick,
              onOpenMain: (text) async {
                _draft = text;
                await _openMain();
              },
              onDragStart: () => windowManager.startDragging(),
            )
          : NotesHomePage(
              key: const ValueKey('notes-home'),
              controller: widget.controller,
              hotkeyLabel: _hotkey.label,
              onOpenSettings: _openSettings,
              onQuickCapture: _summonQuick,
            ),
    );
  }
}
