import 'package:flutter/material.dart';

import 'screens/map_home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HorizonMotoGpsApp());
}

class HorizonMotoGpsApp extends StatelessWidget {
  const HorizonMotoGpsApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFF6600),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      title: 'Horizon Moto GPS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0D0F14),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF141821),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: const MapHomeScreen(),
    );
  }
}
