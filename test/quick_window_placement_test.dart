import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/window/quick_window_placement.dart';

void main() {
  const size = Size(460, 400);
  const margin = 24.0;
  const primary = Rect.fromLTWH(0, 0, 1920, 1040);

  Rect resolve(
    Offset? remembered, {
    List<Rect> displayAreas = const [primary],
  }) {
    return resolveQuickBounds(
      size: size,
      margin: margin,
      primaryArea: primary,
      displayAreas: displayAreas,
      remembered: remembered,
    );
  }

  test('没记过位置时落在主屏右下角', () {
    expect(resolve(null), const Rect.fromLTWH(1436, 616, 460, 400));
  });

  test('记住的位置在可用区内时原样使用', () {
    const remembered = Offset(120, 200);
    final bounds = resolve(remembered);
    expect(bounds.topLeft, remembered);
    expect(bounds.size, size);
  });

  test('副屏上的位置可以恢复', () {
    const secondary = Rect.fromLTWH(1920, 0, 1080, 1880);
    const remembered = Offset(2400, 300);
    final bounds = resolve(remembered, displayAreas: [primary, secondary]);
    expect(bounds.topLeft, remembered);
  });

  test('副屏在左侧（负坐标）时可以恢复', () {
    const left = Rect.fromLTWH(-1080, 0, 1080, 1920);
    const remembered = Offset(-900, 400);
    final bounds = resolve(remembered, displayAreas: [left, primary]);
    expect(bounds.topLeft, remembered);
  });

  test('副屏拔掉后回落到主屏右下角', () {
    const remembered = Offset(2400, 300);
    expect(resolve(remembered), const Rect.fromLTWH(1436, 616, 460, 400));
  });

  test('位置只有一部分在屏幕内时夹回屏幕里', () {
    const remembered = Offset(1800, 900);
    final bounds = resolve(remembered);
    expect(bounds, const Rect.fromLTWH(1460, 640, 460, 400));
  });

  test('屏幕比窗口还小时退到屏幕起点', () {
    const tiny = Rect.fromLTWH(0, 0, 300, 200);
    final bounds = resolve(
      const Offset(10, 10),
      displayAreas: const [tiny],
    );
    expect(bounds.topLeft, Offset.zero);
    expect(bounds.size, size);
  });
}
