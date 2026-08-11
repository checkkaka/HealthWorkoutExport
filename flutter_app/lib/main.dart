import 'package:flutter/material.dart';

void main() {
  runApp(const HealthWorkoutExportApp());
}

class HealthWorkoutExportApp extends StatelessWidget {
  const HealthWorkoutExportApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '健康运动导出',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('健康运动导出')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.directions_run, size: 64),
                SizedBox(height: 16),
                Text(
                  'Flutter 迁移骨架已就绪',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 8),
                Text(
                  '后续逐步接入 Rust 核心和各平台健康数据能力。',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
