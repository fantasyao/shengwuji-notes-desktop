import 'package:flutter/material.dart';

import '../pages/notes_page.dart';
import '../state/notes_controller.dart';
import '../theme/app_theme.dart';

class ShengwujiApp extends StatelessWidget {
  const ShengwujiApp({super.key, required this.controller});

  final NotesController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '声物记电脑版',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: NotesHomePage(controller: controller),
    );
  }
}
