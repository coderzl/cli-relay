import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService extends ChangeNotifier {
  static const _key = 'theme_mode';
  final SharedPreferences _prefs;
  late ThemeMode _mode;

  ThemeService(this._prefs) {
    final s = _prefs.getString(_key);
    _mode = s == 'light' ? ThemeMode.light : s == 'dark' ? ThemeMode.dark : ThemeMode.system;
  }

  ThemeMode get themeMode => _mode;

  void setMode(ThemeMode m) {
    _mode = m;
    _prefs.setString(_key, m.name);
    notifyListeners();
  }

  String get label => switch (_mode) {
    ThemeMode.system => 'Auto',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };

  IconData get icon => switch (_mode) {
    ThemeMode.system => Icons.brightness_auto,
    ThemeMode.light => Icons.light_mode,
    ThemeMode.dark => Icons.dark_mode,
  };
}
