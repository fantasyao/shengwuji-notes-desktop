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

/// 收起首页之上压着的页面（编辑页、回收站、弹窗）。
///
/// 速记窗复用的是同一个导航栈，不先收掉这些页面，460x400 的小窗里就会
/// 显示主界面正在编辑的那条笔记；速记窗应该永远是新建的一条。编辑页离开
/// 前先存盘，等于「关闭主页时自动保存」。
Future<void> closePagesAboveHome(NavigatorState navigator) async {
  await EditorSessions.flushAll();
  navigator.popUntil((route) => route.isFirst);
}
