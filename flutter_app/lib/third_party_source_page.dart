import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'auto_sync_page.dart';
import 'activity_sync_status.dart';
import 'date_range.dart';
import 'export_controls.dart';
import 'workout_export.dart';
import 'native_channels.dart';
import 'src/rust/api/simple.dart';
import 'workout_source.dart';

enum ThirdPartySourceType { xingzhe, onelap }

extension ThirdPartySourceTypeText on ThirdPartySourceType {
  String get title => switch (this) {
    ThirdPartySourceType.xingzhe => '行者',
    ThirdPartySourceType.onelap => '顽鹿',
  };
}

/// 仅包含列表展示字段，不携带登录密码、会话或 token。
final class ThirdPartyWorkout {
  const ThirdPartyWorkout({
    required this.id,
    required this.title,
    required this.startTimeSeconds,
    required this.durationSeconds,
    this.endTimeSeconds,
    this.distanceMeters,
  });

  final String id;
  final String title;
  final double startTimeSeconds;
  final double durationSeconds;
  final double? endTimeSeconds;
  final double? distanceMeters;
}

typedef ThirdPartyLogin =
    Future<void> Function({
      required ThirdPartySourceType source,
      required String account,
      required String password,
    });

typedef ThirdPartyLoad =
    Future<List<ThirdPartyWorkout>> Function({
      required ThirdPartySourceType source,
      required DateInterval interval,
      required String operationId,
    });

/// 行者/顽鹿的最小入口：登录后只从固定 vault 临时租约读取会话来加载列表。
class ThirdPartySourcePage extends StatefulWidget {
  const ThirdPartySourcePage({
    super.key,
    required this.source,
    this.login,
    this.load,
    this.xingzheVault = const XingzheVaultChannel(),
    this.onelapVault = const OnelapVaultChannel(),
  });

  final ThirdPartySourceType source;
  final ThirdPartyLogin? login;
  final ThirdPartyLoad? load;
  final XingzheVaultChannel xingzheVault;
  final OnelapVaultChannel onelapVault;

  @override
  State<ThirdPartySourcePage> createState() => _ThirdPartySourcePageState();
}

class _ThirdPartySourcePageState extends State<ThirdPartySourcePage> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  var _preset = ActivityDatePreset.days30;
  var _configured = false;
  var _loading = true;
  var _loggingIn = false;
  var _requestId = 0;
  CancellableWorkoutSource? _activeSource;
  var _exporting = false;
  var _loggingOut = false;
  DateTime _customStart = DateTime.now().subtract(const Duration(days: 30));
  DateTime _customEnd = DateTime.now();
  String? _error;
  List<ThirdPartyWorkout> _workouts = const [];
  final _selected = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_refreshConfiguration());
  }

  @override
  void dispose() {
    _activeSource?.cancelPending();
    _password.clear();
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '${source.title}活动',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        if (_loading && !_configured)
          const Center(child: CircularProgressIndicator())
        else if (!_configured)
          _loginCard(source)
        else
          ..._activityContent(source),
        if (_configured) ...[
          const SizedBox(height: 16),
          WorkoutExportControls(
            key: ValueKey('${source.name}Export'),
            activities: [
              for (final workout in _workouts)
                if (_selected.contains(workout.id)) _exportActivity(workout),
            ],
            onBusyChanged: (busy) => setState(() => _exporting = busy),
            disabled: _loggingOut || _loading || _error != null,
            currentTimeZoneIdentifier: Platform.isWindows || Platform.isLinux
                ? null
                : const HealthKitChannel().currentTimeZoneIdentifier,
            loadOriginalFit: (activity) =>
                workoutSourceFor(
                  source == ThirdPartySourceType.xingzhe
                      ? WorkoutSourceId.xingzhe
                      : WorkoutSourceId.onelap,
                ).fetchFit(
                  WorkoutActivity(
                    id: activity.id,
                    sourceId: source == ThirdPartySourceType.xingzhe
                        ? WorkoutSourceId.xingzhe
                        : WorkoutSourceId.onelap,
                    title: activity.title,
                    start: activity.start,
                    end: activity.end,
                    durationSeconds: activity.durationSeconds,
                    distanceMeters: activity.distanceMeters,
                  ),
                ),
          ),
        ],
      ],
    );
  }

  Widget _loginCard(ThirdPartySourceType source) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('登录${source.title}后加载活动列表'),
          const SizedBox(height: 12),
          TextField(
            key: Key('${source.name}Account'),
            controller: _account,
            enabled: !_loggingIn,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: '账号'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            key: Key('${source.name}Password'),
            controller: _password,
            enabled: !_loggingIn,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: '密码'),
            onChanged: (_) => setState(() {}),
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 8),
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed:
                _loggingIn ||
                    _account.text.trim().isEmpty ||
                    _password.text.isEmpty
                ? null
                : () => unawaited(_login()),
            child: Text(_loggingIn ? '登录中…' : '登录${source.title}'),
          ),
          const SizedBox(height: 8),
          const Text('登录密码与会话仅写入系统安全存储，页面不会显示或保留它们。'),
        ],
      ),
    ),
  );

  List<Widget> _activityContent(ThirdPartySourceType source) => [
    Text('时间范围', style: Theme.of(context).textTheme.titleSmall),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final preset in ActivityDatePreset.values)
          ChoiceChip(
            label: Text(preset.title),
            selected: _preset == preset,
            onSelected: _loading || _exporting || _loggingOut
                ? null
                : (_) {
                    setState(() => _preset = preset);
                    unawaited(_loadWorkouts());
                  },
          ),
      ],
    ),
    if (_preset == ActivityDatePreset.custom) ...[
      const SizedBox(height: 12),
      OutlinedButton(
        onPressed: _exporting || _loggingOut ? null : () => _selectDate(true),
        child: Text('开始：${_dateTimeText(_customStart)}'),
      ),
      OutlinedButton(
        onPressed: _exporting || _loggingOut ? null : () => _selectDate(false),
        child: Text('结束：${_dateTimeText(_customEnd)}'),
      ),
    ],
    const SizedBox(height: 12),
    Row(
      children: [
        TextButton.icon(
          onPressed: _loading || _exporting || _loggingOut
              ? null
              : () => unawaited(_loadWorkouts()),
          icon: const Icon(Icons.refresh),
          label: const Text('刷新'),
        ),
        const Spacer(),
        TextButton(
          onPressed: _loggingIn || _exporting || _loggingOut
              ? null
              : () => unawaited(_logout()),
          child: const Text('退出登录'),
        ),
      ],
    ),
    if (_loading)
      const Center(child: CircularProgressIndicator())
    else if (_error case final error?)
      _errorCard(error)
    else if (_workouts.isEmpty)
      const Card(
        child: Padding(padding: EdgeInsets.all(16), child: Text('当前时间范围内没有活动')),
      )
    else ...[
      Row(
        children: [
          Text('已选择 ${_selected.length}/${_workouts.length}'),
          const Spacer(),
          TextButton(
            onPressed: _exporting || _loggingOut
                ? null
                : () => setState(() {
                    _selected
                      ..clear()
                      ..addAll(_workouts.map((workout) => workout.id));
                  }),
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: _exporting || _loggingOut
                ? null
                : () => setState(_selected.clear),
            child: const Text('取消全选'),
          ),
        ],
      ),
      for (final workout in _workouts) _workoutCard(workout, source),
      FilledButton(
        onPressed: _selected.isEmpty || _exporting || _loggingOut
            ? null
            : () {
                final sourceId = source == ThirdPartySourceType.xingzhe
                    ? WorkoutSourceId.xingzhe
                    : WorkoutSourceId.onelap;
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AutoSyncPage(
                      entrySource: sourceId,
                      selected: [
                        for (final workout in _workouts)
                          if (_selected.contains(workout.id))
                            WorkoutActivity(
                              id: workout.id,
                              sourceId: sourceId,
                              title: workout.title,
                              start: DateTime.fromMillisecondsSinceEpoch(
                                (workout.startTimeSeconds * 1000).round(),
                              ),
                              end: DateTime.fromMillisecondsSinceEpoch(
                                ((workout.endTimeSeconds ??
                                            (workout.startTimeSeconds +
                                                workout.durationSeconds)) *
                                        1000)
                                    .round(),
                              ),
                              durationSeconds: workout.durationSeconds,
                              distanceMeters: workout.distanceMeters,
                            ),
                      ],
                    ),
                  ),
                );
              },
        child: const Text('自动同步所选'),
      ),
      const SizedBox(height: 16),
      const SizedBox(height: 16),
    ],
  ];

  Widget _errorCard(String error) => Card(
    child: Padding(padding: const EdgeInsets.all(16), child: Text(error)),
  );

  Widget _workoutCard(ThirdPartyWorkout workout, ThirdPartySourceType source) {
    final start = DateTime.fromMillisecondsSinceEpoch(
      (workout.startTimeSeconds * 1000).round(),
    );
    final distance = workout.distanceMeters;
    return Card(
      key: ValueKey('${source.name}-${workout.id}'),
      child: CheckboxListTile(
        value: _selected.contains(workout.id),
        onChanged: _exporting || _loggingOut
            ? null
            : (_) => setState(() {
                if (!_selected.add(workout.id)) _selected.remove(workout.id);
              }),
        title: Text(workout.title),
        secondary: IconButton(
          tooltip: '活动详情',
          icon: const Icon(Icons.info_outline),
          onPressed: () => showWorkoutActivityDetails(
            context,
            sourceId: source.name,
            sourceTitle: source.title,
            activityId: workout.id,
            title: workout.title,
            start: start,
            end: workout.endTimeSeconds == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    (workout.endTimeSeconds! * 1000).round(),
                  ),
            durationSeconds: workout.durationSeconds,
            distanceMeters: distance,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_dateTimeText(start)} · ${_durationText(workout.durationSeconds)}'
              '${distance == null ? '' : ' · ${(distance / 1000).toStringAsFixed(2)} 公里'}',
            ),
            ActivitySyncBadges(sourceId: source.name, activityId: workout.id),
          ],
        ),
      ),
    );
  }

  Future<void> _refreshConfiguration() async {
    try {
      final configured = switch (widget.source) {
        ThirdPartySourceType.xingzhe => await widget.xingzheVault.status().then(
          (status) => status.isConfigured,
        ),
        ThirdPartySourceType.onelap => await widget.onelapVault.status().then(
          (status) => status.isConfigured,
        ),
      };
      if (!mounted) return;
      setState(() {
        _configured = configured;
        _loading = false;
        _error = null;
      });
      if (configured) unawaited(_loadWorkouts());
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '无法读取${widget.source.title}登录状态';
        });
      }
    }
  }

  WorkoutExportActivity _exportActivity(ThirdPartyWorkout workout) =>
      WorkoutExportActivity(
        id: workout.id,
        sourceId: widget.source.name,
        title: workout.title,
        start: DateTime.fromMillisecondsSinceEpoch(
          (workout.startTimeSeconds * 1000).round(),
        ),
        end: DateTime.fromMillisecondsSinceEpoch(
          ((workout.endTimeSeconds ??
                      (workout.startTimeSeconds + workout.durationSeconds)) *
                  1000)
              .round(),
        ),
        durationSeconds: workout.durationSeconds,
        distanceMeters: workout.distanceMeters,
      );

  Future<void> _selectDate(bool isStart) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: isStart ? _customStart : _customEnd,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: isStart ? '选择开始日期' : '选择结束日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (selected == null || !mounted) return;
    setState(() {
      if (isStart) {
        _customStart = selected;
      } else {
        _customEnd = selected;
      }
    });
    await _loadWorkouts();
  }

  Future<void> _logout() async {
    if (_loggingOut || _exporting) return;
    setState(() => _loggingOut = true);
    final accepted = await confirmDestructiveAction(
      context,
      title: '退出${widget.source.title}登录？',
      message: '将清除本机保存的账号、密码和会话；再次使用此数据源需要重新登录。',
      confirmLabel: '退出登录',
    );
    if (!mounted) return;
    if (!accepted) {
      setState(() => _loggingOut = false);
      return;
    }
    _activeSource?.cancelPending();
    ++_requestId;
    try {
      switch (widget.source) {
        case ThirdPartySourceType.xingzhe:
          await widget.xingzheVault.clearAuthorization();
        case ThirdPartySourceType.onelap:
          await widget.onelapVault.clearAuthorization();
      }
      if (!mounted) return;
      _account.clear();
      _password.clear();
      setState(() {
        _configured = false;
        _workouts = const [];
        _selected.clear();
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '退出失败，登录信息尚未确认清除，请重试');
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  Future<void> _login() async {
    if (_loggingIn) return;
    final account = _account.text.trim();
    final password = _password.text;
    if (account.isEmpty || password.isEmpty) return;
    setState(() {
      _loggingIn = true;
      _error = null;
    });
    try {
      await (widget.login ?? _loginWithVault)(
        source: widget.source,
        account: account,
        password: password,
      );
      _password.clear();
      if (!mounted) return;
      setState(() => _configured = true);
      await _loadWorkouts();
    } catch (_) {
      _password.clear();
      if (mounted) {
        setState(() => _error = '${widget.source.title}登录失败，请检查账号、密码和网络');
      }
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _loadWorkouts() async {
    if (!_configured || _exporting || _loggingOut) return;
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final workouts = await (widget.load ?? _loadWithVault)(
        source: widget.source,
        interval: _preset.resolve(
          now: DateTime.now(),
          customStart: _customStart,
          customEnd: _customEnd,
        ),
        operationId:
            '${widget.source.name}-$requestId-${DateTime.now().microsecondsSinceEpoch}',
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _workouts = workouts;
        _selected.clear();
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _error = '${widget.source.title}活动加载失败，请稍后重试';
      });
    }
  }

  Future<void> _loginWithVault({
    required ThirdPartySourceType source,
    required String account,
    required String password,
  }) async {
    switch (source) {
      case ThirdPartySourceType.xingzhe:
        final sessionId = await xingzheLogin(
          account: account,
          password: password,
        );
        await widget.xingzheVault.commitAuthorization(
          account: account,
          password: password,
          sessionId: sessionId,
        );
      case ThirdPartySourceType.onelap:
        final session = await onelapLogin(account: account, password: password);
        await widget.onelapVault.commitAuthorization(
          account: account,
          password: password,
          token: session.token,
          uid: session.uid,
          refreshToken: session.refreshToken,
        );
    }
  }

  Future<List<ThirdPartyWorkout>> _loadWithVault({
    required ThirdPartySourceType source,
    required DateInterval interval,
    required String operationId,
  }) async {
    final workoutSource = source == ThirdPartySourceType.xingzhe
        ? XingzheWorkoutSource(vault: widget.xingzheVault)
        : OnelapWorkoutSource(vault: widget.onelapVault);
    _activeSource?.cancelPending();
    _activeSource = workoutSource;
    final workouts = await workoutSource.listActivities(interval);
    if (identical(_activeSource, workoutSource)) _activeSource = null;
    return [
      for (final workout in workouts)
        ThirdPartyWorkout(
          id: workout.id,
          title: workout.title,
          startTimeSeconds: workout.start.millisecondsSinceEpoch / 1000,
          endTimeSeconds: workout.end.millisecondsSinceEpoch / 1000,
          durationSeconds: workout.durationSeconds,
          distanceMeters: workout.distanceMeters,
        ),
    ];
  }
}

String _dateTimeText(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '${date.year}-$month-$day $hour:$minute';
}

String _durationText(double seconds) {
  final duration = Duration(seconds: seconds.round());
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  return '$hours:$minutes';
}
