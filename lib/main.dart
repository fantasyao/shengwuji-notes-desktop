import 'package:flutter/material.dart';

import 'app.dart';
import 'data/note_store.dart';
import 'state/notes_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await NoteStore.openDefault();
  final controller = NotesController(store);
  runApp(ShengwujiApp(controller: controller));
}
