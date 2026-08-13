import 'dart:async';

import 'package:flutter/material.dart';

import 'date_range.dart';
import 'native_channels.dart';
import 'src/rust/api/simple.dart';

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
    this.distanceMeters,
  });

  final String id;
  final String title;
  final double startTimeSeconds;
  final double durationSeconds;
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
  String? _error;
  List<ThirdPartyWorkout> _workouts = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_refreshConfiguration());
  }

  @override
  void dispose() {
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
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (!_configured)
          _loginCard(source)
        else
          ..._activityContent(source),
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
        for (final preset in ActivityDatePreset.values.where(
          (preset) => preset != ActivityDatePreset.custom,
        ))
          ChoiceChip(
            label: Text(preset.title),
            selected: _preset == preset,
            onSelected: _loading
                ? null
                : (_) {
                    setState(() => _preset = preset);
                    unawaited(_loadWorkouts());
                  },
          ),
      ],
    ),
    const SizedBox(height: 12),
    Row(
      children: [
        TextButton.icon(
          onPressed: _loading ? null : () => unawaited(_loadWorkouts()),
          icon: const Icon(Icons.refresh),
          label: const Text('刷新'),
        ),
        const Spacer(),
        TextButton(
          onPressed: _loggingIn
              ? null
              : () => setState(() {
                  _configured = false;
                  _workouts = const [];
                  _error = null;
                }),
          child: const Text('重新登录'),
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
    else
      for (final workout in _workouts) _workoutCard(workout, source),
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
      child: ListTile(
        leading: const Icon(Icons.directions_bike),
        title: Text(workout.title),
        subtitle: Text(
          '${_dateTimeText(start)} · ${_durationText(workout.durationSeconds)}'
          '${distance == null ? '' : ' · ${(distance / 1000).toStringAsFixed(2)} 公里'}',
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
    if (!_configured) return;
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final workouts = await (widget.load ?? _loadWithVault)(
        source: widget.source,
        interval: _preset.resolve(now: DateTime.now()),
        operationId:
            '${widget.source.name}-$requestId-${DateTime.now().microsecondsSinceEpoch}',
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _workouts = workouts;
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
        );
    }
  }

  Future<List<ThirdPartyWorkout>> _loadWithVault({
    required ThirdPartySourceType source,
    required DateInterval interval,
    required String operationId,
  }) async {
    final fromSeconds = interval.start.millisecondsSinceEpoch ~/ 1000;
    final toSeconds = interval.endExclusive.millisecondsSinceEpoch ~/ 1000;
    switch (source) {
      case ThirdPartySourceType.xingzhe:
        final lease = await widget.xingzheVault.lease();
        final sessionId = lease.sessionId;
        if (sessionId == null) throw StateError('缺少行者会话');
        final reservation = xingzheReserveList(operationId: operationId);
        final workouts = await xingzheListWorkouts(
          operationHandle: reservation.handle,
          sessionId: sessionId,
          fromSeconds: fromSeconds,
          toSeconds: toSeconds,
        );
        return [
          for (final workout in workouts)
            ThirdPartyWorkout(
              id: workout.id,
              title: workout.title,
              startTimeSeconds: workout.startTimeSeconds,
              durationSeconds: workout.durationSeconds,
              distanceMeters: workout.distanceMeters,
            ),
        ];
      case ThirdPartySourceType.onelap:
        final lease = await widget.onelapVault.lease();
        final token = lease.token;
        final uid = lease.uid;
        if (token == null || uid == null) throw StateError('缺少顽鹿会话');
        final workouts = await onelapListWorkouts(
          token: token,
          uid: uid,
          fromSeconds: fromSeconds,
          toSeconds: toSeconds,
          timezoneOffsetSeconds: DateTime.now().timeZoneOffset.inSeconds,
        );
        return [
          for (final workout in workouts)
            ThirdPartyWorkout(
              id: workout.id,
              title: workout.title,
              startTimeSeconds: workout.startTimeSeconds,
              durationSeconds: workout.durationSeconds,
              distanceMeters: workout.distanceMeters,
            ),
        ];
    }
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
