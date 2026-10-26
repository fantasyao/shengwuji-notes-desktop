import 'package:flutter/material.dart';

import '../theme/app_zoom.dart';

/// 把页面内容按缩放档位整体等比缩放，标题栏留在外面保持固定大小。
///
/// 交给子树的逻辑尺寸是“可用尺寸 ÷ 缩放比”，再用 Transform 放大或缩小：
/// 放大时内容会按逻辑宽度重新排版，而不是被裁掉；缩小时也能铺满窗口。
/// MediaQuery 的尺寸一并改成逻辑尺寸，弹窗、下拉菜单才会按实际可见区域
/// 计算大小与位置。
///
/// 树结构必须与缩放比无关（100% 时也保留这层），否则切换档位会重建
/// Navigator，正在编辑的页面和草稿都会丢。
class ZoomHost extends StatelessWidget {
  const ZoomHost({super.key, required this.percent, required this.child});

  final int percent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = zoomScale(percent);
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth / scale;
        final height = constraints.maxHeight / scale;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            minHeight: 0,
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: height,
                child: MediaQuery(
                  data: media.copyWith(
                    size: Size(width, height),
                    padding: EdgeInsets.zero,
                    viewPadding: EdgeInsets.zero,
                    viewInsets: EdgeInsets.zero,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
