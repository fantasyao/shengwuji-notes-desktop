import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/sync/sync_codec.dart';
import 'package:shengwuji_desktop/sync/sync_models.dart';

void main() {
  int ms(DateTime time) => time.millisecondsSinceEpoch;

  test('v1 时间写成本地时间且不带 Z', () {
    final time = DateTime(2026, 10, 23, 9, 5, 7);
    final text = SyncCodec.formatLocalNoZone(ms(time));
    expect(text, '2026-10-23T09:05:07.000');
    expect(text.endsWith('Z'), isFalse);
    expect(SyncCodec.parseIsoMs(text), ms(time));
  });

  test('v1 投影只写手机认识的字段，布尔用数字 1', () {
    final created = DateTime(2026, 10, 20, 8);
    final note = SyncNote(
      uuid: 'n1',
      content: '相机里的猫',
      createdAt: ms(created),
      updatedAt: ms(created),
      mark: '灵感',
      archived: true,
      locked: true,
      extras: const {
        'audio': 'voice.m4a',
        'duration': 1234,
        'images': ['photo.jpg'],
        'unknown_field': 'keep-me',
      },
    );

    final rows = SyncCodec.encodeDiaryV1([
      note,
    ], [
      {'uuid': 'broken', 'content': '手机端新增但字段不全'},
    ]);

    expect(rows, hasLength(2));
    final row = rows.first;
    expect(row['uuid'], 'n1');
    expect(row['content'], '相机里的猫');
    expect(row['created_at'], '2026-10-20T08:00:00.000');
    expect(row['archived'], 1);
    expect(row['locked'], 1);
    expect(row['tag'], '灵感');
    expect(row['audio'], 'voice.m4a');
    expect(row['duration'], 1234);
    expect(row['images'], ['photo.jpg']);
    expect(row['unknown_field'], 'keep-me');
    expect(row.containsKey('updated_at'), isFalse);
    expect(rows.last['uuid'], 'broken');
  });

  test('v1 布尔只有数字 1 才生效，无法解析的行原样保留', () {
    final created = '2026-10-21T10:11:12.000';
    final parsed = SyncCodec.parseDiaryV1([
      {
        'uuid': 'a',
        'content': '真布尔会被手机忽略',
        'created_at': created,
        'archived': true,
        'locked': true,
      },
      {'uuid': 'b', 'content': '缺时间'},
    ]);

    expect(parsed.notes, hasLength(1));
    expect(parsed.notes.single.archived, isFalse);
    expect(parsed.notes.single.locked, isFalse);
    expect(parsed.preservedRows, hasLength(1));
    expect(parsed.skipped, 1);
  });

  test('v1 manifest 加锁与解锁保留未知字段和计数', () {
    final existing = <String, dynamic>{
      'v': 1,
      'device_id': 'phone',
      'custom': {'theme': 'dark'},
      'counts': {'notes': 3, 'audio': 1},
    };

    final locked = SyncCodec.acquireLockV1(existing, 'desktop');
    expect(locked['device_id'], 'desktop');
    expect(locked['custom'], {'theme': 'dark'});
    expect(locked['lock'], isA<Map>());
    expect((locked['lock'] as Map)['device_id'], 'desktop');
    expect(SyncCodec.parseManifestV1(locked).lock?.deviceId, 'desktop');

    final released = SyncCodec.releaseLockV1(locked, 'desktop', {'notes': 4});
    expect(released['lock'], isNull);
    expect(released['custom'], {'theme': 'dark'});
    expect(released['counts'], {'notes': 4});
  });

  test('锁超过 10 分钟或时间无效时视为过期', () {
    final now = DateTime(2026, 10, 23, 12);
    final fresh = SyncLock(
      deviceId: 'phone',
      at: now.subtract(const Duration(minutes: 9)).toIso8601String(),
    );
    final stale = SyncLock(
      deviceId: 'phone',
      at: now.subtract(const Duration(minutes: 11)).toIso8601String(),
    );
    final broken = SyncLock(deviceId: 'phone', at: 'not-a-time');

    expect(fresh.isStale(now), isFalse);
    expect(stale.isStale(now), isTrue);
    expect(broken.isStale(now), isTrue);
  });

  test('v2 笔记与附件往返保留标签和未知字段', () {
    final created = DateTime(2026, 10, 20, 8);
    final note = SyncNote(
      uuid: 'n1',
      content: '桌面端笔记',
      createdAt: ms(created),
      updatedAt: ms(created) + 5000,
      mark: '工作',
      archived: false,
      locked: true,
      sortOrder: 3,
      rev: 7,
      extras: const {
        'tags': ['项目', '重要'],
        'custom_field': 'voice.m4a',
        'custom': 42,
      },
      attachments: [
        SyncAttachment(
          uuid: 'a1',
          kind: 'image',
          sha256: 'a' * 64,
          syncName: 'cat.png',
          mimeType: 'image/png',
          byteSize: 128,
        ),
      ],
    );

    final encoded = SyncCodec.encodeNotesV2(
      notes: [note],
      deviceId: 'desktop',
      nowMs: ms(created),
    );
    final decoded = SyncCodec.parseNotesV2(encoded);

    expect(decoded, hasLength(1));
    final restored = decoded.single;
    expect(restored.uuid, 'n1');
    expect(restored.content, '桌面端笔记');
    expect(restored.locked, isTrue);
    expect(restored.rev, 7);
    expect(restored.sortOrder, 3);
    expect(restored.extras['tags'], ['项目', '重要']);
    expect(restored.extras['custom_field'], 'voice.m4a');
    expect(restored.extras['custom'], 42);
    expect(restored.attachments.single.sha256, 'a' * 64);
    expect(restored.attachments.single.syncName, 'cat.png');
    expect(restored.attachments.single.byteSize, 128);
    expect(restored.payloadHash, note.payloadHash);
  });

  test('v1 录音字段统一成音频附件，回写时只保留文件名和秒数', () {
    final created = '2026-10-23T18:07:04.000';
    final parsed = SyncCodec.parseDiaryV1([
      {
        'uuid': 'n1',
        'content': '一段录音',
        'created_at': created,
        'audio': 'audio\\diary_20261023_180704.wav',
        'duration': 8,
        'custom': 'keep-me',
      },
    ]);

    final note = parsed.notes.single;
    expect(note.extras.containsKey('audio'), isFalse);
    expect(note.extras.containsKey('duration'), isFalse);
    expect(note.extras['custom'], 'keep-me');

    final audio = note.attachments.single;
    expect(audio.kind, 'audio');
    expect(audio.isAudio, isTrue);
    expect(audio.syncName, 'diary_20261023_180704.wav');
    expect(audio.durationMs, 8000);
    expect(audio.mimeType, 'audio/wav');
    expect(
      audio.uuid,
      SyncCodec.audioAttachmentUuid('n1', 'diary_20261023_180704.wav'),
    );

    final rows = SyncCodec.encodeDiaryV1([note], const []);
    expect(rows.single['audio'], 'diary_20261023_180704.wav');
    expect(rows.single['duration'], 8);
  });

  test('音频附件下载后回填 sha256 不改载荷指纹', () {
    final attachment = SyncAttachment(
      uuid: 'a1',
      kind: 'audio',
      syncName: 'voice.m4a',
      durationMs: 3000,
    );
    final note = SyncNote(
      uuid: 'n1',
      content: '录音',
      createdAt: 1000,
      updatedAt: 1000,
      attachments: [attachment],
    );
    final downloaded = note.copyWith(
      attachments: [
        attachment.copyWith(sha256: 'b' * 64, byteSize: 2048),
      ],
    );

    expect(downloaded.payloadHash, note.payloadHash);

    final roundTrip = SyncCodec.parseNotesV2(
      SyncCodec.encodeNotesV2(
        notes: [downloaded],
        deviceId: 'desktop',
        nowMs: 2000,
      ),
    ).single;
    expect(roundTrip.attachments.single.sha256, 'b' * 64);
    expect(roundTrip.attachments.single.syncName, 'voice.m4a');
    expect(roundTrip.attachments.single.durationMs, 3000);
    expect(roundTrip.payloadHash, note.payloadHash);
  });

  test('重复归一化保持附件与 uuid 稳定', () {
    final once = SyncCodec.normalizeAudio(
      SyncNote(
        uuid: 'n1',
        content: '录音',
        createdAt: 1000,
        updatedAt: 1000,
        extras: const {'audio': 'voice.mp3', 'duration': 2.5},
      ),
    );
    final twice = SyncCodec.normalizeAudio(once);

    expect(twice.attachments, hasLength(1));
    expect(twice.attachments.single.uuid, once.attachments.single.uuid);
    expect(twice.attachments.single.durationMs, 2500);
    expect(twice.attachments.single.mimeType, 'audio/mpeg');
    expect(twice.payloadHash, once.payloadHash);
  });

  test('v2 协议版本过高时拒绝继续', () {
    final manifest = SyncCodec.parseManifestV2({
      'protocol_version': 3,
      'min_reader_version': 3,
    });
    expect(
      () => SyncCodec.ensureSupported(manifest),
      throwsA(isA<FormatException>()),
    );
  });

  test('图片索引：多图并存、坏行跳过、文件名收敛为 basename', () {
    final shaA = 'a' * 64;
    final shaB = 'b' * 64;
    final shaC = 'c' * 64;
    final parsed = SyncCodec.parseImageIndex([
      {
        'note_uuid': 'n1',
        'device_id': 'phone-a',
        'sha256': shaA,
        'name': '$shaA.jpg',
        'mime': 'image/jpeg',
        'size': 10,
        'updated_at': '2026-10-24T08:00:00.000Z',
        'position': 1,
      },
      {
        'note_uuid': 'n1',
        'device_id': 'phone-a',
        'sha256': shaB,
        'name': '$shaB.jpg',
        'updated_at': '2026-10-24T09:00:00.000Z',
        'position': 0,
      },
      {
        'note_uuid': 'n2',
        'device_id': 'pc',
        'sha256': shaC,
        'name': '../../evil.png',
        'source': 'desktop',
      },
      // 哈希不合法 → 跳过
      {'note_uuid': 'n3', 'sha256': 'abc', 'name': 'x.jpg'},
      'garbage',
    ]);

    expect(parsed.skipped, 2);
    expect(parsed.entries, hasLength(3));
    final n1 = parsed.entries.where((entry) => entry.noteUuid == 'n1');
    expect(n1.map((entry) => entry.sha256).toSet(), {shaA, shaB});
    final latest = n1.firstWhere((entry) => entry.sha256 == shaB);
    expect(latest.remotePath, 'v2/assets/bb/$shaB.jpg');
    expect(latest.position, 0);
    final sanitized = parsed.entries.firstWhere(
      (entry) => entry.noteUuid == 'n2',
    );
    expect(sanitized.name, 'evil.png');
    expect(sanitized.source, 'desktop');
  });

  test('图片索引编码保留 position 与 desktop 来源', () {
    final sha = 'd' * 64;
    final text = SyncCodec.encodeImageIndex([
      SyncImageEntry(
        noteUuid: 'n1',
        deviceId: 'pc',
        sha256: sha,
        name: '$sha.png',
        position: 2,
        source: 'desktop',
        updatedAt: 1761300000000,
      ),
    ]);
    final parsed = SyncCodec.parseImageIndex(jsonDecode(text));
    expect(parsed.entries.single.position, 2);
    expect(parsed.entries.single.source, 'desktop');
    expect(parsed.entries.single.updatedAt, 1761300000000);
  });

  test('手机截图索引顶层不是数组时抛格式错误', () {
    expect(
      () => SyncCodec.parseImageIndex({'notes': []}),
      throwsA(isA<FormatException>()),
    );
  });
}
