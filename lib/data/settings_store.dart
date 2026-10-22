import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/hotkey_spec.dart';

/// 应用设置，目前只有快速记录的全局快捷键。
class AppSettings {
  const AppSettings({this.quickHotkey = HotkeySpec.defaultQuick});

  final HotkeySpec quickHotkey;

  AppSettings copyWith({HotkeySpec? quickHotkey}) {
    return AppSettings(quickHotkey: quickHotkey ?? this.quickHotkey);
  }

  Map<String, dynamic> toJson() => {
    'quick_hotkey': quickHotkey.toJson(),
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final hotkey = json['quick_hotkey'];
    if (hotkey is Map) {
      try {
        return AppSettings(
          quickHotkey: HotkeySpec.fromJson(
            hotkey.cast<String, dynamic>(),
          ),
        );
      } on FormatException catch (error) {
        debugPrint('设置里的快捷键无效，回退默认值：$error');
      }
    }
    return const AppSettings();
  }
}

/// `settings.json` 的读写。损坏时回退默认设置并留档，不阻断启动。
class SettingsStore {
  SettingsStore({required this.rootDir});

  final Directory rootDir;

  File get settingsFile => File(p.join(rootDir.path, 'settings.json'));

  Future<AppSettings> load() async {
    if (!await settingsFile.exists()) return const AppSettings();
    try {
      final text = await settingsFile.readAsString();
      if (text.trim().isEmpty) return const AppSettings();
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const FormatException('settings.json 顶层不是对象');
      }
      return AppSettings.fromJson(decoded.cast<String, dynamic>());
    } catch (error) {
      debugPrint('settings.json 读取失败，使用默认设置：$error');
      await _preserveCorruptFile();
      return const AppSettings();
    }
  }

  Future<void> save(AppSettings settings) async {
    await rootDir.create(recursive: true);
    final content = const JsonEncoder.withIndent('  ').convert(
      settings.toJson(),
    );
    final tmp = File('${settingsFile.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    try {
      await tmp.rename(settingsFile.path);
    } on FileSystemException {
      await settingsFile.writeAsString(content, flush: true);
      if (await tmp.exists()) await tmp.delete();
    }
  }

  Future<void> _preserveCorruptFile() async {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final target = File(p.join(rootDir.path, 'settings.corrupt-$stamp.json'));
    try {
      await settingsFile.rename(target.path);
    } on FileSystemException catch (error) {
      debugPrint('损坏的设置文件留档失败：$error');
    }
  }
}
