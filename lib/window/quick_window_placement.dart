/// 速记窗呼出位置的计算。
///
/// 默认落在主屏可用区（不含任务栏）右下角；开启「记住位置」后优先使用上次
/// 保存的坐标，但要先确认它落在某块当前接上的屏幕里。副屏被拔掉、分辨率或
/// 缩放变了，旧坐标可能完全在屏幕外，这时回落到主屏右下角，避免窗口叫出来
/// 却看不见。
library;

import 'dart:ui';

/// 按 [area]（屏幕可用区）与 [margin] 算出右下角位置。
Rect defaultQuickBounds(Rect area, Size size, double margin) {
  return Rect.fromLTWH(
    area.right - size.width - margin,
    area.bottom - size.height - margin,
    size.width,
    size.height,
  );
}

/// 呼出速记窗时的矩形。
///
/// [remembered] 是上次保存的窗口左上角，为空表示用户没挪过；[displayAreas]
/// 是各屏幕的可用区。记住的位置与某块屏幕有重叠就沿用它，并把窗口夹回那块
/// 屏幕内（防止只有一条边露出来）；否则回到主屏右下角。
Rect resolveQuickBounds({
  required Size size,
  required Rect primaryArea,
  required List<Rect> displayAreas,
  required Offset? remembered,
  double margin = 24,
}) {
  final fallback = defaultQuickBounds(primaryArea, size, margin);
  if (remembered == null) return fallback;

  final candidate = Rect.fromLTWH(
    remembered.dx,
    remembered.dy,
    size.width,
    size.height,
  );
  final area = _bestDisplay(candidate, displayAreas);
  if (area == null) return fallback;
  return Rect.fromLTWH(
    _fit(candidate.left, area.left, area.right - size.width),
    _fit(candidate.top, area.top, area.bottom - size.height),
    size.width,
    size.height,
  );
}

/// 与候选矩形重叠面积最大的屏幕；完全不重叠说明位置已失效。
Rect? _bestDisplay(Rect candidate, List<Rect> areas) {
  Rect? best;
  var bestOverlap = 0.0;
  for (final area in areas) {
    final overlap = candidate.intersect(area);
    if (overlap.isEmpty) continue;
    final size = overlap.width * overlap.height;
    if (size > bestOverlap) {
      bestOverlap = size;
      best = area;
    }
  }
  return best;
}

/// 屏幕比窗口还小时（极端分辨率）退到屏幕起点，避免 clamp 上下界颠倒。
double _fit(double value, double start, double end) {
  if (end <= start) return start;
  return value.clamp(start, end).toDouble();
}
