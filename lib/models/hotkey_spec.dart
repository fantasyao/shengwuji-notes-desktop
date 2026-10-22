import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

/// 一个可持久化的系统级快捷键组合。
///
/// 主键用 HID usage code 保存，避免依赖本地化后的按键显示名；
/// [keyLabel] 只用于界面展示。
class HotkeySpec {
  const HotkeySpec({
    required this.usbHidUsage,
    required this.keyLabel,
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });

  static const HotkeySpec defaultQuick = HotkeySpec(
    usbHidUsage: 0x0007002C,
    keyLabel: 'Space',
    control: true,
    alt: true,
  );

  final int usbHidUsage;
  final String keyLabel;
  final bool control;
  final bool alt;
  final bool shift;
  final bool meta;

  /// 至少要有 Ctrl / Alt / Win 之一，避免单键或 Shift+字母抢占全局。
  bool get isGlobalSafe => control || alt || meta;

  String get label {
    final parts = <String>[
      if (control) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) 'Win',
      keyLabel,
    ];
    return parts.join(' + ');
  }

  Map<String, dynamic> toJson() => {
    'usb_hid_usage': usbHidUsage,
    'key_label': keyLabel,
    'control': control,
    'alt': alt,
    'shift': shift,
    'meta': meta,
  };

  factory HotkeySpec.fromJson(Map<String, dynamic> json) {
    final usage = json['usb_hid_usage'];
    final label = json['key_label'];
    if (usage is! int || label is! String || label.isEmpty) {
      throw const FormatException('快捷键字段不完整');
    }
    final spec = HotkeySpec(
      usbHidUsage: usage,
      keyLabel: label,
      control: json['control'] == true,
      alt: json['alt'] == true,
      shift: json['shift'] == true,
      meta: json['meta'] == true,
    );
    if (!spec.isGlobalSafe) {
      throw const FormatException('快捷键至少需要 Ctrl/Alt/Win 之一');
    }
    if (spec.toPhysicalKey() == null) {
      throw const FormatException('未知的按键');
    }
    return spec;
  }

  PhysicalKeyboardKey? toPhysicalKey() {
    return PhysicalKeyboardKey.findKeyByCode(usbHidUsage);
  }

  HotKey toHotKey() {
    return HotKey(
      key: toPhysicalKey() ?? PhysicalKeyboardKey.space,
      modifiers: [
        if (control) HotKeyModifier.control,
        if (alt) HotKeyModifier.alt,
        if (shift) HotKeyModifier.shift,
        if (meta) HotKeyModifier.meta,
      ],
      scope: HotKeyScope.system,
    );
  }

  static String labelFor(LogicalKeyboardKey key) {
    final names = <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.space: 'Space',
      LogicalKeyboardKey.enter: 'Enter',
      LogicalKeyboardKey.numpadEnter: 'Enter',
      LogicalKeyboardKey.escape: 'Esc',
      LogicalKeyboardKey.tab: 'Tab',
      LogicalKeyboardKey.backspace: 'Backspace',
      LogicalKeyboardKey.delete: 'Delete',
      LogicalKeyboardKey.insert: 'Insert',
      LogicalKeyboardKey.home: 'Home',
      LogicalKeyboardKey.end: 'End',
      LogicalKeyboardKey.pageUp: 'PageUp',
      LogicalKeyboardKey.pageDown: 'PageDown',
      LogicalKeyboardKey.arrowUp: '↑',
      LogicalKeyboardKey.arrowDown: '↓',
      LogicalKeyboardKey.arrowLeft: '←',
      LogicalKeyboardKey.arrowRight: '→',
    };
    final named = names[key];
    if (named != null) return named;
    if (key.keyLabel.isNotEmpty) return key.keyLabel;
    return key.debugName ?? '按键';
  }
}
