import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shengwuji_desktop/data/note_store.dart';
import 'package:shengwuji_desktop/models/note.dart';
import 'package:shengwuji_desktop/state/notes_controller.dart';
import 'package:shengwuji_desktop/sync/password_store.dart';
import 'package:shengwuji_desktop/sync/sync_codec.dart';
import 'package:shengwuji_desktop/sync/sync_config.dart';
import 'package:shengwuji_desktop/sync/sync_service.dart';

import 'support/fake_cloud_storage.dart';

Future<void> waitFor(bool Function() predicate) async {
  for (var i = 0; i < 300; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('等待条件超时');
}

void main() {
  late Directory dir;
  late NoteStore store;
  late NotesController controller;
  late FakeCloudStorage cloud;
  late SyncService service;
  late DateTime now;

  const defaultConfig = SyncConfig(
    baseUrl: 'https://dav.example.com',
    username: 'demo',
    remoteDir: '/shengwuji_sync',
  );

  SyncService buildService({
    required NoteStore targetStore,
    required NotesController targetController,
    String device = 'device-a',
    Duration debounce = const Duration(seconds: 25),
    SyncConfig syncConfig = defaultConfig,
  }) {
    return SyncService(
      store: targetStore,
      passwordStore: MemoryPasswordStore('secret'),
      onSynced: targetController.reloadAfterSync,
      config: syncConfig,
      deviceId: device,
      clientFactory: (_, _) => cloud,
      clock: () => now,
      debounceDelay: debounce,
    );
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('shengwuji_sync_test_');
    store = NoteStore(rootDir: dir);
    controller = NotesController(store);
    await controller.load();
    cloud = FakeCloudStorage();
    now = DateTime(2026, 10, 23, 10);
    service = buildService(targetStore: store, targetController: controller);
  });

  tearDown(() async {
    service.dispose();
    controller.dispose();
    await store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Note note(
    String uuid,
    String content, {
    DateTime? created,
    DateTime? updated,
    List<String> images = const [],
  }) {
    final createdAt = created ?? DateTime(2020, 1, 1);
    return Note(
      uuid: uuid,
      content: content,
      images: images,
      createdAt: createdAt,
      updatedAt: updated ?? createdAt,
    );
  }

  Map<String, dynamic> readJson(String path) {
    return jsonDecode(cloud.text(path)!) as Map<String, dynamic>;
  }

  List<dynamic> readList(String path) {
    return jsonDecode(cloud.text(path)!) as List<dynamic>;
  }

  test('首次同步：本地写入 v1 投影与 v2，同时吸收手机新增', () async {
    await controller.upsert(note('desktop-1', '桌面笔记', created: now));
    cloud.putText(
      'diary.json',
      jsonEncode([
        {
          'uuid': 'phone-1',
          'content': '手机笔记',
          'created_at': SyncCodec.formatLocalNoZone(
            DateTime(2026, 10, 22, 9).millisecondsSinceEpoch,
          ),
        },
      ]),
    );

    final result = await service.sync(manual: true);

    expect(result, isNotNull, reason: service.lastError);
    expect(controller.notes, hasLength(2));
    expect(
      controller.notes.map((item) => item.uuid),
      containsAll(['desktop-1', 'phone-1']),
    );

    final diary = readList('diary.json');
    expect(diary, hasLength(2));
    final row = diary.firstWhere((item) => item['uuid'] == 'desktop-1');
    expect(row['created_at'], endsWith('.000'));
    expect((row['created_at'] as String).endsWith('Z'), isFalse);
    expect(row.containsKey('updated_at'), isFalse);
    expect(row.containsKey('archived'), isFalse);

    final manifest = readJson('manifest.json');
    expect(manifest['lock'], isNull);
    expect(manifest['device_id'], 'device-a');
    expect((manifest['counts'] as Map)['notes'], 2);

    final v2 = readJson('v2/notes.json');
    expect((v2['notes'] as List), hasLength(2));
    expect(readJson('v2/manifest.json')['protocol_version'], 2);
    expect(readJson('v2/tombstones.json')['tombstones'], isEmpty);
    expect(
      cloud.files.keys.where((key) => key.startsWith('v2/assets/')),
      isEmpty,
    );
  });

  test('远端 v2 修改按基线覆盖本地，不会误报冲突', () async {
    await controller.upsert(note('n1', '第一版', created: now));
    expect(
      await service.sync(manual: true),
      isNotNull,
      reason: service.lastError,
    );

    now = now.add(const Duration(minutes: 2));
    final v2 = readJson('v2/notes.json');
    final rows = v2['notes'] as List<dynamic>;
    rows.first['content'] = '远端改过';
    rows.first['updated_at'] = SyncCodec.formatUtc(now.millisecondsSinceEpoch);
    cloud.putText('v2/notes.json', jsonEncode(v2));

    final result = await service.sync(manual: true);

    expect(result, isNotNull, reason: service.lastError);
    expect(result!.stats.conflictCopies, 0);
    expect(controller.notes.single.content, '远端改过');
    expect(readList('diary.json').single['content'], '远端改过');
  });

  test('本地修改写回 v2 与 v1，重复同步不会产生重复笔记', () async {
    await controller.upsert(note('n1', '第一版', created: now));
    expect(
      await service.sync(manual: true),
      isNotNull,
      reason: service.lastError,
    );

    now = now.add(const Duration(minutes: 1));
    final local = controller.notes.single;
    await controller.upsert(local.copyWith(content: '本地改过', updatedAt: now));

    final result = await service.sync(manual: true);

    expect(result, isNotNull, reason: service.lastError);
    expect(controller.notes, hasLength(1));
    expect(readList('diary.json').single['content'], '本地改过');
    final v2 = readJson('v2/notes.json');
    expect((v2['notes'] as List).single['content'], '本地改过');
    expect(result!.stats.conflictCopies, 0);
  });

  test('永久删除写入墓碑，手机端旧记录不会把笔记带回来', () async {
    final original = note('n1', '要删掉的', created: now);
    await controller.upsert(original);
    expect(
      await service.sync(manual: true),
      isNotNull,
      reason: service.lastError,
    );

    now = now.add(const Duration(minutes: 1));
    await controller.deletePermanently(controller.notes.single);
    expect(
      await service.sync(manual: true),
      isNotNull,
      reason: service.lastError,
    );

    expect(readList('diary.json'), isEmpty);
    expect((readJson('v2/notes.json')['notes'] as List), isEmpty);
    final tombstones = readJson('v2/tombstones.json')['tombstones'] as List;
    expect(tombstones.single['uuid'], 'n1');
    expect(tombstones.single['origin'], 'local');

    cloud.putText(
      'diary.json',
      jsonEncode([
        {
          'uuid': 'n1',
          'content': '手机端的旧副本',
          'created_at': SyncCodec.formatLocalNoZone(
            original.createdAt.millisecondsSinceEpoch,
          ),
        },
      ]),
    );
    await service.sync(manual: true);

    expect(controller.notes, isEmpty);
    expect(
      (readJson('v2/tombstones.json')['tombstones'] as List),
      hasLength(1),
    );
  });

  test('双方都改且时间接近时生成冲突副本', () async {
    final created = DateTime(2020, 1, 1);
    await controller.upsert(note('n1', '基线', created: created, updated: now));
    expect(
      await service.sync(manual: true),
      isNotNull,
      reason: service.lastError,
    );

    now = now.add(const Duration(minutes: 1));
    await controller.upsert(
      controller.notes.single.copyWith(content: '本地版本', updatedAt: now),
    );

    final remoteTime = now.add(const Duration(seconds: 10));
    final v2 = readJson('v2/notes.json');
    final rows = v2['notes'] as List<dynamic>;
    rows.first['content'] = '远端版本';
    rows.first['updated_at'] = SyncCodec.formatUtc(
      remoteTime.millisecondsSinceEpoch,
    );
    cloud.putText('v2/notes.json', jsonEncode(v2));

    final result = await service.sync(manual: true);

    expect(result, isNotNull, reason: service.lastError);
    expect(result!.stats.conflictCopies, 1);
    expect(controller.notes, hasLength(2));
    final winner = controller.notes.firstWhere((item) => item.uuid == 'n1');
    expect(winner.content, '远端版本');
    final copy = controller.notes.firstWhere((item) => item.uuid != 'n1');
    expect(copy.content, '本地版本');
    expect(copy.raw['conflict_of'], 'n1');
  });

  test('图片随笔记同步到另一台电脑并落到 blobs', () async {
    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 4, height: 4)),
    );
    final relative = await controller.saveImage(png);
    await controller.upsert(
      note('n1', '带图的笔记', created: now, images: [relative]),
    );

    expect(
      await service.sync(manual: true),
      isNotNull,
      reason: service.lastError,
    );
    final assetKeys = cloud.files.keys
        .where((key) => key.startsWith('v2/assets/'))
        .toList();
    expect(assetKeys, hasLength(1));
    expect(cloud.files[assetKeys.single], png);

    final dir2 = Directory.systemTemp.createTempSync('shengwuji_sync_test_b_');
    final store2 = NoteStore(rootDir: dir2);
    final controller2 = NotesController(store2);
    await controller2.load();
    final service2 = buildService(
      targetStore: store2,
      targetController: controller2,
      device: 'device-b',
    );

    try {
      final result = await service2.sync(manual: true);
      expect(result, isNotNull, reason: service2.lastError);
      expect(controller2.notes, hasLength(1));
      final synced = controller2.notes.single;
      expect(synced.content, '带图的笔记');
      expect(synced.images, hasLength(1));
      expect(synced.images.single, startsWith('blobs/'));
      final file = store2.imageFile(synced.images.single);
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), png);
    } finally {
      service2.dispose();
      controller2.dispose();
      await store2.close();
      if (dir2.existsSync()) dir2.deleteSync(recursive: true);
    }
  });

  test('手机截图索引把 v2/assets 里的图片挂到对应笔记', () async {
    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 3, height: 3)),
    );
    final sha = sha256.convert(png).toString();
    final createdAt = DateTime(2026, 10, 23, 8);
    cloud.putText(
      'diary.json',
      jsonEncode([
        {
          'uuid': 'phone-shot',
          'content': '手机截图的笔记',
          'created_at': SyncCodec.formatLocalNoZone(
            createdAt.millisecondsSinceEpoch,
          ),
        },
      ]),
    );
    cloud.putText(
      'image_index.json',
      jsonEncode([
        {
          'note_uuid': 'phone-shot',
          'device_id': 'phone-a',
          'sha256': sha,
          'name': '$sha.png',
          'mime': 'image/png',
          'size': png.length,
          'updated_at': SyncCodec.formatUtc(now.millisecondsSinceEpoch),
        },
      ]),
    );
    cloud.files['v2/assets/${sha.substring(0, 2)}/$sha.png'] = png;

    final result = await service.sync(manual: true);

    expect(result, isNotNull, reason: service.lastError);
    expect(result!.stats.assetsDownloaded, 1);
    expect(controller.notes, hasLength(1));
    final synced = controller.notes.single;
    expect(synced.uuid, 'phone-shot');
    expect(synced.images, hasLength(1));
    expect(synced.images.single, startsWith('blobs/'));
    final file = store.imageFile(synced.images.single);
    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), png);

    // 其他电脑即使不读 image_index.json，也能从 v2/notes.json 拿到附件
    final v2 = readJson('v2/notes.json');
    final rows = v2['notes'] as List<dynamic>;
    final attachments =
        (rows.single as Map<String, dynamic>)['attachments'] as List<dynamic>;
    expect(attachments, hasLength(1));
    expect((attachments.single as Map)['origin'], 'mobile');
    expect((attachments.single as Map)['sha256'], sha);
  });

  test('开启录音同步后从 audio/ 下载并绑定到笔记', () async {    service.dispose();
    service = buildService(
      targetStore: store,
      targetController: controller,
      syncConfig: defaultConfig.copyWith(audioEnabled: true),
    );
    final audioBytes = Uint8List.fromList(List<int>.generate(64, (i) => i));
    const audioName = 'diary_20261023_180704.wav';
    final createdAt = DateTime(2026, 10, 23, 18, 7);
    cloud.putText(
      'diary.json',
      jsonEncode([
        {
          'uuid': 'phone-audio',
          'content': '手机录音',
          'created_at': SyncCodec.formatLocalNoZone(
            createdAt.millisecondsSinceEpoch,
          ),
          'audio': audioName,
          'duration': 8,
        },
      ]),
    );
    // 旧桌面写入的 v2 不含录音附件；v1 里的 audio 不能因此丢掉。
    cloud.putText(
      'v2/notes.json',
      jsonEncode({
        'format': 'shengwuji.notes',
        'version': 2,
        'generated_at': SyncCodec.formatUtc(createdAt.millisecondsSinceEpoch),
        'notes': [
          {
            'uuid': 'phone-audio',
            'content': '手机录音',
            'created_at': SyncCodec.formatUtc(createdAt.millisecondsSinceEpoch),
            'updated_at': SyncCodec.formatUtc(createdAt.millisecondsSinceEpoch),
            'attachments': const [],
          },
        ],
      }),
    );
    cloud.putText('audio_index.json', jsonEncode([audioName]));
    cloud.files['audio/$audioName'] = audioBytes;

    final result = await service.sync(manual: true);

    expect(result, isNotNull, reason: service.lastError);
    expect(result!.stats.audioDownloaded, 1);
    final synced = controller.notes.single;
    expect(synced.audios, hasLength(1));
    final audio = synced.audios.single;
    expect(audio.fileName, audioName);
    expect(audio.durationMs, 8000);
    expect(audio.isDownloaded, isTrue);
    expect(audio.path, startsWith('blobs/'));
    final file = store.imageFile(audio.path!);
    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), audioBytes);

    final again = await service.sync(manual: true);
    expect(again, isNotNull, reason: service.lastError);
    expect(again!.stats.audioDownloaded, 0);
    expect(again.stats.appliedRemote, 0);
    expect(controller.notes.single.audios.single.path, audio.path);
  });

  test('关闭录音同步时只保留录音信息，不下载文件', () async {
    const audioName = 'diary_20261023_180704.wav';
    cloud.putText(
      'diary.json',
      jsonEncode([
        {
          'uuid': 'phone-audio',
          'content': '手机录音',
          'created_at': SyncCodec.formatLocalNoZone(
            DateTime(2026, 10, 23, 18, 7).millisecondsSinceEpoch,
          ),
          'audio': audioName,
          'duration': 8,
        },
      ]),
    );
    cloud.putText('audio_index.json', jsonEncode([audioName]));
    cloud.files['audio/$audioName'] = Uint8List.fromList([1, 2, 3, 4]);

    final result = await service.sync(manual: true);

    expect(result, isNotNull, reason: service.lastError);
    expect(result!.stats.audioDownloaded, 0);
    final audio = controller.notes.single.audios.single;
    expect(audio.fileName, audioName);
    expect(audio.durationMs, 8000);
    expect(audio.isDownloaded, isFalse);
    expect(
      Directory('${dir.path}/blobs').existsSync(),
      isFalse,
      reason: '未开启录音同步时不应写入 blobs',
    );
  });

  test('录音尚未出现在 audio_index.json 时先跳过，下一轮再下载', () async {
    service.dispose();
    service = buildService(
      targetStore: store,
      targetController: controller,
      syncConfig: defaultConfig.copyWith(audioEnabled: true),
    );
    const audioName = 'diary_20261023_180704.wav';
    cloud.putText(
      'diary.json',
      jsonEncode([
        {
          'uuid': 'phone-audio',
          'content': '手机录音',
          'created_at': SyncCodec.formatLocalNoZone(
            DateTime(2026, 10, 23, 18, 7).millisecondsSinceEpoch,
          ),
          'audio': audioName,
          'duration': 8,
        },
      ]),
    );
    cloud.putText('audio_index.json', jsonEncode([]));
    cloud.files['audio/$audioName'] = Uint8List.fromList([1, 2, 3, 4]);

    final first = await service.sync(manual: true);
    expect(first, isNotNull, reason: service.lastError);
    expect(first!.stats.audioDownloaded, 0);
    expect(controller.notes.single.audios.single.isDownloaded, isFalse);
    expect(first.warnings, isEmpty);

    now = now.add(const Duration(minutes: 1));
    cloud.putText('audio_index.json', jsonEncode([audioName]));
    final second = await service.sync(manual: true);
    expect(second, isNotNull, reason: service.lastError);
    expect(second!.stats.audioDownloaded, 1);
    expect(controller.notes.single.audios.single.isDownloaded, isTrue);
  });

  test('其他设备的软锁会阻止同步，过期后可接管', () async {
    cloud.putText(
      'manifest.json',
      jsonEncode({
        'v': 1,
        'lock': {'device_id': 'phone', 'at': now.toIso8601String()},
      }),
    );

    expect(await service.sync(manual: true), isNull);
    expect(service.lastError, contains('另一台设备正在同步'));
    expect(cloud.text('manifest.json'), contains('phone'));

    now = now.add(const Duration(minutes: 11));
    await controller.upsert(note('n1', '锁过期后同步', created: now));
    final result = await service.sync(manual: true);

    expect(result, isNotNull, reason: service.lastError);
    expect(readJson('manifest.json')['lock'], isNull);
    expect(readList('diary.json').single['content'], '锁过期后同步');
  });

  test('远端协议版本过高时停止并释放锁', () async {
    cloud.putText(
      'v2/manifest.json',
      jsonEncode({'protocol_version': 3, 'min_reader_version': 3}),
    );

    expect(await service.sync(manual: true), isNull);
    expect(service.lastError, contains('协议版本'));
    expect(readJson('manifest.json')['lock'], isNull);
  });

  test('远端 v2/notes.json 损坏时保留原文件并报错', () async {
    cloud.putText('v2/notes.json', '{ not valid json');

    expect(await service.sync(manual: true), isNull);
    expect(service.lastError, contains('v2/notes.json'));
    expect(cloud.text('v2/notes.json'), '{ not valid json');
    expect(readJson('manifest.json')['lock'], isNull);
  });

  test('同步进行中收到的改动会在本轮结束后补跑', () async {
    await controller.upsert(note('n1', '第一轮', created: now));

    var starts = 0;
    service.addListener(() {
      if (service.status == SyncStatus.syncing) starts++;
    });

    final gate = Completer<void>();
    cloud.blockRead = gate;

    final first = service.sync(manual: true);
    await controller.upsert(
      note('n2', '同步中新增', created: now.add(const Duration(minutes: 1))),
    );
    expect(service.isBusy, isTrue);
    final second = service.sync();
    expect(identical(second, first), isTrue);

    gate.complete();
    expect(await first, isNotNull, reason: service.lastError);
    await waitFor(() => starts >= 2 && !service.isBusy);

    expect(readJson('v2/notes.json')['notes'] as List, hasLength(2));
  });

  test('远端图片哈希异常时跳过资源同步并给出提醒', () async {
    cloud.putText(
      'v2/notes.json',
      jsonEncode({
        'format': 'shengwuji.notes',
        'version': 2,
        'generated_at': SyncCodec.formatUtc(now.millisecondsSinceEpoch),
        'notes': [
          {
            'uuid': 'bad-1',
            'content': '坏索引',
            'created_at': SyncCodec.formatUtc(now.millisecondsSinceEpoch),
            'updated_at': SyncCodec.formatUtc(now.millisecondsSinceEpoch),
            'attachments': [
              {'uuid': 'a1', 'kind': 'image', 'sha256': 'abc', 'name': 'x.png'},
            ],
          },
        ],
      }),
    );

    final result = await service.sync(manual: true);

    expect(result, isNotNull, reason: service.lastError);
    expect(result!.warnings.join('\n'), contains('图片索引信息异常'));
    expect(
      cloud.files.keys.where((key) => key.startsWith('v2/assets/')),
      isEmpty,
    );
  });

  test('本地改动会合并成一次延时同步', () async {
    service.dispose();
    service = buildService(
      targetStore: store,
      targetController: controller,
      debounce: const Duration(milliseconds: 30),
    );

    await controller.upsert(note('n1', '延时同步', created: now));
    service.noteLocalChange();
    service.noteLocalChange();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(cloud.text('v2/notes.json'), isNotNull);
    expect(readJson('v2/notes.json')['notes'], hasLength(1));
    expect(service.status, SyncStatus.success);
  });

  test('定时轮询：远端未变化时只读元信息，不读正文也不写文件', () async {
    await controller.upsert(note('n1', '轮询', created: now));
    expect(
      await service.sync(manual: true),
      isNotNull,
      reason: service.lastError,
    );

    cloud.stats = 0;
    cloud.reads = 0;
    cloud.writes = 0;

    final result = await service.poll();

    expect(result, isNull);
    expect(cloud.stats, 2, reason: '只探测 manifest.json 与 v2/manifest.json');
    expect(cloud.reads, 0);
    expect(cloud.writes, 0);
    expect(service.lastError, isNull);
  });

  test('定时轮询：远端变化后执行完整同步并拉下新笔记', () async {
    await controller.upsert(note('n1', '轮询', created: now));
    expect(
      await service.sync(manual: true),
      isNotNull,
      reason: service.lastError,
    );

    now = now.add(const Duration(minutes: 3));
    final diary = readList('diary.json');
    diary.add({
      'uuid': 'phone-2',
      'content': '手机新笔记',
      'created_at': SyncCodec.formatLocalNoZone(now.millisecondsSinceEpoch),
    });
    cloud.putText('diary.json', jsonEncode(diary));
    final manifest = readJson('manifest.json');
    manifest['updated_at'] = SyncCodec.formatLocalNoZone(
      now.millisecondsSinceEpoch,
    );
    manifest['counts'] = {'notes': 2};
    cloud.putText('manifest.json', jsonEncode(manifest));

    final result = await service.poll();

    expect(result, isNotNull, reason: service.lastError);
    expect(controller.notes, hasLength(2));
    expect(
      controller.notes.map((item) => item.uuid),
      containsAll(['n1', 'phone-2']),
    );
    expect(readList('diary.json'), hasLength(2));
  });

  test('完整同步在内容未变时不重传 v2 三个快照', () async {
    await controller.upsert(note('n1', '不变', created: now));
    expect(
      await service.sync(manual: true),
      isNotNull,
      reason: service.lastError,
    );

    final writesBefore = cloud.writes;
    final notesBefore = cloud.text('v2/notes.json');
    final tombstonesBefore = cloud.text('v2/tombstones.json');
    final manifestBefore = cloud.text('v2/manifest.json');

    now = now.add(const Duration(minutes: 1));
    final result = await service.sync(manual: true);

    expect(result, isNotNull, reason: service.lastError);
    expect(cloud.writes - writesBefore, 2, reason: '只写 v1 锁的获取与释放');
    expect(cloud.text('v2/notes.json'), notesBefore);
    expect(cloud.text('v2/tombstones.json'), tombstonesBefore);
    expect(cloud.text('v2/manifest.json'), manifestBefore);
  });

  test('自动推送失败后，下一次轮询会重试而不是只探测', () async {
    service.dispose();
    service = buildService(
      targetStore: store,
      targetController: controller,
      debounce: const Duration(milliseconds: 30),
    );

    await controller.upsert(note('n1', '失败后重试', created: now));
    cloud.failWritePath = 'v2/notes.json';
    cloud.failWriteStatus = 500;
    service.noteLocalChange();
    await waitFor(() => service.status == SyncStatus.error && !service.isBusy);
    expect(service.lastError, isNotNull);

    cloud.failWritePath = null;
    final retried = await service.poll();

    expect(retried, isNotNull, reason: service.lastError);
    expect(readJson('v2/notes.json')['notes'], hasLength(1));
    expect(
      (readJson('v2/notes.json')['notes'] as List).single['content'],
      '失败后重试',
    );
  });

  test('服务端不支持 PROPFIND 时轮询退回完整同步', () async {
    await controller.upsert(note('n1', '兜底', created: now));
    expect(
      await service.sync(manual: true),
      isNotNull,
      reason: service.lastError,
    );

    cloud.supportsStat = false;
    cloud.writes = 0;
    now = now.add(const Duration(minutes: 1));

    final result = await service.poll();

    expect(result, isNotNull, reason: service.lastError);
    expect(cloud.writes, greaterThan(0));
  });
}
