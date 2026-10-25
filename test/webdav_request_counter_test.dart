import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shengwuji_desktop/sync/webdav_request_counter.dart';

void main() {
  test('按滚动 30 分钟窗口计数', () {
    var now = DateTime(2026, 10, 25, 10);
    final counter = WebDavRequestCounter(clock: () => now);
    addTearDown(counter.dispose);

    counter.record();
    counter.record();
    expect(counter.recentCount, 2);

    now = now.add(const Duration(minutes: 29, seconds: 59));
    expect(counter.recentCount, 2);

    now = now.add(const Duration(seconds: 2));
    expect(counter.recentCount, 0);
  });

  test('剩余额度按上限估算且不会为负', () {
    var now = DateTime(2026, 10, 25, 10);
    final counter = WebDavRequestCounter(limit: 3, clock: () => now);
    addTearDown(counter.dispose);

    counter.record();
    counter.record();
    expect(counter.remaining, 1);

    counter.record();
    counter.record();
    expect(counter.remaining, 0);
  });

  test('计数落盘后可在下次启动恢复，并清掉过期分钟桶', () async {
    final dir = Directory.systemTemp.createTempSync('shengwuji_budget_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final file = File(p.join(dir.path, 'webdav_requests.json'));
    var now = DateTime(2026, 10, 25, 10);

    final first = WebDavRequestCounter(clock: () => now, storageFile: file);
    first.record();
    first.record();
    first.record();
    await first.flush();

    final decoded = jsonDecode(await file.readAsString());
    expect(decoded, isA<Map>());
    expect((decoded as Map)['buckets'], isNotEmpty);

    final second = WebDavRequestCounter(clock: () => now, storageFile: file);
    await second.load();
    expect(second.recentCount, 3);

    final third = WebDavRequestCounter(
      clock: () => now.add(const Duration(minutes: 31)),
      storageFile: file,
    );
    await third.load();
    expect(third.recentCount, 0);

    first.dispose();
    second.dispose();
    third.dispose();
  });

  test('计数文件损坏时按空窗口处理', () async {
    final dir = Directory.systemTemp.createTempSync('shengwuji_budget_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final file = File(p.join(dir.path, 'webdav_requests.json'));
    await file.writeAsString('not json');

    final counter = WebDavRequestCounter(
      clock: () => DateTime(2026, 10, 25, 10),
      storageFile: file,
    );
    await counter.load();

    expect(counter.recentCount, 0);
    counter.dispose();
  });
}
