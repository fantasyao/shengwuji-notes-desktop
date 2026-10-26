/// 界面缩放：整页等比缩放，正文、按钮和间距一起变化。
///
/// 档位取桌面软件常见的 80%–150%。上限没有放到 200%，是因为速记窗只有
/// 460×400、主界面最小 880×600：再往上放大，逻辑可见区域会缩到按钮和
/// 标题都放不下的程度，反而不能用。
const int kMinZoomPercent = 80;
const int kMaxZoomPercent = 150;
const int kDefaultZoomPercent = 100;

/// 可选的缩放档位，快捷键也按这个顺序逐档切换。
const List<int> kZoomLevels = [80, 90, 100, 110, 125, 150];

/// 把任意值收拢到最近的档位：配置文件被改坏时也不会得到 37% 这样的值。
///
/// 0 或负数当作没有设置，回到默认 100%；超出范围按上下限处理。
int normalizeZoomPercent(int percent) {
  if (percent <= 0) return kDefaultZoomPercent;
  if (percent <= kMinZoomPercent) return kMinZoomPercent;
  if (percent >= kMaxZoomPercent) return kMaxZoomPercent;
  var best = kDefaultZoomPercent;
  var bestDistance = -1;
  for (final level in kZoomLevels) {
    final distance = (level - percent).abs();
    if (bestDistance < 0 || distance < bestDistance) {
      best = level;
      bestDistance = distance;
    }
  }
  return best;
}

int zoomInPercent(int current) {
  final normalized = normalizeZoomPercent(current);
  for (final level in kZoomLevels) {
    if (level > normalized) return level;
  }
  return kMaxZoomPercent;
}

int zoomOutPercent(int current) {
  final normalized = normalizeZoomPercent(current);
  for (final level in kZoomLevels.reversed) {
    if (level < normalized) return level;
  }
  return kMinZoomPercent;
}

/// 缩放比例，1.0 表示原始大小。
double zoomScale(int percent) => normalizeZoomPercent(percent) / 100;

String zoomLabel(int percent) => '${normalizeZoomPercent(percent)}%';
