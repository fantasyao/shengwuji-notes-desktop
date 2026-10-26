import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_desktop/theme/app_theme.dart';

void main() {
  test('主题把自定义字体应用到文字样式', () {
    final theme = AppTheme.light(fontFamily: 'SimSun');
    expect(theme.textTheme.bodyMedium?.fontFamily, 'SimSun');
    expect(theme.textTheme.titleLarge?.fontFamily, 'SimSun');
  });

  test('空字体名回退微软雅黑', () {
    expect(
      AppTheme.dark().textTheme.bodyMedium?.fontFamily,
      kDefaultFontFamily,
    );
    expect(
      AppTheme.light(fontFamily: '   ').textTheme.bodyMedium?.fontFamily,
      kDefaultFontFamily,
    );
  });
}
