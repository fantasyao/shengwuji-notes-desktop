/// 卡片时间：今天/昨天显示时分，今年显示月日，跨年显示年月日。
String formatNoteTime(DateTime time, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(time.year, time.month, time.day);
  final hhmm =
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  if (day == today) return '今天 $hhmm';
  if (day == today.subtract(const Duration(days: 1))) return '昨天 $hhmm';
  if (time.year == current.year) return '${time.month}月${time.day}日';
  return '${time.year}年${time.month}月${time.day}日';
}

/// 保存状态里用的短时间。
String formatClock(DateTime time) {
  return '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
}
