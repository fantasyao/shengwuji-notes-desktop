import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/models/note.dart';

void main() {
  test('fromJson 读取主 App 字段并保留未知字段', () {
    final json = <String, dynamic>{
      'uuid': 'uuid-1',
      'content': '第一行\n第二行',
      'created_at': '2026-10-22T14:30:00.123456',
      'audio': 'voice.m4a',
      'duration': 12,
      'archived': 1,
      'locked': 1,
      'tag': 'star',
      'sort_order': 3,
      'future_field': {'keep': true},
    };

    final note = Note.fromJson(json);
    expect(note.uuid, 'uuid-1');
    expect(note.content, '第一行\n第二行');
    expect(note.images, isEmpty);
    expect(note.archived, isTrue);
    expect(note.tag, 'star');
    expect(note.createdAt, DateTime(2026, 10, 22, 14, 30, 0, 123, 456));
    expect(note.updatedAt, note.createdAt);

    final written = note.toJson();
    expect(written['audio'], 'voice.m4a');
    expect(written['duration'], 12);
    expect(written['locked'], 1);
    expect(written['sort_order'], 3);
    expect(written['future_field'], {'keep': true});
    expect(written['archived'], 1);
    expect(written['tag'], 'star');
  });

  test('读取录音附件，未下载时没有本地路径', () {
    final note = Note.fromJson({
      'uuid': 'u',
      'content': '',
      'created_at': '2026-10-23T18:07:04',
      'audios': [
        {
          'uuid': 'a1',
          'path': 'blobs/aa/aa.wav',
          'file_name': 'voice.wav',
          'duration_ms': 8000,
        },
        {'uuid': 'a2', 'file_name': 'cloud.m4a', 'duration_ms': 3000},
        {'path': 'no-uuid.m4a'},
      ],
    });

    expect(note.audios, hasLength(3));
    expect(note.audios.first.isDownloaded, isTrue);
    expect(note.audios.first.duration, const Duration(seconds: 8));
    expect(note.audios[1].isDownloaded, isFalse);
    expect(note.audios[1].fileName, 'cloud.m4a');
    expect(note.title, '录音笔记');
    expect(note.copyWith(content: '有内容').title, '有内容');
    expect(note.toJson()['audios'], hasLength(3));
  });

  test('images 只接受字符串，坏值忽略', () {
    final note = Note.fromJson({
      'uuid': 'u',
      'content': 'x',
      'created_at': '2026-10-22T10:00:00',
      'images': ['a.png', '', 3, null, 'b.jpg'],
    });
    expect(note.images, ['a.png', 'b.jpg']);
  });

  test('archived 兼容 int 与 bool，tag 可清除', () {
    final note = Note.fromJson({
      'uuid': 'u',
      'content': 'x',
      'created_at': '2026-10-22T10:00:00',
      'archived': true,
      'tag': 'urgent',
    });
    expect(note.archived, isTrue);
    expect(note.copyWith(clearTag: true).tag, isNull);
    expect(note.copyWith(archived: false).archived, isFalse);
  });

  test('title 取首个非空行，body 取剩余内容', () {
    final now = DateTime(2026, 10, 22);
    final note = Note(
      uuid: 'u',
      content: '\n  标题行  \n正文一\n正文二',
      createdAt: now,
      updatedAt: now,
    );
    expect(note.title, '标题行');
    expect(note.body, '正文一\n正文二');
    expect(
      Note(
        uuid: 'u2',
        content: '',
        createdAt: now,
        updatedAt: now,
        images: const ['a.png'],
      ).title,
      '图片笔记',
    );
  });

  test('缺 uuid 视为坏行', () {
    expect(
      () => Note.fromJson({'content': '没有 id'}),
      throwsFormatException,
    );
  });

  test('缺时间字段时使用 epoch，保证排序稳定', () {
    final note = Note.fromJson({'uuid': 'u', 'content': 'x'});
    expect(note.createdAt, DateTime.fromMillisecondsSinceEpoch(0));
  });
}
