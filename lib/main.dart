import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'data/note_store.dart';
import 'data/settings_store.dart';
import 'state/notes_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1180, 780),
    minimumSize: Size(880, 600),
    center: true,
    title: '声物记电脑版',
  );
  unawaited(
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    }),
  );

  final store = await NoteStore.openDefault();
  final controller = NotesController(store);
  await controller.load();
  final settingsStore = SettingsStore(rootDir: store.rootDir);
  final settings = await settingsStore.load();

  runApp(
    ShengwujiApp(
      controller: controller,
      settingsStore: settingsStore,
      initialSettings: settings,
    ),
  );
}
