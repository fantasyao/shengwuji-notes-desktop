import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/hotkey_spec.dart';
import '../sync/sync_config.dart';

/// 应用设置：快速记录快捷键、笔记数据目录与 WebDAV 同步配置。
///
/// `settings.json` 始终留在应用支持目录；[dataDirectory] 为空表示使用默认目录。
/// WebDAV 密码不在这里，见 `PasswordStore`。
class AppSettings {
  const AppSettings({
    this.quickHotkey = HotkeySpec.defaultQuick,
    this.dataDirectory,
    this.sync = const SyncConfig(),
    this.deviceId = '',
  });

  final HotkeySpec quickHotkey;
  final String? dataDirectory;
  final SyncConfig sync;

  /// 本机固定设备 id，用于远端锁与冲突裁决；首次启动生成后不再变化。
  final String deviceId;

  AppSettings copyWith({
    HotkeySpec? quickHotkey,
    String? dataDirectory,
    SyncConfig? sync,
    String? deviceId,
  }) {
    return AppSettings(
      quickHotkey: quickHotkey ?? this.quickHotkey,
      dataDirectory: dataDirectory ?? this.dataDirectory,
      sync: sync ?? this.sync,
      deviceId: deviceId ?? this.deviceId,
    );
  }

  Map<String, dynamic> toJson() => {
    'quick_hotkey': quickHotkey.toJson(),
    if (dataDirectory != null) 'data_directory': dataDirectory,
    'sync': sync.toJson(),
    if (deviceId.isNotEmpty) 'device_id': deviceId,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    var quickHotkey = HotkeySpec.defaultQuick;
    final hotkey = json['quick_hotkey'];
    if (hotkey is Map) {
      try {
        quickHotkey = HotkeySpec.fromJson(hotkey.cast<String, dynamic>());
      } on FormatException catch (error) {
        debugPrint('设置里的快捷键无效，回退默认值：$error');
      }
    }
    final directory = json['data_directory'];
    final sync = json['sync'];
    final deviceId = json['device_id'];
    return AppSettings(
      quickHotkey: quickHotkey,
      dataDirectory: directory is String && directory.trim().isNotEmpty
          ? directory.trim()
          : null,
      sync: sync is Map
          ? SyncConfig.fromJson(sync.cast<String, dynamic>())
          : const SyncConfig(),
      deviceId: deviceId is String ? deviceId.trim() : '',
    );
  }
}

/// `settings.json` 的读写。损坏时回退默认设置并留档，不阻断启动。
class SettingsStore {
  SettingsStore({required this.rootDir});

  static const Uuid _uuid = Uuid();

  final Directory rootDir;

  File get settingsFile => File(p.join(rootDir.path, 'settings.json'));

  Future<AppSettings> load() async {
    final settings = await _loadRaw();
    if (settings.deviceId.isNotEmpty) return settings;

    // 设备 id 必须跨启动稳定，生成后立刻落盘；写失败也不阻断启动。
    final next = settings.copyWith(deviceId: _uuid.v4());
    try {
      await save(next);
    } catch (error) {
      debugPrint('保存设备 id 失败：$error');
    }
    return next;
  }

  Future<AppSettings> _loadRaw() async {
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
