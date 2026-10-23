import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/data/data_location.dart';
import 'package:shengwuji_desktop/models/hotkey_spec.dart';
import 'package:shengwuji_desktop/pages/settings_dialog.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';

void main() {
  Future<void> openDialog(
    WidgetTester tester, {
    required Future<String?> Function(HotkeySpec) onApply,
    HotkeySpec current = HotkeySpec.defaultQuick,
    String? currentDataDir,
    Future<String?> Function()? onChooseDataDir,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => SettingsDialog(
                  currentHotkey: current,
                  onApply: onApply,
                  currentDataDir: currentDataDir,
                  onChooseDataDir: onChooseDataDir,
                ),
              ),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
  }

  Future<void> recordCombo(
    WidgetTester tester,
    List<LogicalKeyboardKey> keys,
  ) async {
    for (final key in keys) {
      await tester.sendKeyDownEvent(key);
    }
    await tester.sendKeyUpEvent(keys.last);
    for (final key in keys.take(keys.length - 1).toList().reversed) {
      await tester.sendKeyUpEvent(key);
    }
    await tester.pumpAndSettle();
  }

  testWidgets('展示当前快捷键并支持录制新组合', (tester) async {
    HotkeySpec? applied;
    await openDialog(
      tester,
      onApply: (spec) async {
        applied = spec;
        return null;
      },
    );

    expect(find.text('Ctrl + Alt + Space'), findsOneWidget);

    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    expect(find.text('请按下新的组合键…'), findsOneWidget);

    await recordCombo(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.keyK,
    ]);

    expect(find.text('Ctrl + Alt + K'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(applied?.label, 'Ctrl + Alt + K');
    expect(applied?.usbHidUsage, PhysicalKeyboardKey.keyK.usbHidUsage);
    expect(find.text('打开设置'), findsOneWidget);
  });

  testWidgets('没有 Ctrl/Alt/Win 时给出提示且不保存', (tester) async {
    await openDialog(tester, onApply: (_) async => null);

    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    await recordCombo(tester, [LogicalKeyboardKey.keyK]);

    expect(find.text('至少包含 Ctrl、Alt 或 Win 之一'), findsOneWidget);
    expect(find.text('请按下新的组合键…'), findsOneWidget);
  });

  testWidgets('录制中按 Esc 取消录制', (tester) async {
    await openDialog(tester, onApply: (_) async => null);

    await tester.tap(find.text('修改'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('Ctrl + Alt + Space'), findsOneWidget);
    expect(find.text('请按下新的组合键…'), findsNothing);
  });

  testWidgets('应用失败时弹窗保留并展示原因', (tester) async {
    await openDialog(tester, onApply: (_) async => '注册失败，换一个组合试试');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('注册失败，换一个组合试试'), findsWidgets);
    expect(find.byType(SettingsDialog), findsOneWidget);
  });

  testWidgets('展示数据目录并可更改', (tester) async {
    var calls = 0;
    await openDialog(
      tester,
      onApply: (_) async => null,
      currentDataDir: r'C:\Users\demo\AppData\Roaming\Shengwuji',
      onChooseDataDir: () async {
        calls++;
        return r'D:\声物记笔记';
      },
    );

    expect(find.text(r'C:\Users\demo\AppData\Roaming\Shengwuji'), findsOneWidget);

    await tester.ensureVisible(find.text('更改…'));
    await tester.tap(find.text('更改…'));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text(r'D:\声物记笔记'), findsOneWidget);
    expect(find.byType(SettingsDialog), findsOneWidget);
  });

  testWidgets('更改数据目录失败时展示原因', (tester) async {
    await openDialog(
      tester,
      onApply: (_) async => null,
      currentDataDir: r'C:\data',
      onChooseDataDir: () async =>
          throw const DataDirectoryException('无法使用这个文件夹：权限不足'),
    );

    await tester.ensureVisible(find.text('更改…'));
    await tester.tap(find.text('更改…'));
    await tester.pumpAndSettle();

    expect(find.text('无法使用这个文件夹：权限不足'), findsOneWidget);
    expect(find.byType(SettingsDialog), findsOneWidget);
  });
}
