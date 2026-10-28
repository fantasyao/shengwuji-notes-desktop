import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/window/tray_setup.dart';
import 'package:tray_manager/tray_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('启动托盘依次设置图标、悬停提示与右键菜单', () async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('tray_manager'), (
      call,
    ) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('tray_manager'),
        null,
      ),
    );

    await setUpTray(
      menu: Menu(
        items: [MenuItem(key: 'quit', label: '退出')],
      ),
    );

    // tray_manager 0.5.3 加图标时会把未初始化的 szTip 一起注册，
    // 提示必须紧跟在 setIcon 之后补上，悬停才不会是乱码。
    expect(calls.map((call) => call.method).toList(), [
      'setIcon',
      'setToolTip',
      'setContextMenu',
    ]);
    expect(calls.first.arguments['iconPath'] as String, endsWith(trayIconPath));
    expect(calls[1].arguments['toolTip'], '声物记电脑版');
    expect(
      (calls[1].arguments['toolTip'] as String).trim(),
      isNotEmpty,
      reason: '空提示会退回插件带出来的乱码',
    );
  });
}
