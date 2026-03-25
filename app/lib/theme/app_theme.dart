import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTheme {
  static const blue = Color(0xFF007AFF);
  static const green = Color(0xFF34C759);
  static const orange = Color(0xFFFF9500);
  static const red = Color(0xFFFF3B30);
  static const purple = Color(0xFFAF52DE);

  static ThemeData light() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(seedColor: blue, brightness: Brightness.light),
        scaffoldBackgroundColor: const Color(0xFFF2F2F7),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          color: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 0.5,
          centerTitle: true,
          backgroundColor: Color(0xFFF2F2F7),
          surfaceTintColor: Colors.transparent,
          // [FM24] 浅色主题 → 深色状态栏图标
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
          ),
          titleTextStyle: TextStyle(
            color: Colors.black,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        dividerTheme: const DividerThemeData(color: Color(0xFFE5E5EA), thickness: 0.5),
      );

  static ThemeData dark() => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0A84FF), brightness: Brightness.dark),
        scaffoldBackgroundColor: Colors.black,
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          color: const Color(0xFF1C1C1E),
        ),
        appBarTheme: const AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 0.5,
          centerTitle: true,
          backgroundColor: Colors.black,
          surfaceTintColor: Colors.transparent,
          // [FM24] 深色主题 → 浅色状态栏图标
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
          ),
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
        dividerTheme: const DividerThemeData(color: Color(0xFF38383A), thickness: 0.5),
      );
}
