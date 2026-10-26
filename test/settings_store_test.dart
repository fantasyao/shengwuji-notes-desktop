import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/data/settings_store.dart';
import 'package:shengwuji_desktop/models/hotkey_spec.dart';
import 'package:shengwuji_desktop/sync/sync_config.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';

void main() {
  late Directory dir;
  late SettingsStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('shengwuji_settings_test_');
    store = SettingsStore(rootDir: dir);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('没有设置文件时返回默认快捷键', () async {
    final settings = await store.load();
    expect(settings.quickHotkey.label, 'Ctrl + Alt + Space');
  });

  test('保存后能读回自定义快捷键', () async {
    const custom = HotkeySpec(
      usbHidUsage: 0x00070012,
      keyLabel: 'O',
      control: true,
      alt: true,
    );
    await store.save(AppSettings(quickHotkey: custom));
    expect(store.settingsFile.existsSync(), isTrue);

    final restored = await store.load();
    expect(restored.quickHotkey.label, 'Ctrl + Alt + O');
  });

  test('保存并读回自定义数据目录', () async {
    await store.save(const AppSettings(dataDirectory: r'D:\声物记笔记'));
    final restored = await store.load();
    expect(restored.dataDirectory, r'D:\声物记笔记');
    expect(restored.quickHotkey.label, 'Ctrl + Alt + Space');
  });

  test('保存并读回 WebDAV 配置，密码不落在设置文件里', () async {
    await store.save(
      const AppSettings(
        sync: SyncConfig(
          baseUrl: 'https://dav.example.com',
          username: 'demo',
          remoteDir: '/notes/',
          enabled: false,
          audioEnabled: true,
          autoSyncMinutes: 15,
        ),
      ),
    );

    final restored = await store.load();
    expect(restored.sync.baseUrl, 'https://dav.example.com');
    expect(restored.sync.username, 'demo');
    expect(restored.sync.remoteDir, '/notes');
    expect(restored.sync.enabled, isFalse);
    expect(restored.sync.audioEnabled, isTrue);
    expect(restored.sync.autoSyncMinutes, 15);
    expect(restored.sync.isConfigured, isTrue);

    final text = store.settingsFile.readAsStringSync();
    expect(text, contains('dav.example.com'));
    expect(text.toLowerCase(), isNot(contains('password')));
  });

  test('自动同步间隔损坏时回退默认 10 分钟', () async {
    store.settingsFile.writeAsStringSync(
      '{"sync": {"base_url": "https://dav.example.com", '
      '"username": "demo", "auto_sync_minutes": 7}}',
    );

    final settings = await store.load();
    expect(settings.sync.autoSyncMinutes, SyncConfig.defaultAutoSyncMinutes);
    expect(settings.sync.autoSyncInterval, const Duration(minutes: 10));
  });

  test('首次加载生成稳定的设备 id', () async {
    final first = await store.load();
    final second = await store.load();
    expect(first.deviceId, isNotEmpty);
    expect(second.deviceId, first.deviceId);
  });

  test('保存并读回外观设置', () async {
    final defaults = await store.load();
    expect(defaults.theme, AppThemeChoice.system);

    await store.save(const AppSettings(theme: AppThemeChoice.dark));
    final restored = await store.load();
    expect(restored.theme, AppThemeChoice.dark);
    expect(restored.theme.themeMode, ThemeMode.dark);
  });

  test('外观值损坏时回退跟随系统', () async {
    store.settingsFile.writeAsStringSync('{"theme": "sepia"}');
    final settings = await store.load();
    expect(settings.theme, AppThemeChoice.system);
  });

  test('保存并读回字体设置', () async {
    final defaults = await store.load();
    expect(defaults.fontFamily, isEmpty);

    await store.save(const AppSettings(fontFamily: 'KaiTi'));
    final restored = await store.load();
    expect(restored.fontFamily, 'KaiTi');
    expect(
      store.settingsFile.readAsStringSync(),
      contains('"font_family": "KaiTi"'),
    );
  });

  test('字体值损坏时回退默认字体', () async {
    store.settingsFile.writeAsStringSync('{"font_family": 42}');
    final settings = await store.load();
    expect(settings.fontFamily, isEmpty);
  });

  test('保存并读回速记窗位置', () async {
    await store.save(
      const AppSettings(
        rememberQuickPosition: true,
        quickWindowPosition: Offset(2400, -120),
      ),
    );

    final restored = await store.load();
    expect(restored.rememberQuickPosition, isTrue);
    expect(restored.quickWindowPosition, const Offset(2400, -120));
  });

  test('速记窗位置损坏时当作没记过，但保留开关', () async {
    store.settingsFile.writeAsStringSync(
      '{"remember_quick_position": true, '
      '"quick_window_position": {"left": "x", "top": 3}}',
    );

    final settings = await store.load();
    expect(settings.rememberQuickPosition, isTrue);
    expect(settings.quickWindowPosition, isNull);
  });

  test('损坏的设置文件回退默认并留档', () async {
    store.settingsFile.writeAsStringSync('{ not json');
    final settings = await store.load();
    expect(settings.quickHotkey.label, 'Ctrl + Alt + Space');

    final backups = dir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('settings.corrupt-'))
        .toList();
    expect(backups, hasLength(1));
  });
}
