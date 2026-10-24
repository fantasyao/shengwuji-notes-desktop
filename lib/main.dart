import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'data/data_location.dart';
import 'data/note_store.dart';
import 'data/settings_store.dart';
import 'state/notes_controller.dart';
import 'sync/sync_service.dart';
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
  );

  await Future.wait([controller.load(), syncService.initialize()]);

  runApp(
    ShengwujiApp(
      controller: controller,
      settingsStore: settingsStore,
      initialSettings: settings,
      syncService: syncService,
      passwordStore: passwordStore,
    ),
  );
}
