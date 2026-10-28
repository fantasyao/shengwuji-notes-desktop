import 'package:flutter/widgets.dart';

/// 正在编辑的笔记页登记处。
///
/// 主界面与速记窗共用同一个窗口和导航栈：主界面还压着编辑页时切到速记窗，
/// 小窗里会连着编辑页一起显示。切之前要先把编辑页的正文落盘、再把栈上的
/// 页面收掉；这里只负责“让它存”，收页面留在 [closePagesAboveHome] 里。
class EditorSessions {
  EditorSessions._();

  static final Set<Future<void> Function()> _flushers = {};

  /// 当前有没有编辑页开着。
  static bool get hasEditor => _flushers.isNotEmpty;

  /// 编辑页 initState 时登记，dispose 时注销。
  static void register(Future<void> Function() flush) => _flushers.add(flush);

  static void unregister(Future<void> Function() flush) =>
      _flushers.remove(flush);

  /// 让每个编辑页立刻落盘；单个保存失败只记日志，不挡着窗口切换。
  static Future<void> flushAll() async {
    for (final flush in List<Future<void> Function()>.of(_flushers)) {
      try {
        await flush();
      } catch (error) {
        debugPrint('切换窗口前保存编辑页失败：$error');
      }
    }
  }
}

/// 记录首页之上压着的页面：编辑页、回收站、设置弹窗与图片预览。
///
/// 挂在 [Navigator.observers] 上；收页面时把这些 route 交给
/// [closePagesAboveHome]。首页是第一个压进来的 route，不算在内。
class PageStackTracker extends NavigatorObserver {
  final List<Route<dynamic>> _stack = [];

  /// 首页之上的页面，从下到上。
  List<Route<dynamic>> get routesAboveHome =>
      List<Route<dynamic>>.unmodifiable(_stack.skip(1));

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (index < 0) {
      if (newRoute != null) _stack.add(newRoute);
      return;
    }
    if (newRoute == null) {
      _stack.removeAt(index);
    } else {
      _stack[index] = newRoute;
    }
  }
}

/// 收起首页之上压着的页面（编辑页、回收站、弹窗），速记窗里只剩速记页。
///
/// 编辑页离开前先存盘，等于「关闭主页时自动保存」。收页面用
/// [NavigatorState.removeRoute] 而不是 popUntil：退场动画要等出帧才走得完，
/// 主界面收起后窗口已经隐藏、不再出帧，动画会停在半路；等速记窗显示出来
/// 才继续播，小窗里就会先闪一下主界面正在编辑的那条笔记。
Future<void> closePagesAboveHome(
  NavigatorState navigator,
  Iterable<Route<dynamic>> pages,
) async {
  await EditorSessions.flushAll();
  for (final page in pages.toList().reversed) {
    if (page.isActive) navigator.removeRoute(page);
  }
}
