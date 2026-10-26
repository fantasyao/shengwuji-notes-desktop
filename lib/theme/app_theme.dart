import 'package:flutter/material.dart';

/// 与主 App 同源的青绿色，Windows 端保持同一品牌观感。
const Color kSeedColor = Color(0xFF009688);

/// 没选自定义字体时使用的系统字体；不随安装包附带，直接走 Windows 字体。
const String kDefaultFontFamily = 'Microsoft YaHei UI';

/// 默认字体的界面叫法，设置页与恢复默认处共用。
const String kDefaultFontLabel = '微软雅黑';

/// 夜间模式用中性深灰，避免 M3 种子色把底色染成偏青的墨绿。
const Color _kDarkBackground = Color(0xFF1E2124);
const Color _kDarkSurfaceLowest = Color(0xFF191B1E);
const Color _kDarkSurfaceLow = Color(0xFF212427);
const Color _kDarkSurface = Color(0xFF26292C);
const Color _kDarkSurfaceHigh = Color(0xFF2D3134);
const Color _kDarkSurfaceHighest = Color(0xFF35393C);

/// 外观设置：跟随系统，或固定浅色 / 深色。
enum AppThemeChoice {
  system('system', '跟随系统'),
  light('light', '浅色'),
  dark('dark', '深色');

  const AppThemeChoice(this.id, this.label);

  final String id;
  final String label;

  ThemeMode get themeMode => switch (this) {
    AppThemeChoice.system => ThemeMode.system,
    AppThemeChoice.light => ThemeMode.light,
    AppThemeChoice.dark => ThemeMode.dark,
  };

  static AppThemeChoice fromId(Object? id) {
    for (final choice in values) {
      if (choice.id == id) return choice;
    }
    return AppThemeChoice.system;
  }
}

class AppTheme {
  static ThemeData light({String? fontFamily}) =>
      _build(Brightness.light, fontFamily);

  static ThemeData dark({String? fontFamily}) =>
      _build(Brightness.dark, fontFamily);

  static ThemeData _build(Brightness brightness, String? fontFamily) {
    final isDark = brightness == Brightness.dark;
    final seed = ColorScheme.fromSeed(
      seedColor: kSeedColor,
      brightness: brightness,
    );
    final scheme = isDark
        ? seed.copyWith(
            surface: _kDarkSurfaceLow,
            surfaceContainerLowest: _kDarkSurfaceLowest,
            surfaceContainerLow: _kDarkSurfaceLow,
            surfaceContainer: _kDarkSurface,
            surfaceContainerHigh: _kDarkSurfaceHigh,
            surfaceContainerHighest: _kDarkSurfaceHighest,
            onSurface: const Color(0xFFE5E7E8),
            onSurfaceVariant: const Color(0xFFA6ACAF),
            outline: const Color(0xFF6B7074),
            outlineVariant: const Color(0xFF3C4044),
          )
        : seed;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: _fontFamily(fontFamily),
      scaffoldBackgroundColor: isDark
          ? _kDarkBackground
          : const Color(0xFFF4F6F5),
      textTheme: const TextTheme(
        headlineSmall: TextStyle(fontWeight: FontWeight.w600, height: 1.3),
        titleLarge: TextStyle(fontWeight: FontWeight.w600, height: 1.35),
        titleMedium: TextStyle(fontWeight: FontWeight.w600, height: 1.4),
        bodyLarge: TextStyle(height: 1.65),
        bodyMedium: TextStyle(height: 1.6),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: isDark ? _kDarkSurface : Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.7),
        thickness: 1,
        space: 1,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          scheme.onSurface.withValues(alpha: 0.18),
        ),
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(8),
      ),
      tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 450)),
    );
  }

  /// 空值或纯空白都回到内置的微软雅黑，避免主题拿到不可用的字体名后
  /// 整页退回 Flutter 默认字体。
  static String _fontFamily(String? fontFamily) {
    final name = fontFamily?.trim();
    return name == null || name.isEmpty ? kDefaultFontFamily : name;
  }
}

/// 卡片统一的描边与底色，卡片组件与编辑器配图区共用。
class AppSurface {
  static Color card(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? _kDarkSurface
        : Colors.white;
  }

  static Color border(BuildContext context) {
    return Theme.of(
      context,
    ).colorScheme.outlineVariant.withValues(alpha: 0.65);
  }
}
