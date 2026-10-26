import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/widgets/zoom_shortcuts.dart';

void main() {
  Future<void> pumpShortcuts(
    WidgetTester tester, {
    required VoidCallback onZoomIn,
    required VoidCallback onZoomOut,
    required VoidCallback onReset,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ZoomShortcuts(
            onZoomIn: onZoomIn,
            onZoomOut: onZoomOut,
            onReset: onReset,
            child: const Focus(autofocus: true, child: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pressWithControl(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('Ctrl+= 放大，Ctrl+- 缩小，Ctrl+0 回到默认', (tester) async {
    var zoomsIn = 0;
    var zoomsOut = 0;
    var resets = 0;
    await pumpShortcuts(
      tester,
      onZoomIn: () => zoomsIn++,
      onZoomOut: () => zoomsOut++,
      onReset: () => resets++,
    );

    await pressWithControl(tester, LogicalKeyboardKey.equal);
    expect(zoomsIn, 1);

    await pressWithControl(tester, LogicalKeyboardKey.minus);
    expect(zoomsOut, 1);

    await pressWithControl(tester, LogicalKeyboardKey.digit0);
    expect(resets, 1);
  });

  testWidgets('兼容 Shift+= 与数字键盘的加减号', (tester) async {
    var zoomsIn = 0;
    var zoomsOut = 0;
    await pumpShortcuts(
      tester,
      onZoomIn: () => zoomsIn++,
      onZoomOut: () => zoomsOut++,
      onReset: () {},
    );

    await pressWithControl(
      tester,
      LogicalKeyboardKey.equal,
      shift: true,
    );
    await pressWithControl(tester, LogicalKeyboardKey.numpadAdd);
    expect(zoomsIn, 2);

    await pressWithControl(tester, LogicalKeyboardKey.numpadSubtract);
    expect(zoomsOut, 1);
  });

  testWidgets('没有 Ctrl 时普通按键不触发缩放', (tester) async {
    var calls = 0;
    await pumpShortcuts(
      tester,
      onZoomIn: () => calls++,
      onZoomOut: () => calls++,
      onReset: () => calls++,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.pumpAndSettle();

    expect(calls, 0);
  });
}
