import 'package:flutter/material.dart';
import 'camera_gesture_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gesta z kamery',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const CameraGesturePage(),
    );
  }
}

// Původní ukázka s GestureDetector byla odstraněna – domovská obrazovka nyní
// rovnou spouští rozpoznávání gest z kamery pomocí ML Kit.
