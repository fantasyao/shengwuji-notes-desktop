import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/models/hotkey_spec.dart';

void main() {
  test('默认快捷键是 Ctrl + Alt + Space', () {
    expect(HotkeySpec.defaultQuick.label, 'Ctrl + Alt + Space');
    expect(HotkeySpec.defaultQuick.usbHidUsage, 0x0007002C);
    expect(HotkeySpec.defaultQuick.toPhysicalKey(), PhysicalKeyboardKey.space);
  });

  test('JSON 往返保留按键与修饰键', () {
    const spec = HotkeySpec(
      usbHidUsage: 0x0007000E,
      keyLabel: 'K',
      control: true,
      shift: true,
    );
    final restored = HotkeySpec.fromJson(spec.toJson());
    expect(restored.label, 'Ctrl + Shift + K');
    expect(restored.toPhysicalKey(), PhysicalKeyboardKey.keyK);
  });

  test('缺少 Ctrl/Alt/Win 的配置视为无效', () {
    expect(
      () => HotkeySpec.fromJson({
        'usb_hid_usage': 0x0007000E,
        'key_label': 'K',
        'shift': true,
      }),
      throwsFormatException,
    );
  });

  test('未知按键在读取时抛格式错误', () {
    expect(
      () => HotkeySpec.fromJson({
        'usb_hid_usage': 0x00FFFFFF,
        'key_label': '未知',
        'control': true,
      }),
      throwsFormatException,
    );
  });

  test('标签覆盖常见功能键', () {
    expect(HotkeySpec.labelFor(LogicalKeyboardKey.space), 'Space');
    expect(HotkeySpec.labelFor(LogicalKeyboardKey.escape), 'Esc');
    expect(HotkeySpec.labelFor(LogicalKeyboardKey.arrowUp), '↑');
    expect(HotkeySpec.labelFor(LogicalKeyboardKey.f1), 'F1');
  });
}
