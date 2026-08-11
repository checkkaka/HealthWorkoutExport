import 'package:flutter/material.dart';

import 'date_range.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() => startApp();

Future<void> startApp({Future<void> Function()? initializeRust}) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (initializeRust == null) {
    await WorkoutCoreRustLib.init();
  } else {
    await initializeRust();
  }
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
      home: const _RootTabsPage(),
    );
  }
}

class _RootTabsPage extends StatefulWidget {
  const _RootTabsPage();

  @override
  State<_RootTabsPage> createState() => _RootTabsPageState();
}

class _RootTabsPageState extends State<_RootTabsPage> {
  static const _pages = [
    _SourcePage(title: '健康训练', sourceName: '健康'),
    _SourcePage(title: '行者活动', sourceName: '行者'),
    _SourcePage(title: '顽鹿活动', sourceName: '顽鹿'),
  ];

  var _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_pages[_selectedIndex].title)),
      body: IndexedStack(index: _selectedIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() => _selectedIndex = index);
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.favorite), label: '健康'),
          NavigationDestination(icon: Icon(Icons.directions_bike), label: '行者'),
          NavigationDestination(icon: Icon(Icons.flag), label: '顽鹿'),
        ],
      ),
    );
  }
}

class _SourcePage extends StatefulWidget {
  const _SourcePage({required this.title, required this.sourceName});

  final String title;
  final String sourceName;

  @override
  State<_SourcePage> createState() => _SourcePageState();
}

class _SourcePageState extends State<_SourcePage> {
  var _preset = ActivityDatePreset.days30;
  late DateTime _customStart;
  late DateTime _customEnd;

  @override
  void initState() {
    super.initState();
    _customEnd = DateTime.now();
    _customStart = ActivityDatePreset.days7.resolve(now: _customEnd).start;
  }

  @override
  Widget build(BuildContext context) {
    final range = _preset.resolve(
      now: DateTime.now(),
      customStart: _customStart,
      customEnd: _customEnd,
    );

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('时间范围', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in ActivityDatePreset.values)
              ChoiceChip(
                label: Text(preset.title),
                selected: _preset == preset,
                onSelected: (_) => setState(() => _preset = preset),
              ),
          ],
        ),
        if (_preset == ActivityDatePreset.custom) ...[
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () => _selectDate(isStart: true),
            child: Text('开始：${_dateText(_customStart)}'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _selectDate(isStart: false),
            child: Text('结束：${_dateText(_customEnd)}'),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          '筛选区间：${_dateTimeText(range.start)} 至 '
          '${_dateTimeText(range.endExclusive)}（不含）',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const Icon(Icons.inbox_outlined, size: 40),
                const SizedBox(height: 12),
                Text(
                  '${widget.sourceName}数据接入将在后续迁移中完成',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _selectDate({required bool isStart}) async {
    final current = isStart ? _customStart : _customEnd;
    final selected = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: isStart ? '选择开始日期' : '选择结束日期',
      cancelText: '取消',
      confirmText: '确定',
      fieldLabelText: '日期',
    );
    if (selected == null || !mounted) return;
    setState(() {
      if (isStart) {
        _customStart = selected;
      } else {
        _customEnd = selected;
      }
    });
  }
}

String _dateText(DateTime date) => '${date.year}年${date.month}月${date.day}日';

String _dateTimeText(DateTime date) {
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '${_dateText(date)} $hour:$minute';
}
