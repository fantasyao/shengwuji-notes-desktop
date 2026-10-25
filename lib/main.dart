import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'data/data_location.dart';
import 'data/note_store.dart';
import 'data/settings_store.dart';
import 'state/notes_controller.dart';
import 'sync/sync_service.dart';
import 'sync/webdav_request_counter.dart';
import 'sync/windows_credential_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1180, 780),
    minimumSize: Size(880, 600),
    center: true,
    title: '声物记电脑版',
    titleBarStyle: TitleBarStyle.hidden,
  );
  unawaited(
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    }),
  );

  // 设置与数据目录指针固定在应用支持目录；笔记本身可以在设置里换到别的盘。
  final configDir = await configDirectory();
  final settingsStore = SettingsStore(rootDir: configDir);
  final settings = await settingsStore.load();
  final dataDir = await resolveDataDirectory(settings);
  final store = NoteStore(rootDir: dataDir);
  final passwordStore = WindowsCredentialPasswordStore();

  // 请求预算跟账号走，不跟笔记目录走；放配置目录，避免数据目录换盘或
  // 放进同步盘后计数被复制到其它电脑。
  final requestCounter = WebDavRequestCounter(
    storageFile: File(p.join(configDir.path, 'webdav_requests.json')),
  );

  late final SyncService syncService;
  final controller = NotesController(
    store,
    onLocalChange: () => syncService.noteLocalChange(),
  );
  syncService = SyncService(
    store: store,
    passwordStore: passwordStore,
    onSynced: controller.reloadAfterSync,
    config: settings.sync,
    deviceId: settings.deviceId,
    requestCounter: requestCounter,
  );

  await Future.wait([
    controller.load(),
    syncService.initialize(),
    requestCounter.load(),
  ]);

  runApp(
    ShengwujiApp(
      controller: controller,
      settingsStore: settingsStore,
      initialSettings: settings,
      syncService: syncService,
      passwordStore: passwordStore,
      requestCounter: requestCounter,
    ),
  );
}
