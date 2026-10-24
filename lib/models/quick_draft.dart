/// 速记草稿：正文 + 已经落盘、但还没挂到笔记上的图片名。
///
/// 图片在粘贴时就写进数据目录，草稿只记文件名；保存时整体交给新建的笔记，
/// 收起或下次呼出都能继续带着这些图片。
class QuickDraft {
  const QuickDraft({this.text = '', this.images = const []});

  final String text;
  final List<String> images;

  bool get isEmpty => text.trim().isEmpty && images.isEmpty;
}
