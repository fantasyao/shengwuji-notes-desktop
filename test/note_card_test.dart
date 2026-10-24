import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/data/note_store.dart';
import 'package:shengwuji_desktop/models/note.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';
import 'package:shengwuji_desktop/widgets/note_card.dart';

void main() {
  late Directory dir;
  late NoteStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('shengwuji_card_test_');
    store = NoteStore(rootDir: dir);
  });

  tearDown(() async {
    await store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pumpCard(
    WidgetTester tester,
    Note note, {
    VoidCallback? onCopy,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: NoteCard(
                note: note,
                store: store,
                onOpen: () {},
                onCopy: onCopy ?? () {},
                onDelete: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<TestGesture> hoverCard(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(NoteCard)));
    await tester.pumpAndSettle();
    return gesture;
  }

  testWidgets('已下载的录音显示时长，未下载时标注待下载', (tester) async {
    final now = DateTime(2026, 10, 23, 18, 7);
    await pumpCard(
      tester,
      Note(
        uuid: 'n1',
        content: '',
        createdAt: now,
        updatedAt: now,
        audios: const [
          NoteAudio(
            uuid: 'a1',
            path: 'blobs/aa/aa.wav',
            fileName: 'voice.wav',
            durationMs: 8000,
          ),
        ],
      ),
    );

    expect(find.text('录音笔记'), findsOneWidget);
    expect(find.text('录音 0:08'), findsOneWidget);
    expect(find.textContaining('待下载'), findsNothing);

    await pumpCard(
      tester,
      Note(
        uuid: 'n2',
        content: '',
        createdAt: now,
        updatedAt: now,
        audios: const [
          NoteAudio(uuid: 'a2', fileName: 'cloud.wav', durationMs: 9000),
          NoteAudio(uuid: 'a3', fileName: 'cloud2.wav', durationMs: 4000),
        ],
      ),
    );

    expect(find.text('录音 2 段 · 待下载'), findsOneWidget);
  });

  testWidgets('悬停出现复制按钮，比删除按钮略大且点击可复制', (tester) async {
    var copied = 0;
    final now = DateTime(2026, 10, 23, 18, 7);
    await pumpCard(
      tester,
      Note(uuid: 'n1', content: '标题\n正文内容', createdAt: now, updatedAt: now),
      onCopy: () => copied++,
    );

    await hoverCard(tester);

    final copy = find.byTooltip('复制正文');
    final delete = find.byTooltip('移入回收站');
    expect(copy, findsOneWidget);
    expect(delete, findsOneWidget);
    expect(tester.getSize(copy).width, greaterThan(tester.getSize(delete).width));

    await tester.tap(copy);
    await tester.pump();
    expect(copied, 1);
  });
}
