import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// 用系统默认浏览器打开 [uri]，返回是否已交给系统处理。
///
/// 桌面端只跑 Windows，直接走 ShellExecuteW：
/// - 不引入 url_launcher 插件，和现有的 win32 依赖保持一致；
/// - ShellExecute 返回值大于 32 才算成功，其余是错误码；
/// - 链接里出现引号等字符也不经过命令行拼接，避免被当成命令参数。
bool openUrlInBrowser(Uri uri) {
  if (!Platform.isWindows) return false;
  final operation = 'open'.toNativeUtf16();
  final target = uri.toString().toNativeUtf16();
  try {
    final result = ShellExecute(
      null,
      PCWSTR(operation),
      PCWSTR(target),
      null,
      null,
      SW_SHOWNORMAL,
    );
    return result.address > 32;
  } finally {
    malloc.free(operation);
    malloc.free(target);
  }
}
