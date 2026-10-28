import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/widgets/window_entrance.dart';

void main() {
  Widget build(double width) {
    return MaterialApp(
      home: WindowEntrance(
        key: const Key('entrance'),
        child: SizedBox(width: width, height: 100),
      ),
    );
  }

  Finder entranceFinder() => find.byKey(const Key('entrance'));
  Finder opacityFinder() =>
      find.descendant(of: entranceFinder(), matching: find.byType(Opacity));
  Finder transformFinder() =>
      find.descendant(of: entranceFinder(), matching: find.byType(Transform));

  testWidgets('首次挂载从透明上浮到完全显示', (tester) async {
    await tester.pumpWidget(build(100));

    expect(tester.widget<Opacity>(opacityFinder()).opacity, 0);
    final start = tester.widget<Transform>(transformFinder()).transform;
    expect(start.getTranslation().y, WindowEntrance.rise);

    await tester.pump(WindowEntrance.duration ~/ 2);
    final midway = tester.widget<Opacity>(opacityFinder()).opacity;
    expect(midway, greaterThan(0));
    expect(midway, lessThan(1));

    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(opacityFinder()).opacity, 1);
    expect(
      tester.widget<Transform>(transformFinder()).transform.getTranslation().y,
      0,
    );
  });

  testWidgets('同一页面重建不会重播入场动画', (tester) async {
    await tester.pumpWidget(build(100));
    await tester.pumpAndSettle();

    await tester.pumpWidget(build(120));
    await tester.pump();
    expect(tester.widget<Opacity>(opacityFinder()).opacity, 1);
    expect(
      tester.widget<Transform>(transformFinder()).transform.getTranslation().y,
      0,
    );
  });
}
