import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/pages/notes_page.dart';
import 'package:shengwuji_desktop/state/notes_controller.dart';
import 'package:shengwuji_desktop/sync/password_store.dart';
import 'package:shengwuji_desktop/sync/sync_config.dart';
import 'package:shengwuji_desktop/sync/sync_service.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';

import 'support/fake_cloud_storage.dart';
import 'support/memory_note_store.dart';

void main() {
  late Directory dir;
  late NotesController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('shengwuji_home_sync_test_');
    controller = NotesController(MemoryNoteStore(rootDir: dir));
    await controller.load();
  });

  tearDown(() async {
    controller.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  SyncService buildService(SyncConfig config) {
    return SyncService(
      store: controller.store,
      passwordStore: MemoryPasswordStore('secret'),
      onSynced: () async {},
      config: config,
      deviceId: 'desktop-test',
      clientFactory: (_, _) => FakeCloudStorage(),
    );
  }

  Future<void> pumpPage(
    WidgetTester tester,
    SyncService service, {
    VoidCallback? onOpenSettings,
    Size size = const Size(1200, 800),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: NotesHomePage(
          controller: controller,
          syncService: service,
          onOpenSettings: onOpenSettings,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('未配置 WebDAV 时显示离线图标并引导到设置', (tester) async {
    final service = buildService(const SyncConfig());
    addTearDown(service.dispose);

    var settingsOpened = 0;
    await pumpPage(
      tester,
      service,
      onOpenSettings: () => settingsOpened++,
    );

    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
    expect(find.text('电脑版 · 本地笔记'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.cloud_off_rounded));
    expect(settingsOpened, 1);
  });

  testWidgets('手动同步失败时提示原因并把状态标为错误', (tester) async {
    final service = buildService(
      const SyncConfig(
        baseUrl: 'https://dav.example.com',
        username: 'demo',
      ),
    );
    addTearDown(service.dispose);

    await pumpPage(tester, service);
    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.cloud_done_outlined));
    await tester.pumpAndSettle();

    expect(service.status, SyncStatus.error);
    expect(find.textContaining('当前数据目录处于兼容模式'), findsOneWidget);
    expect(find.byIcon(Icons.sync_problem_rounded), findsOneWidget);
    expect(find.text('电脑版 · 同步失败'), findsOneWidget);
  });

  testWidgets('缩放后逻辑宽度变窄时头部仍不溢出', (tester) async {
    final service = buildService(const SyncConfig());
    addTearDown(service.dispose);

    await pumpPage(tester, service, size: const Size(586, 400));
    expect(tester.takeException(), isNull);
    expect(find.text('电脑版 · 本地笔记'), findsNothing);
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
  });
}
