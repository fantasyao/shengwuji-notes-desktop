import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';
import 'package:shengwuji_desktop/widgets/zoom_host.dart';

void main() {
  const contentKey = ValueKey('zoom-content');

  Future<void> pumpZoom(
    WidgetTester tester, {
    required int percent,
    required Size size,
    required Widget child,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ZoomHost(percent: percent, child: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('放大时子树按缩小后的逻辑尺寸排版，点击仍能命中', (tester) async {
    Size? logical;
    Size? media;
    var taps = 0;
    await pumpZoom(
      tester,
      percent: 150,
      size: const Size(600, 450),
      child: GestureDetector(
        key: contentKey,
        behavior: HitTestBehavior.opaque,
        onTap: () => taps++,
        child: LayoutBuilder(
          builder: (context, constraints) {
            logical = constraints.biggest;
            media = MediaQuery.sizeOf(context);
            return const SizedBox.expand();
          },
        ),
      ),
    );

    expect(logical, const Size(400, 300));
    expect(media, const Size(400, 300));
    expect(tester.getSize(find.byKey(contentKey)), const Size(400, 300));

    await tester.tapAt(const Offset(590, 440));
    expect(taps, 1);
  });

  testWidgets('缩小时子树比窗口大，窗口内任意位置仍可交互', (tester) async {
    Size? logical;
    var taps = 0;
    await pumpZoom(
      tester,
      percent: 80,
      size: const Size(600, 450),
      child: GestureDetector(
        key: contentKey,
        behavior: HitTestBehavior.opaque,
        onTap: () => taps++,
        child: LayoutBuilder(
          builder: (context, constraints) {
            logical = constraints.biggest;
            return const SizedBox.expand();
          },
        ),
      ),
    );

    expect(logical, const Size(750, 562.5));
    expect(tester.getSize(find.byKey(contentKey)), const Size(750, 562.5));

    await tester.tapAt(const Offset(10, 10));
    await tester.tapAt(const Offset(590, 440));
    expect(taps, 2);
  });

  testWidgets('100% 时尺寸不变，切换档位不会重建子树', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 450));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Widget build(int percent) {
      return MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ZoomHost(percent: percent, child: const _StatefulTally()),
        ),
      );
    }

    await tester.pumpWidget(build(100));
    await tester.pumpAndSettle();
    expect(find.text('点击 0 次'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(contentKey)),
      const Size(600, 450),
    );

    await tester.tap(find.byKey(contentKey));
    await tester.pumpAndSettle();
    expect(find.text('点击 1 次'), findsOneWidget);

    await tester.pumpWidget(build(150));
    await tester.pumpAndSettle();
    // 子树还是同一个 State，没有被 ZoomHost 的包装层换掉重建。
    expect(find.text('点击 1 次'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(contentKey)),
      const Size(400, 300),
    );
  });

  testWidgets('缩放后弹窗按逻辑尺寸计算大小，不会被窗口裁掉', (tester) async {
    await tester.binding.setSurfaceSize(const Size(880, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var saved = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => ZoomHost(
          percent: 150,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('测试弹窗'),
                  content: const SizedBox(
                    width: 700,
                    height: 500,
                    child: Text('内容'),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        saved = true;
                        Navigator.of(dialogContext).pop();
                      },
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('测试弹窗'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(saved, isTrue);
    expect(find.text('测试弹窗'), findsNothing);
  });
}

class _StatefulTally extends StatefulWidget {
  const _StatefulTally();

  @override
  State<_StatefulTally> createState() => _StatefulTallyState();
}

class _StatefulTallyState extends State<_StatefulTally> {
  int _taps = 0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('zoom-content'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _taps++),
        child: Center(child: Text('点击 $_taps 次')),
      ),
    );
  }
}
