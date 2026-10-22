import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/data/settings_store.dart';
import 'package:shengwuji_desktop/models/hotkey_spec.dart';

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
