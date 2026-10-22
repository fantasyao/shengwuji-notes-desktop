import 'package:flutter/material.dart';

/// 与主 App 同源的青绿色，Windows 端保持同一品牌观感。
const Color kSeedColor = Color(0xFF009688);

class AppTheme {
  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: kSeedColor,
      brightness: brightness,
    );
    final isDark = brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: 'Microsoft YaHei UI',
      scaffoldBackgroundColor: isDark
          ? const Color(0xFF0F1413)
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
        fillColor: isDark ? const Color(0xFF1A201F) : Colors.white,
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
}

/// 卡片统一的描边与底色，卡片组件与编辑器配图区共用。
class AppSurface {
  static Color card(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF191F1E)
        : Colors.white;
  }

  static Color border(BuildContext context) {
    return Theme.of(
      context,
    ).colorScheme.outlineVariant.withValues(alpha: 0.65);
  }
}
