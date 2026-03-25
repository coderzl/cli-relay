import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/relay_client.dart';
import 'services/theme_service.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // [FM24] 不硬编码 statusbar 颜色，让主题控制
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
  ));

  final prefs = await SharedPreferences.getInstance();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => RelayClient()),
        ChangeNotifierProvider(create: (_) => ThemeService(prefs)),
      ],
      child: const CliRelayApp(),
    ),
  );
}

class CliRelayApp extends StatelessWidget {
  const CliRelayApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeSvc = context.watch<ThemeService>();

    return MaterialApp(
      title: 'CLI Relay',
      debugShowCheckedModeBanner: false,
      themeMode: themeSvc.themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const HomeScreen(),
    );
  }
}
