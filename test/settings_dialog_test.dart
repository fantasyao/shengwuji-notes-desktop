import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/data/data_location.dart';
import 'package:shengwuji_desktop/models/hotkey_spec.dart';
import 'package:shengwuji_desktop/pages/settings_dialog.dart';
import 'package:shengwuji_desktop/sync/sync_config.dart';
import 'package:shengwuji_desktop/sync/webdav_request_counter.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';

void main() {
  Future<void> openDialog(
    WidgetTester tester, {
    required Future<String?> Function(HotkeySpec) onApply,
    HotkeySpec current = HotkeySpec.defaultQuick,
    bool rememberQuickPosition = false,
    Future<String?> Function(bool remember)? onApplyQuickPosition,
    AppThemeChoice themeChoice = AppThemeChoice.system,
    Future<String?> Function(AppThemeChoice theme)? onApplyTheme,
    String? currentDataDir,
    Future<String?> Function()? onChooseDataDir,
    SyncConfig syncConfig = const SyncConfig(),
    String currentSyncPassword = '',
    Future<String?> Function(SyncConfig config, String password)? onApplySync,
    Future<String?> Function(SyncConfig config, String password)? onTestSync,
    WebDavRequestCounter? requestCounter,
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
                  rememberQuickPosition: rememberQuickPosition,
                  onApplyQuickPosition: onApplyQuickPosition,
                  themeChoice: themeChoice,
                  onApplyTheme: onApplyTheme,
                  currentDataDir: currentDataDir,
                  onChooseDataDir: onChooseDataDir,
                  syncConfig: syncConfig,
                  currentSyncPassword: currentSyncPassword,
                  onApplySync: onApplySync,
                  onTestSync: onTestSync,
                  requestCounter: requestCounter,
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

  testWidgets('外观选择随保存提交', (tester) async {
    AppThemeChoice? applied;
    await openDialog(
      tester,
      onApply: (_) async => null,
      onApplyTheme: (choice) async {
        applied = choice;
        return null;
      },
    );

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(applied, AppThemeChoice.dark);
    expect(find.byType(SettingsDialog), findsNothing);
  });

  testWidgets('恢复默认把外观改回跟随系统', (tester) async {
    await openDialog(
      tester,
      onApply: (_) async => null,
      themeChoice: AppThemeChoice.dark,
      onApplyTheme: (_) async => null,
    );

    await tester.tap(find.text('恢复默认'));
    await tester.pumpAndSettle();

    final segmented = tester.widget<SegmentedButton<AppThemeChoice>>(
      find.byType(SegmentedButton<AppThemeChoice>),
    );
    expect(segmented.selected, {AppThemeChoice.system});
  });

  testWidgets('记住速记窗位置开关随保存提交', (tester) async {
    bool? applied;
    await openDialog(
      tester,
      onApply: (_) async => null,
      onApplyQuickPosition: (remember) async {
        applied = remember;
        return null;
      },
    );

    expect(find.text('记住速记窗位置'), findsOneWidget);
    expect(find.textContaining('主屏右下角'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(applied, isTrue);
    expect(find.byType(SettingsDialog), findsNothing);
  });

  testWidgets('保存速记窗位置设置失败时弹窗保留', (tester) async {
    await openDialog(
      tester,
      onApply: (_) async => null,
      onApplyQuickPosition: (_) async => '保存速记窗位置设置失败：磁盘只读',
    );

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('保存速记窗位置设置失败：磁盘只读'), findsOneWidget);
    expect(find.byType(SettingsDialog), findsOneWidget);
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

    expect(
      find.text(r'C:\Users\demo\AppData\Roaming\Shengwuji'),
      findsOneWidget,
    );

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

  testWidgets('测试连接并保存 WebDAV 配置', (tester) async {
    SyncConfig? saved;
    String? savedPassword;
    SyncConfig? tested;
    await openDialog(
      tester,
      onApply: (_) async => null,
      syncConfig: const SyncConfig(
        baseUrl: 'https://dav.example.com',
        username: 'old-user',
        remoteDir: '/shengwuji_sync',
      ),
      currentSyncPassword: 'old-pass',
      onApplySync: (config, password) async {
        saved = config;
        savedPassword = password;
        return null;
      },
      onTestSync: (config, password) async {
        tested = config;
        expect(password, 'old-pass');
        return null;
      },
    );

    expect(find.text('WebDAV 同步'), findsOneWidget);
    expect(find.text('https://dav.example.com'), findsOneWidget);

    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(tested?.username, 'old-user');
    expect(find.text('连接成功，远端目录可用'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(1), 'new-user');
    await tester.enterText(find.byType(TextField).at(2), 'new-pass');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(saved?.username, 'new-user');
    expect(saved?.baseUrl, 'https://dav.example.com');
    expect(savedPassword, 'new-pass');
    expect(find.byType(SettingsDialog), findsNothing);
  });

  testWidgets('同步录音开关随 WebDAV 配置一起保存', (tester) async {
    SyncConfig? saved;
    await openDialog(
      tester,
      onApply: (_) async => null,
      syncConfig: const SyncConfig(
        baseUrl: 'https://dav.example.com',
        username: 'demo',
      ),
      onApplySync: (config, password) async {
        saved = config;
        return null;
      },
    );

    expect(find.text('同步录音'), findsOneWidget);
    expect(find.textContaining('关闭时只保留'), findsOneWidget);

    await tester.ensureVisible(find.byType(Switch).at(2));
    await tester.tap(find.byType(Switch).at(2));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(saved?.audioEnabled, isTrue);
    expect(find.byType(SettingsDialog), findsNothing);
  });

  testWidgets('自动同步间隔随 WebDAV 配置一起保存', (tester) async {
    SyncConfig? saved;
    await openDialog(
      tester,
      onApply: (_) async => null,
      syncConfig: const SyncConfig(
        baseUrl: 'https://dav.example.com',
        username: 'demo',
        autoSyncMinutes: 15,
      ),
      onApplySync: (config, password) async {
        saved = config;
        return null;
      },
    );

    expect(find.text('自动检查云端'), findsOneWidget);
    final dropdown = find.byType(DropdownButton<int>);
    expect(dropdown, findsOneWidget);
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 分钟').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(saved?.autoSyncMinutes, 5);
    expect(find.byType(SettingsDialog), findsNothing);
  });

  testWidgets('展示本机最近 30 分钟的 WebDAV 请求数', (tester) async {
    final counter = WebDavRequestCounter(
      clock: () => DateTime(2026, 10, 25, 10),
    );
    addTearDown(counter.dispose);
    counter.record();
    counter.record();

    await openDialog(
      tester,
      onApply: (_) async => null,
      syncConfig: const SyncConfig(
        baseUrl: 'https://dav.example.com',
        username: 'demo',
      ),
      onApplySync: (config, password) async => null,
      requestCounter: counter,
    );

    expect(find.textContaining('这台电脑发出 2 次请求'), findsOneWidget);
    expect(find.textContaining('还剩 598 次'), findsOneWidget);
    expect(find.textContaining('只统计这台电脑'), findsOneWidget);

    counter.dispose();
  });

  testWidgets('启用同步但缺账号时不保存', (tester) async {
    var applied = false;
    await openDialog(
      tester,
      onApply: (_) async => null,
      syncConfig: const SyncConfig(baseUrl: 'https://dav.example.com'),
      onApplySync: (config, password) async {
        applied = true;
        return null;
      },
    );

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('启用同步需要填写 WebDAV 地址与账号'), findsOneWidget);
    expect(applied, isFalse);
    expect(find.byType(SettingsDialog), findsOneWidget);
  });

  testWidgets('测试连接失败时展示原因', (tester) async {
    await openDialog(
      tester,
      onApply: (_) async => null,
      syncConfig: const SyncConfig(
        baseUrl: 'https://dav.example.com',
        username: 'demo',
      ),
      onApplySync: (config, password) async => null,
      onTestSync: (config, password) async => '账号或应用密码不正确',
    );

    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    expect(find.text('账号或应用密码不正确'), findsOneWidget);
    expect(find.text('连接成功，远端目录可用'), findsNothing);
  });
}
