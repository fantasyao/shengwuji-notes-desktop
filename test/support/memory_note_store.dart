import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shengwuji_desktop/data/image_payload.dart';
import 'package:shengwuji_desktop/data/note_store.dart';
import 'package:shengwuji_desktop/models/note.dart';
import 'package:uuid/uuid.dart';

/// 界面测试用的存储：笔记放内存，图片同步写临时目录。
///
/// 真实 NoteStore 的文件 I/O 与 WidgetTester 的假时钟混在一起时，保存 Future
/// 可能迟迟不完成，导致点击「完成」后页面不退出；这里把异步降到微任务级别。
class MemoryNoteStore extends NoteStore {
  MemoryNoteStore({required super.rootDir});

  static const Uuid _uuid = Uuid();

  final List<Note> _notes = [];

  @override
  Future<List<Note>> load() async => List<Note>.from(_notes);

  @override
  Future<void> writeAll(List<Note> notes) async {
    _notes
      ..clear()
      ..addAll(notes);
  }

  @override
  Future<String> saveImage(Uint8List bytes) async {
    final payload = normalizeImage(bytes);
    if (payload.bytes.length > NoteStore.maxImageBytes) {
      throw const ImageTooLargeException(NoteStore.maxImageBytes);
    }
    imagesDir.createSync(recursive: true);
    final name =
        '${DateTime.now().millisecondsSinceEpoch}_'
        '${_uuid.v4().substring(0, 8)}.${payload.extension}';
    File(p.join(imagesDir.path, name)).writeAsBytesSync(payload.bytes);
    return name;
  }

  @override
  Future<void> deleteImage(String name) async {
    if (name.isEmpty || p.basename(name) != name) return;
    final file = imageFile(name);
    if (file.existsSync()) file.deleteSync();
  }
}
