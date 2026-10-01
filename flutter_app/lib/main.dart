import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'auto_sync_page.dart';
import 'activity_sync_status.dart';
import 'auto_sync_session.dart';
import 'date_range.dart';
import 'export_controls.dart';
import 'fit_merge_page.dart';
import 'native_channels.dart';
import 'src/rust/frb_generated.dart';
import 'strava_settings_page.dart';
import 'sync_history_page.dart';
import 'third_party_source_page.dart';
import 'workout_export.dart';
import 'workout_source.dart';

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
  const HealthWorkoutExportApp({
    super.key,
    this.healthKit,
    this.stravaSettingsEnabled,
  });

  final HealthKitChannel? healthKit;
  final bool? stravaSettingsEnabled;

  @override
  Widget build(BuildContext context) {
    final platformHealthKit =
        healthKit ??
        (defaultTargetPlatform == TargetPlatform.iOS ||
                defaultTargetPlatform == TargetPlatform.macOS ||
                defaultTargetPlatform == TargetPlatform.android
            ? const HealthKitChannel()
            : null);
    return MaterialApp(
      title: '健康运动导出',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: _RootTabsPage(
        healthKit: platformHealthKit,
        stravaSettingsEnabled:
            stravaSettingsEnabled ??
            (defaultTargetPlatform == TargetPlatform.iOS ||
                defaultTargetPlatform == TargetPlatform.macOS ||
                defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.windows),
      ),
    );
  }
}

class _RootTabsPage extends StatefulWidget {
  const _RootTabsPage({
    required this.healthKit,
    required this.stravaSettingsEnabled,
  });

  final HealthKitChannel? healthKit;
  final bool stravaSettingsEnabled;

  @override
  State<_RootTabsPage> createState() => _RootTabsPageState();
}

class _RootTabsPageState extends State<_RootTabsPage> {
  var _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      _SourcePage(
        title: '健康训练',
        sourceName: '健康',
        healthKit: widget.healthKit,
        unavailableMessage: widget.healthKit == null
            ? '此平台不支持 HealthKit'
            : null,
      ),
      const ThirdPartySourcePage(source: ThirdPartySourceType.xingzhe),
      const ThirdPartySourcePage(source: ThirdPartySourceType.onelap),
    ];
    const titles = ['健康训练', '行者活动', '顽鹿活动'];
    return ListenableBuilder(
      listenable: AutoSyncSession.instance,
      builder: (context, _) {
        final session = AutoSyncSession.instance;
        return Scaffold(
          appBar: AppBar(
            title: Text(titles[_selectedIndex]),
            actions: [
              IconButton(
                tooltip: '合并 FIT',
                icon: const Icon(Icons.merge_type),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const FitMergePage(),
                    ),
                  );
                },
              ),
              IconButton(
                tooltip: '同步记录',
                icon: const Icon(Icons.history),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SyncHistoryPage(),
                    ),
                  );
                },
              ),
              if (widget.stravaSettingsEnabled)
                IconButton(
                  tooltip: 'Strava 设置',
                  icon: const Icon(Icons.settings),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const StravaSettingsPage(),
                      ),
                    );
                  },
                ),
            ],
          ),
          body: Stack(
            children: [
              IndexedStack(
                index: _selectedIndex,
                children: [
                  for (var index = 0; index < pages.length; index++)
                    TickerMode(
                      enabled: index == _selectedIndex,
                      child: pages[index],
                    ),
                ],
              ),
              if (session.isRunning)
                Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Material(
                      elevation: 2,
                      borderRadius: BorderRadius.circular(24),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              session.progress.message.isEmpty
                                  ? '同步进行中…'
                                  : session.progress.message,
                            ),
                            TextButton(
                              onPressed: session.cancel,
                              child: const Text('停止'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) {
              setState(() => _selectedIndex = index);
            },
            destinations: const [
              NavigationDestination(icon: Icon(Icons.favorite), label: '健康'),
              NavigationDestination(
                icon: Icon(Icons.directions_bike),
                label: '行者',
              ),
              NavigationDestination(icon: Icon(Icons.flag), label: '顽鹿'),
            ],
          ),
        );
      },
    );
  }
}

class _SourcePage extends StatefulWidget {
  const _SourcePage({
    required this.title,
    required this.sourceName,
    this.healthKit,
    this.unavailableMessage,
  });

  final String title;
  final String sourceName;
  final HealthKitChannel? healthKit;
  final String? unavailableMessage;

  @override
  State<_SourcePage> createState() => _SourcePageState();
}

class _SourcePageState extends State<_SourcePage> {
  var _preset = ActivityDatePreset.days30;
  late DateTime _customStart;
  late DateTime _customEnd;
  var _loading = false;
  var _workouts = const <HealthWorkoutSummary>[];
  var _selectedWorkoutIds = <String>{};
  String? _error;
  var _requestId = 0;
  Future<bool>? _authorization;
  var _exporting = false;

  @override
  void initState() {
    super.initState();
    _customEnd = DateTime.now();
    _customStart = ActivityDatePreset.days7.resolve(now: _customEnd).start;
    if (widget.healthKit != null) {
      _loading = true;
      unawaited(_loadWorkouts(authorize: true));
    }
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
                onSelected: _exporting
                    ? null
                    : (_) {
                        setState(() => _preset = preset);
                        if (widget.healthKit != null) {
                          unawaited(_loadWorkouts());
                        }
                      },
              ),
          ],
        ),
        if (_preset == ActivityDatePreset.custom) ...[
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _exporting ? null : () => _selectDate(isStart: true),
            child: Text('开始：${_dateText(_customStart)}'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _exporting ? null : () => _selectDate(isStart: false),
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
        if (widget.healthKit == null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  const Icon(Icons.inbox_outlined, size: 40),
                  const SizedBox(height: 12),
                  Text(
                    widget.unavailableMessage ??
                        '${widget.sourceName}数据接入将在后续迁移中完成',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          )
        else
          ..._healthContent(),
        if (widget.healthKit != null) ...[
          const SizedBox(height: 16),
          WorkoutExportControls(
            key: const ValueKey('healthExport'),
            disabled: _loading || _error != null,
            activities: [
              for (final workout in _workouts)
                if (_selectedWorkoutIds.contains(workout.uuid))
                  WorkoutExportActivity.health(workout),
            ],
            loadHealthBundle: (id) async =>
                (await widget.healthKit!.fetchWorkoutBundles([id])).single,
            currentTimeZoneIdentifier:
                widget.healthKit!.currentTimeZoneIdentifier,
            onBusyChanged: (busy) => setState(() => _exporting = busy),
          ),
        ],
      ],
    );
  }

  List<Widget> _healthContent() {
    if (_loading) {
      return const [Center(child: CircularProgressIndicator())];
    }
    if (_error != null) {
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text('加载失败：$_error', textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => unawaited(_loadWorkouts(authorize: true)),
                  child: const Text('重试'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => unawaited(_openSettings()),
                  child: const Text('打开设置'),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    if (_workouts.isEmpty) {
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const Text('当前时间范围内没有训练'),
                const SizedBox(height: 8),
                const Text('如果尚未允许读取健康数据，请前往系统设置检查权限。'),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => unawaited(_openSettings()),
                  child: const Text('打开设置'),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    return [
      Row(
        children: [
          Text('已选择 ${_selectedWorkoutIds.length}/${_workouts.length}'),
          const Spacer(),
          TextButton(onPressed: _selectAll, child: const Text('全选')),
          TextButton(onPressed: _clearSelection, child: const Text('取消全选')),
        ],
      ),
      for (final workout in _workouts)
        Card(
          child: CheckboxListTile(
            key: ValueKey(workout.uuid),
            value: _selectedWorkoutIds.contains(workout.uuid),
            onChanged: (_) => _toggleWorkout(workout.uuid),
            title: Text(workout.activityName),
            secondary: IconButton(
              tooltip: '活动详情',
              icon: const Icon(Icons.info_outline),
              onPressed: () => showWorkoutActivityDetails(
                context,
                sourceId: 'healthkit',
                sourceTitle: '健康',
                activityId: workout.uuid,
                title: workout.activityName,
                start: DateTime.fromMillisecondsSinceEpoch(workout.startMs),
                end: DateTime.fromMillisecondsSinceEpoch(workout.endMs),
                durationSeconds: workout.durationSeconds,
                distanceMeters: workout.totalDistanceMeters,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_dateTimeText(DateTime.fromMillisecondsSinceEpoch(workout.startMs))}'
                  '${workout.sourceName == null ? '' : ' · ${workout.sourceName}'}',
                ),
                ActivitySyncBadges(
                  sourceId: 'healthkit',
                  activityId: workout.uuid,
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 16),
      const SizedBox(height: 24),
      const Divider(),
      const SizedBox(height: 16),
      Text('同步到 Strava', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      const Text('在自动同步页确认主补源、上传方式和重复活动处理后开始'),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _selectedWorkoutIds.isEmpty || _exporting
            ? null
            : _openAutoSync,
        icon: const Icon(Icons.sync),
        label: const Text('自动同步所选'),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _exporting ? null : _openAutoSync,
        icon: const Icon(Icons.sync_alt),
        label: const Text('完整自动同步'),
      ),
    ];
  }

  Future<void> _loadWorkouts({bool authorize = false}) async {
    final healthKit = widget.healthKit;
    if (healthKit == null || _exporting) return;
    if (authorize) _authorization = _requestAuthorization(healthKit);
    final authorization = _authorization;
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (authorization != null && !await authorization) {
        if (!mounted || requestId != _requestId) return;
        setState(() {
          _loading = false;
          _error = '此设备不支持 HealthKit';
        });
        return;
      }
      if (!mounted || requestId != _requestId) return;
      final range = _preset.resolve(
        now: DateTime.now(),
        customStart: _customStart,
        customEnd: _customEnd,
      );
      final workouts = await healthKit.listWorkouts(
        start: range.start,
        endExclusive: range.endExclusive,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _workouts = workouts;
        _selectedWorkoutIds = <String>{};
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<bool> _requestAuthorization(HealthKitChannel healthKit) async {
    if (!await healthKit.isAvailable()) return false;
    await healthKit.requestAuthorization();
    return true;
  }

  Future<void> _openSettings() async {
    try {
      await widget.healthKit?.openSettings();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  void _toggleWorkout(String uuid) {
    setState(() {
      if (!_selectedWorkoutIds.add(uuid)) _selectedWorkoutIds.remove(uuid);
    });
  }

  void _selectAll() {
    setState(() {
      _selectedWorkoutIds = _workouts.map((workout) => workout.uuid).toSet();
    });
  }

  void _clearSelection() => setState(_selectedWorkoutIds.clear);

  void _openAutoSync() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AutoSyncPage(
          entrySource: WorkoutSourceId.healthkit,
          selected: [
            for (final workout in _workouts)
              if (_selectedWorkoutIds.contains(workout.uuid))
                WorkoutActivity(
                  id: workout.uuid,
                  sourceId: WorkoutSourceId.healthkit,
                  title: workout.activityName,
                  start: DateTime.fromMillisecondsSinceEpoch(workout.startMs),
                  end: DateTime.fromMillisecondsSinceEpoch(workout.endMs),
                  durationSeconds: workout.durationSeconds,
                  distanceMeters: workout.totalDistanceMeters,
                ),
          ],
        ),
      ),
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
    if (widget.healthKit != null) unawaited(_loadWorkouts());
  }
}

String _dateText(DateTime date) => '${date.year}年${date.month}月${date.day}日';

String _dateTimeText(DateTime date) {
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '${_dateText(date)} $hour:$minute';
}
