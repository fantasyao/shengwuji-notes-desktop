import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/theme/app_zoom.dart';

void main() {
  test('默认档位是 100%，档位覆盖上下限', () {
    expect(kDefaultZoomPercent, 100);
    expect(kZoomLevels.first, kMinZoomPercent);
    expect(kZoomLevels.last, kMaxZoomPercent);
    expect(kZoomLevels, contains(kDefaultZoomPercent));
    expect(kZoomLevels, orderedEquals([...kZoomLevels]..sort()));
  });

  test('任意值收拢到最近的档位', () {
    expect(normalizeZoomPercent(100), 100);
    expect(normalizeZoomPercent(95), 90);
    expect(normalizeZoomPercent(96), 100);
    expect(normalizeZoomPercent(120), 125);
    expect(normalizeZoomPercent(130), 125);
    expect(normalizeZoomPercent(148), 150);
  });

  test('超出范围按上下限处理，零和负数回到默认', () {
    expect(normalizeZoomPercent(5), kMinZoomPercent);
    expect(normalizeZoomPercent(999), kMaxZoomPercent);
    expect(normalizeZoomPercent(0), kDefaultZoomPercent);
    expect(normalizeZoomPercent(-20), kDefaultZoomPercent);
  });

  test('快捷键逐档放大、缩小，到顶到底后保持不变', () {
    expect(zoomInPercent(80), 90);
    expect(zoomInPercent(100), 110);
    expect(zoomInPercent(110), 125);
    expect(zoomInPercent(125), 150);
    expect(zoomInPercent(150), 150);

    expect(zoomOutPercent(150), 125);
    expect(zoomOutPercent(125), 110);
    expect(zoomOutPercent(100), 90);
    expect(zoomOutPercent(90), 80);
    expect(zoomOutPercent(80), 80);
  });

  test('缩放比例与标签随档位变化', () {
    expect(zoomScale(100), 1);
    expect(zoomScale(125), 1.25);
    expect(zoomScale(80), 0.8);
    expect(zoomScale(0), 1);
    expect(zoomLabel(150), '150%');
    expect(zoomLabel(95), '90%');
  });
}
