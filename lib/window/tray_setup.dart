import 'package:tray_manager/tray_manager.dart';

/// 托盘图标路径，与 `pubspec.yaml` 里登记的 assets 一致。
const String trayIconPath = 'assets/tray_icon.ico';

/// 托盘悬停提示。
///
/// tray_manager 0.5.3 的 Windows 插件首次添加图标时，会把未初始化的
/// `NOTIFYICONDATA.szTip` 当提示文字一起注册（`_ApplyIcon` 先备份旧值、
/// 再带 `NIF_TIP` 重新添加）。启动时显式设一次，覆盖掉那段乱码内存。
const String trayTooltip = '声物记电脑版';

/// 启动托盘：加图标、补悬停提示、挂右键菜单。
///
/// 顺序不能换：`setToolTip` 走的是 `NIM_MODIFY`，图标还没添加时无处可改。
Future<void> setUpTray({required Menu menu}) async {
  await trayManager.setIcon(trayIconPath);
  await trayManager.setToolTip(trayTooltip);
  await trayManager.setContextMenu(menu);
}
