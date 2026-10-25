import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// 本机 WebDAV 请求预算：滚动 30 分钟窗口内发出的请求数。
///
/// 坚果云只在帮助中心说明「免费版 600 次 / 30 分钟、付费版 1500 次」，
/// 没有查询剩余额度的接口，响应里也不返回限流余量，因此只能客户端自己记账。
/// 窗口按分钟归档，滚动计算，不需要判断当前落在哪个固定区间。
///
/// 计数只覆盖这台电脑；手机端和其它客户端发出的请求不在这里。
class WebDavRequestCounter extends ChangeNotifier {
  WebDavRequestCounter({
    this.limit = freeLimit,
    this.storageFile,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const int freeLimit = 600;
  static const int paidLimit = 1500;
  static const Duration windowLength = Duration(minutes: 30);
  static const int _windowMinutes = 30;
  static const Duration _persistDelay = Duration(seconds: 2);
  static const int _storageVersion = 1;

  /// 用于估算剩余额度的上限；默认按坚果云免费版。
  final int limit;

  /// 计数落盘位置；为 null 时只在内存里计数（测试与单元场景）。
  final File? storageFile;

  final DateTime Function() _clock;
  final Map<int, int> _buckets = <int, int>{};
  Future<void> _writeChain = Future<void>.value();
  Timer? _persistTimer;
  Timer? _expiryTimer;
  bool _disposed = false;

  /// 最近 30 分钟内本机发出的请求数。
  int get recentCount {
    _prune();
    var total = 0;
    for (final count in _buckets.values) {
      total += count;
    }
    return total;
  }

  /// 按 [limit] 估算的剩余次数；实际额度还可能被其它设备占用。
  int get remaining => math.max(0, limit - recentCount);

  /// 窗口内最早一批请求滑出窗口还要多久；窗口为空时为 null。
  Duration? get untilNextExpiry {
    _prune();
    if (_buckets.isEmpty) return null;
    final oldest = _buckets.keys.reduce(math.min);
    final expireAt = _minuteStart(oldest).add(windowLength);
    final left = expireAt.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  /// 读取上次退出前的计数；损坏或不存在时按空窗口处理。
  Future<void> load() async {
    if (_disposed) return;
    final file = storageFile;
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final rawBuckets = decoded['buckets'];
      if (rawBuckets is! Map) return;
      for (final entry in rawBuckets.entries) {
        final minute = int.tryParse('${entry.key}');
        final value = entry.value;
        if (minute == null || value is! num) continue;
        final count = value.toInt();
        if (count > 0) _buckets[minute] = count;
      }
    } catch (error) {
      debugPrint('读取 WebDAV 请求计数失败，按空窗口处理：$error');
    }
    _prune();
    _scheduleExpiry();
    _notify();
  }

  /// 每发出一次 HTTP 请求调用一次（失败的请求也计入，偏保守）。
  void record() {
    if (_disposed) return;
    final now = _clock();
    _prune(now);
    final minute = _minuteOf(now);
    _buckets[minute] = (_buckets[minute] ?? 0) + 1;
    _scheduleExpiry();
    _schedulePersist();
    _notify();
  }

  /// 立即把当前计数写盘；退出前调用，避免丢掉最后几秒的请求。
  Future<void> flush() {
    _persistTimer?.cancel();
    _persistTimer = null;
    final file = storageFile;
    if (file == null) return Future<void>.value();
    _prune();
    final snapshot = _snapshot();
    _writeChain = _writeChain.then((_) => _write(file, snapshot));
    return _writeChain;
  }

  void _prune([DateTime? now]) {
    if (_buckets.isEmpty) return;
    final current = _minuteOf(now ?? _clock());
    final cutoff = current - (_windowMinutes - 1);
    _buckets.removeWhere((minute, _) => minute < cutoff || minute > current);
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (_disposed) return;
    final now = _clock();
    _prune(now);
    if (_buckets.isEmpty) return;
    final oldest = _buckets.keys.reduce(math.min);
    final expireAt = _minuteStart(oldest).add(windowLength);
    var delay = expireAt.difference(now);
    if (delay < const Duration(milliseconds: 100)) {
      delay = const Duration(milliseconds: 100);
    }
    _expiryTimer = Timer(delay + const Duration(milliseconds: 20), () {
      _expiryTimer = null;
      _prune();
      _schedulePersist();
      _notify();
      _scheduleExpiry();
    });
  }

  void _schedulePersist() {
    if (_disposed || storageFile == null) return;
    _persistTimer ??= Timer(_persistDelay, () {
      _persistTimer = null;
      unawaited(flush());
    });
  }

  Map<String, Object?> _snapshot() {
    return {
      'version': _storageVersion,
      'window_minutes': _windowMinutes,
      'buckets': {
        for (final entry in _buckets.entries) '${entry.key}': entry.value,
      },
    };
  }

  Future<void> _write(File file, Map<String, Object?> snapshot) async {
    try {
      await file.parent.create(recursive: true);
      final text = jsonEncode(snapshot);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      try {
        await tmp.rename(file.path);
      } on FileSystemException {
        await file.writeAsString(text, flush: true);
        if (await tmp.exists()) await tmp.delete();
      }
    } catch (error) {
      debugPrint('保存 WebDAV 请求计数失败：$error');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _persistTimer?.cancel();
    _persistTimer = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    super.dispose();
  }

  static int _minuteOf(DateTime time) => time.millisecondsSinceEpoch ~/ 60000;

  static DateTime _minuteStart(int minute) =>
      DateTime.fromMillisecondsSinceEpoch(minute * 60000);
}
