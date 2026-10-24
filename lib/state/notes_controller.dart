import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/note_store.dart';
import '../models/note.dart';

/// 笔记列表的内存状态 + 持久化编排。
///
/// 所有写操作都串行进入同一条 Future 链，避免自动保存与删除同时落盘时
/// 旧快照覆盖新快照。界面先更新内存再等落盘，输入不会因为磁盘慢而卡顿。
class NotesController extends ChangeNotifier {
  NotesController(
    this.store, {
    DateTime Function()? clock,
    VoidCallback? onLocalChange,
  }) : _clock = clock ?? DateTime.now,
       _onLocalChange = onLocalChange;

  static const Uuid _uuid = Uuid();

  final NoteStore store;
  final DateTime Function() _clock;
  final VoidCallback? _onLocalChange;

  final List<Note> _notes = [];
  String _query = '';
  bool _loading = true;
  String? _error;
  bool _disposed = false;
  Future<void> _writeChain = Future.value();

  List<Note> get notes => List.unmodifiable(_notes);

  /// 主列表里的笔记；`archived` 的笔记只出现在回收站。
  List<Note> get activeNotes =>
      List.unmodifiable(_notes.where((note) => !note.archived));

  List<Note> get archivedNotes =>
      List.unmodifiable(_notes.where((note) => note.archived));

  bool get isLoading => _loading;

  String? get error => _error;

  String get query => _query;

  List<Note> get visibleNotes {
    final keyword = _query.trim().toLowerCase();
    return List.unmodifiable(
      _notes.where(
        (note) =>
            !note.archived &&
            (keyword.isEmpty || note.content.toLowerCase().contains(keyword)),
      ),
    );
  }

  Future<void> load({bool silent = false}) async {
    if (!silent) {
      _loading = true;
      _error = null;
      _notify();
    }
    try {
      final loaded = await store.load();
      _notes
        ..clear()
        ..addAll(loaded);
      _sort();
      _error = null;
    } catch (error) {
      _error = '读取本地笔记失败：$error';
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// 同步写入数据库后重新读取，避免界面与磁盘状态不一致。
  Future<void> reloadAfterSync() => load(silent: true);

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    _notify();
  }

  Note createDraft() {
    final now = _clock();
    return Note(uuid: _uuid.v4(), content: '', createdAt: now, updatedAt: now);
  }

  Future<void> upsert(Note note) async {
    final index = _notes.indexWhere((item) => item.uuid == note.uuid);
    final previous = index >= 0 ? _notes[index] : null;
    if (index >= 0) {
      _notes[index] = note;
    } else {
      _notes.add(note);
    }
    _sort();
    _notify();

    await _persist();
    if (previous != null) {
      final removed = previous.images.where(
        (name) => !note.images.contains(name),
      );
      await store.deleteImages(removed);
    }
    _notifyLocalChange();
  }

  /// 删除先移入回收站：保留图片，等用户确认后再永久清理。
  Future<void> moveToTrash(Note note) async {
    final index = _notes.indexWhere((item) => item.uuid == note.uuid);
    if (index < 0 || _notes[index].archived) return;
    _notes[index] = _notes[index].copyWith(
      archived: true,
      updatedAt: _clock(),
    );
    _notify();
    await _persist();
    _notifyLocalChange();
  }

  Future<void> restore(Note note) async {
    final index = _notes.indexWhere((item) => item.uuid == note.uuid);
    if (index < 0 || !_notes[index].archived) return;
    _notes[index] = _notes[index].copyWith(
      archived: false,
      updatedAt: _clock(),
    );
    _notify();
    await _persist();
    _notifyLocalChange();
  }

  Future<void> deletePermanently(Note note) => deletePermanentlyMany([note]);

  /// 批量永久删除（回收站多选/全选），图片一次性清理。
  Future<void> deletePermanentlyMany(Iterable<Note> notes) async {
    final uuids = notes.map((note) => note.uuid).toSet();
    if (uuids.isEmpty) return;
    final images = <String>[];
    final before = _notes.length;
    _notes.removeWhere((item) {
      if (!uuids.contains(item.uuid)) return false;
      images.addAll(item.images);
      return true;
    });
    if (_notes.length == before) return;
    _notify();
    await _persist();
    await store.deleteImages(images);
    _notifyLocalChange();
  }

  Future<void> emptyTrash() => deletePermanentlyMany(archivedNotes);

  /// 新建笔记从未落盘就关闭时调用：清掉已经写进 images/ 的孤儿文件。
  Future<void> discardDraft(Note note) async {
    if (_notes.any((item) => item.uuid == note.uuid)) return;
    await store.deleteImages(note.images);
  }

  Future<String> saveImage(Uint8List bytes) => store.saveImage(bytes);

  /// 等已排队的写盘全部完成；切换数据目录前调用，避免旧目录还有半截写入。
  Future<void> flush() => _writeChain;

  Future<void> _persist() {
    final snapshot = List<Note>.unmodifiable(_notes);
    final next = _writeChain.then((_) => store.writeAll(snapshot));
    // 单次写失败不能阻断后续保存，错误交给调用方处理。
    _writeChain = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _sort() {
    _notes.sort((a, b) {
      final byCreated = b.createdAt.compareTo(a.createdAt);
      if (byCreated != 0) return byCreated;
      return a.uuid.compareTo(b.uuid);
    });
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  void _notifyLocalChange() {
    if (_disposed) return;
    _onLocalChange?.call();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
