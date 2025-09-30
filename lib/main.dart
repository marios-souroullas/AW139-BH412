// ignore_for_file: library_private_types_in_public_api
import 'package:flutter/material.dart';
import 'cruise_input_screen.dart';

void main() {
  runApp(const AW139CruiseApp());
}

class AW139CruiseApp extends StatelessWidget {
  const AW139CruiseApp({super.key});

  @override
  Widget build(BuildContext context) {
    final baseDark = ThemeData.dark();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AW139 Cruise Planner v4',
      theme: baseDark.copyWith(
        scaffoldBackgroundColor: Colors.black,
        canvasColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        colorScheme: baseDark.colorScheme.copyWith(
          primary: Colors.orangeAccent,
          secondary: Colors.tealAccent,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFF1E1E1E),
          labelStyle: TextStyle(color: Colors.white70),
          hintStyle: TextStyle(color: Colors.white38),
          enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.white24),
          ),
          focusedBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Colors.orangeAccent),
          ),
        ),
        textTheme: baseDark.textTheme.apply(
          bodyColor: Colors.white,
          displayColor: Colors.white,
        ),
        chipTheme: baseDark.chipTheme.copyWith(
          backgroundColor: const Color(0xFF222222),
          selectedColor: Colors.orange,
          labelStyle: const TextStyle(color: Colors.white),
          secondaryLabelStyle: const TextStyle(color: Colors.white),
        ),
      ),
      home: const CruiseInputScreen(),
    );
  }
}
