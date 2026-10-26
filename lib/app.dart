import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:path/path.dart' as p;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'data/data_location.dart';
import 'data/note_store.dart';
import 'data/settings_store.dart';
import 'models/hotkey_spec.dart';
import 'models/quick_draft.dart';
import 'pages/notes_page.dart';
import 'pages/quick_capture_page.dart';
import 'pages/settings_dialog.dart';
import 'services/system_fonts.dart';
import 'state/notes_controller.dart';
import 'sync/password_store.dart';
import 'sync/sync_config.dart';
import 'sync/sync_service.dart';
import 'sync/webdav_request_counter.dart';
import 'theme/app_theme.dart';
import 'theme/app_zoom.dart';
import 'widgets/window_title_bar.dart';
import 'widgets/zoom_host.dart';
import 'widgets/zoom_shortcuts.dart';
import 'window/quick_window_placement.dart';

/// 应用外壳：主界面与速记窗共用同一个原生窗口，只切换尺寸与页面。
///
/// 关闭主窗口只是隐藏到托盘，全局快捷键、托盘菜单仍能把窗口叫回来。
class ShengwujiApp extends StatefulWidget {
  const ShengwujiApp({
    super.key,
    required this.controller,
    required this.settingsStore,
    required this.initialSettings,
    required this.syncService,
    required this.passwordStore,
    required this.requestCounter,
  });

  final NotesController controller;
  final SettingsStore settingsStore;
  final AppSettings initialSettings;
  final SyncService syncService;
  final PasswordStore passwordStore;
  final WebDavRequestCounter requestCounter;

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
  final GlobalKey<QuickCapturePageState> _quickPageKey =
      GlobalKey<QuickCapturePageState>();

  late AppSettings _settings;
  late NotesController _controller;
  late SyncService _syncService;
  late Directory _dataDir;
  final SystemFontCatalog _fontCatalog = SystemFontCatalog();

  /// 启动后就在后台扫一遍系统字体，第一次打开设置时不用等。
  late final Future<List<SystemFont>> _fontFuture = _fontCatalog.load();
  HotkeySpec get _hotkey => _settings.quickHotkey;

  /// 速记窗是否已占据窗口（隐藏时仍保留，方便草稿与再次呼出）。
  bool _quickMode = false;
  bool _switching = false;
  bool _quitting = false;
  QuickDraft _draft = const QuickDraft();

  /// 每次把速记窗叫到前台就加一，速记页据此把焦点交还输入框。
  int _quickFocusRequest = 0;
  Rect? _mainBounds;
  bool _mainWasMaximized = false;

  /// 设置弹窗打开时暂停缩放快捷键：弹窗里的缩放只在点保存后生效，
  /// 避免快捷键先改了设置、弹窗再拿旧值覆盖回去。
  bool _settingsOpen = false;

  /// 连续按 Ctrl+= 时串行落盘，避免两次保存同时写同一个临时文件。
  Future<void> _saveQueue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _settings = widget.initialSettings;
    _controller = widget.controller;
    _syncService = widget.syncService;
    _dataDir = widget.controller.store.rootDir;
    windowManager.addListener(this);
    trayManager.addListener(this);
    _initDesktop();
    unawaited(
      _fontFuture.then(
        (_) {},
        onError: (Object error) => debugPrint('读取系统字体失败：$error'),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_syncService.syncOnStartup());
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    _syncService.dispose();
    _controller.dispose();
    unawaited(_controller.store.close());
    unawaited(widget.requestCounter.flush());
    widget.requestCounter.dispose();
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
        MenuItem(key: 'main', label: '打开主界面', onClick: (_) => _openMain()),
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

  /// 速记窗内的「丢弃并收起」键：窗口在前台时临时注册成系统热键。
  ///
  /// 走 WM_HOTKEY 而不是框架内的 SingleActivator，是为了绕开中文输入法——
  /// 组字时按键会被输入法吃掉，框架层收不到；系统热键不受影响。
  /// 窗口失焦或收起就注销，免得抢走别的软件里的 Ctrl+D。
  static final HotKey _discardHotkey = HotKey(
    key: PhysicalKeyboardKey.keyD,
    modifiers: [HotKeyModifier.control],
    scope: HotKeyScope.system,
  );

  bool _discardHotkeyRegistered = false;

  /// 呼出速记窗的全局热键本身就是 Ctrl+D 时不能再抢，否则会互相顶掉。
  bool get _hotkeyIsCtrlD =>
      _hotkey.control &&
      !_hotkey.alt &&
      !_hotkey.shift &&
      !_hotkey.meta &&
      _hotkey.toPhysicalKey() == PhysicalKeyboardKey.keyD;

  Future<void> _registerDiscardHotkey() async {
    if (_discardHotkeyRegistered || !_quickMode || _hotkeyIsCtrlD) return;
    try {
      await hotKeyManager.register(
        _discardHotkey,
        keyDownHandler: (_) => _discardFromHotkey(),
      );
      _discardHotkeyRegistered = true;
    } catch (error) {
      debugPrint('注册 Ctrl+D 丢弃热键失败：$error');
    }
  }

  Future<void> _unregisterDiscardHotkey() async {
    if (!_discardHotkeyRegistered) return;
    _discardHotkeyRegistered = false;
    try {
      await hotKeyManager.unregister(_discardHotkey);
    } catch (error) {
      debugPrint('注销 Ctrl+D 丢弃热键失败：$error');
    }
  }

  Future<void> _discardFromHotkey() async {
    if (!_quickMode) return;
    final page = _quickPageKey.currentState;
    if (page == null) return;
    await page.discardFromHost();
  }

  Future<void> _toggleQuick() async {
    if (_switching) return;
    if (_quickMode && await windowManager.isVisible()) {
      await _dismissQuick();
      return;
    }
    await _summonQuick();
  }

  /// 把窗口缩成速记窗并置顶显示。
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
      final bounds = await _quickBounds();

      await windowManager.setMinimumSize(_quickMinSize);
      await windowManager.setResizable(false);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSkipTaskbar(true);
      await windowManager.setBounds(bounds);
      if (!mounted) return;
      setState(() => _quickMode = true);
      await windowManager.show();
      await windowManager.focus();
      await _registerDiscardHotkey();
      if (mounted) setState(() => _quickFocusRequest++);
    } finally {
      _switching = false;
    }
  }

  /// 速记窗的位置：开着「记住位置」且旧坐标还在某块接上的屏幕里就用它，
  /// 否则回主屏右下角。
  Future<Rect> _quickBounds() async {
    final primary = await screenRetriever.getPrimaryDisplay();
    final remembered = _settings.rememberQuickPosition
        ? _settings.quickWindowPosition
        : null;
    var displays = <Display>[primary];
    if (remembered != null) {
      try {
        final all = await screenRetriever.getAllDisplays();
        if (all.isNotEmpty) displays = all;
      } catch (error) {
        debugPrint('读取显示器列表失败，只按主屏校验位置：$error');
      }
    }
    return resolveQuickBounds(
      size: _quickSize,
      margin: _quickMargin,
      primaryArea: _displayArea(primary),
      displayAreas: [for (final display in displays) _displayArea(display)],
      remembered: remembered,
    );
  }

  Rect _displayArea(Display display) {
    return (display.visiblePosition ?? Offset.zero) &
        (display.visibleSize ?? display.size);
  }

  /// 用户拖完速记窗后记下左上角；主界面的移动不算。
  Future<void> _rememberQuickBounds() async {
    try {
      final bounds = await windowManager.getBounds();
      final current = _settings;
      if (!current.rememberQuickPosition) return;
      if (current.quickWindowPosition == bounds.topLeft) return;
      final next = current.copyWith(quickWindowPosition: bounds.topLeft);
      _settings = next;
      await widget.settingsStore.save(next);
    } catch (error) {
      debugPrint('保存速记窗位置失败：$error');
    }
  }

  /// 收起速记窗：只隐藏窗口，草稿留在内存里，下次呼出继续写。
  ///
  /// 隐藏前先放开输入框。窗口藏着的时候如果还挂着中文输入法的组字会话，
  /// 再呼出时键盘事件会全部丢给输入法，Ctrl+D / Ctrl+Enter 这些快捷键就失灵了。
  Future<void> _dismissQuick() async {
    await _unregisterDiscardHotkey();
    await _quickPageKey.currentState?.releaseInput();
    FocusManager.instance.primaryFocus?.unfocus();
    await windowManager.hide();
  }

  /// 丢弃速记草稿（Ctrl+D）：正文不留，粘贴进来的图片从磁盘删掉，再收起窗口。
  Future<void> _discardQuickDraft(QuickDraft draft) async {
    try {
      await _controller.store.deleteImages(draft.images);
    } catch (error) {
      debugPrint('清理速记草稿图片失败：$error');
    }
    _draft = const QuickDraft();
    await _dismissQuick();
  }

  /// 速记草稿落成一条笔记；图片在粘贴时已经写进数据目录，这里只负责关联。
  Future<void> _saveQuickDraft(QuickDraft draft) async {
    if (draft.isEmpty) return;
    final note = _controller.createDraft().copyWith(
      content: draft.text.trim(),
      images: List<String>.from(draft.images),
    );
    await _controller.upsert(note);
    _draft = const QuickDraft();
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
      await _unregisterDiscardHotkey();
      await _saveQuickDraft(_draft);
      await windowManager.setResizable(true);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSkipTaskbar(false);
      await windowManager.setMinimumSize(_mainMinSize);
      final bounds = _mainBounds ?? Rect.fromLTWH(0, 0, 1180, 780);
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
    List<SystemFont> fonts;
    try {
      fonts = await _fontFuture;
    } catch (error) {
      debugPrint('读取系统字体失败：$error');
      fonts = const [];
    }
    final password = await _readSyncPassword();
    if (!mounted) return;
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    _settingsOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => SettingsDialog(
          currentHotkey: _hotkey,
          currentDataDir: _dataDir.path,
          onApply: _applyHotkey,
          rememberQuickPosition: _settings.rememberQuickPosition,
          onApplyQuickPosition: _applyRememberQuickPosition,
          themeChoice: _settings.theme,
          onApplyTheme: _applyTheme,
          fontFamily: _settings.fontFamily,
          fontFamilies: fonts,
          onApplyFont: _applyFont,
          zoomPercent: _settings.zoomPercent,
          onApplyZoom: _applyZoom,
          onChooseDataDir: _chooseDataDir,
          syncConfig: _settings.sync,
          currentSyncPassword: password,
          onApplySync: _applySyncSettings,
          onTestSync: (config, candidate) =>
              _syncService.testConnection(config, candidate),
          requestCounter: widget.requestCounter,
        ),
      );
    } finally {
      _settingsOpen = false;
    }
  }

  Future<String> _readSyncPassword() async {
    try {
      return await widget.passwordStore.read() ?? '';
    } catch (error) {
      debugPrint('读取 WebDAV 密码失败：$error');
      return '';
    }
  }

  Future<String?> _applySyncSettings(SyncConfig config, String password) async {
    final next = _settings.copyWith(sync: config);
    try {
      await widget.settingsStore.save(next);
      if (password.isEmpty) {
        await widget.passwordStore.delete();
      } else {
        await widget.passwordStore.write(password);
      }
    } catch (error) {
      return '保存同步设置失败：$error';
    }
    if (!mounted) return null;
    setState(() => _settings = next);
    _syncService.configure(config);
    if (config.enabled && config.isConfigured) {
      unawaited(_syncService.sync(manual: true));
    }
    return null;
  }

  /// 让用户换一个笔记目录：复制现有数据过去，原目录保留，切换后立即生效。
  Future<String?> _chooseDataDir() async {
    final selected = await getDirectoryPath(confirmButtonText: '选择此文件夹');
    if (selected == null) return null;
    final target = Directory(selected);
    if (p.equals(p.normalize(target.path), p.normalize(_dataDir.path))) {
      return _dataDir.path;
    }
    try {
      await target.create(recursive: true);
    } on FileSystemException catch (error) {
      throw DataDirectoryException('无法使用这个文件夹：${error.message}');
    }

    final existing = await hasExistingNotes(target);
    if (existing) {
      final context = _navigatorKey.currentContext;
      if (context == null || !context.mounted) return null;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('这个文件夹已有笔记'),
          content: Text(
            '切换后会显示该文件夹里的笔记，当前目录的数据会原样保留。\n\n'
            '${target.path}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('切换'),
            ),
          ],
        ),
      );
      if (confirmed != true) return null;
    }

    try {
      await _controller.flush();
      if (!existing) await _controller.store.copyTo(target);
    } catch (error) {
      throw DataDirectoryException('复制笔记失败：$error');
    }

    final nextStore = NoteStore(rootDir: target);
    late final SyncService nextSyncService;
    final nextController = NotesController(
      nextStore,
      onLocalChange: () => nextSyncService.noteLocalChange(),
    );
    await nextController.load();
    if (nextController.error != null) {
      final message = nextController.error!;
      nextController.dispose();
      await nextStore.close();
      throw DataDirectoryException(message);
    }

    final nextSettings = _settings.copyWith(dataDirectory: target.path);
    try {
      await widget.settingsStore.save(nextSettings);
    } catch (error) {
      nextController.dispose();
      await nextStore.close();
      throw DataDirectoryException('保存设置失败：$error');
    }

    nextSyncService = SyncService(
      store: nextStore,
      passwordStore: widget.passwordStore,
      onSynced: nextController.reloadAfterSync,
      config: nextSettings.sync,
      deviceId: nextSettings.deviceId,
      requestCounter: widget.requestCounter,
    );
    await nextSyncService.initialize();

    final previous = _controller;
    final previousStore = previous.store;
    final previousSync = _syncService;
    if (!mounted) {
      nextSyncService.dispose();
      nextController.dispose();
      await nextStore.close();
      return null;
    }
    setState(() {
      _controller = nextController;
      _syncService = nextSyncService;
      _dataDir = target;
      _settings = nextSettings;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      previousSync.dispose();
      previous.dispose();
      await previousStore.close();
    });
    return target.path;
  }

  Future<String?> _applyHotkey(HotkeySpec spec) async {
    final previous = _hotkey;
    try {
      await hotKeyManager.unregisterAll();
      _discardHotkeyRegistered = false;
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
    if (_quickMode) unawaited(_registerDiscardHotkey());

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

  Future<String?> _applyRememberQuickPosition(bool remember) async {
    if (_settings.rememberQuickPosition == remember) return null;
    final next = _settings.copyWith(rememberQuickPosition: remember);
    try {
      await widget.settingsStore.save(next);
    } catch (error) {
      return '保存速记窗位置设置失败：$error';
    }
    if (mounted) setState(() => _settings = next);
    return null;
  }

  Future<String?> _applyTheme(AppThemeChoice theme) async {
    if (_settings.theme == theme) return null;
    final next = _settings.copyWith(theme: theme);
    try {
      await widget.settingsStore.save(next);
    } catch (error) {
      return '保存外观设置失败：$error';
    }
    if (mounted) setState(() => _settings = next);
    return null;
  }

  Future<String?> _applyFont(String family) async {
    if (_settings.fontFamily == family) return null;
    final next = _settings.copyWith(fontFamily: family);
    try {
      await widget.settingsStore.save(next);
    } catch (error) {
      return '保存字体设置失败：$error';
    }
    if (mounted) setState(() => _settings = next);
    return null;
  }

  Future<String?> _applyZoom(int percent) async {
    final normalized = normalizeZoomPercent(percent);
    if (_settings.zoomPercent == normalized) return null;
    final next = _settings.copyWith(zoomPercent: normalized);
    try {
      await widget.settingsStore.save(next);
    } catch (error) {
      return '保存缩放设置失败：$error';
    }
    if (mounted) setState(() => _settings = next);
    return null;
  }

  void _stepZoom(int direction) {
    final current = _settings.zoomPercent;
    _zoomTo(direction > 0 ? zoomInPercent(current) : zoomOutPercent(current));
  }

  void _resetZoom() => _zoomTo(kDefaultZoomPercent);

  /// 快捷键先改界面再落盘；连续按的时候排队写，避免并发写坏设置文件。
  void _zoomTo(int percent) {
    if (_settingsOpen) return;
    final normalized = normalizeZoomPercent(percent);
    if (_settings.zoomPercent == normalized) return;
    final next = _settings.copyWith(zoomPercent: normalized);
    setState(() => _settings = next);
    _saveQueue = _saveQueue.then((_) async {
      try {
        await widget.settingsStore.save(next);
      } catch (error) {
        debugPrint('保存缩放设置失败：$error');
      }
    });
  }

  Future<void> _quit() async {
    if (_quitting) return;
    _quitting = true;
    await _saveQueue;
    await widget.requestCounter.flush();
    // 速记草稿没保存就退出时，粘贴进来的图片还留在磁盘上，顺手清掉。
    try {
      await _controller.store.deleteImages(_draft.images);
    } catch (error) {
      debugPrint('清理速记草稿图片失败：$error');
    }
    _draft = const QuickDraft();
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
  void onWindowBlur() {
    // 速记窗不在前台时不占着 Ctrl+D，免得妨碍其它软件。
    if (_quickMode) unawaited(_unregisterDiscardHotkey());
  }

  @override
  void onWindowFocus() {
    if (_quickMode) unawaited(_registerDiscardHotkey());
  }

  @override
  void onWindowMoved() {
    if (!_quickMode || !_settings.rememberQuickPosition) return;
    unawaited(_rememberQuickBounds());
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
      theme: AppTheme.light(fontFamily: _settings.fontFamily),
      darkTheme: AppTheme.dark(fontFamily: _settings.fontFamily),
      themeMode: _settings.theme.themeMode,
      // 标题栏画在 Navigator 之上且不参与缩放，编辑器与回收站路由推上来时
      // 同样保留；下面的页面整体按设置的比例缩放。
      builder: (context, child) => Column(
        children: [
          WindowTitleBar(
            key: ValueKey('title-bar-$_quickMode'),
            label: _quickMode ? null : '声物记电脑版',
            showMinimize: !_quickMode,
            showMaximize: !_quickMode,
          ),
          Expanded(
            child: ZoomShortcuts(
              onZoomIn: () => _stepZoom(1),
              onZoomOut: () => _stepZoom(-1),
              onReset: _resetZoom,
              child: ZoomHost(
                percent: _settings.zoomPercent,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
      home: _quickMode
          ? QuickCapturePage(
              key: _quickPageKey,
              controller: _controller,
              initialDraft: _draft,
              hotkeyLabel: _hotkey.label,
              onChanged: (draft) => _draft = draft,
              onSave: (draft) async {
                await _saveQuickDraft(draft);
                await _dismissQuick();
              },
              onClose: _dismissQuick,
              onDiscard: _discardQuickDraft,
              onOpenMain: (draft) async {
                _draft = draft;
                await _openMain();
              },
              onDragStart: () => windowManager.startDragging(),
              focusRequest: _quickFocusRequest,
            )
          : NotesHomePage(
              key: ValueKey('notes-home-${_dataDir.path}'),
              controller: _controller,
              syncService: _syncService,
              hotkeyLabel: _hotkey.label,
              onOpenSettings: _openSettings,
              onQuickCapture: _summonQuick,
            ),
    );
  }
}
