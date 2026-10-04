import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'activity_sync_status.dart';
import 'auto_sync_page.dart';
import 'date_range.dart';
import 'export_controls.dart';
import 'keep_vault.dart';
import 'native_channels.dart';
import 'src/rust/api/keep.dart' as rust;
import 'workout_export.dart';
import 'workout_source.dart';

typedef KeepLogin =
    Future<String> Function({
      required String account,
      required String password,
    });

/// Experimental, explicit one-shot login. Only the returned token enters the vault.
class KeepSourcePage extends StatefulWidget {
  const KeepSourcePage({
    super.key,
    this.login,
    this.vault = const KeepVaultChannel(),
    this.sourceFactory,
  });

  final KeepLogin? login;
  final KeepVaultChannel vault;
  final WorkoutSource Function()? sourceFactory;

  @override
  State<KeepSourcePage> createState() => _KeepSourcePageState();
}

class _KeepSourcePageState extends State<KeepSourcePage> {
  final _account = TextEditingController();
  final _password = TextEditingController();
  late final WorkoutSource _source =
      widget.sourceFactory?.call() ?? KeepWorkoutSource(vault: widget.vault);
  var _preset = ActivityDatePreset.days30;
  DateTime _customStart = DateTime.now().subtract(const Duration(days: 30));
  DateTime _customEnd = DateTime.now();
  var _configured = false;
  var _statusError = false;
  var _loading = true;
  var _loggingIn = false;
  var _savingAuthorization = false;
  var _loggingOut = false;
  var _exporting = false;
  var _sessionExpired = false;
  var _requestId = 0;
  var _loginRequest = 0;
  String? _loginHandle;
  String? _error;
  List<WorkoutActivity> _workouts = const [];
  final _selected = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_refreshConfiguration());
  }

  void _cancelSource() {
    final source = _source;
    if (source is CancellableWorkoutSource) source.cancelPending();
  }

  void _cancelLoginOperation() {
    final handle = _loginHandle;
    if (handle != null) rust.keepCancelOperation(operationHandle: handle);
  }

  @override
  void dispose() {
    ++_requestId;
    ++_loginRequest;
    _cancelSource();
    _cancelLoginOperation();
    _password.clear();
    _password.dispose();
    _account.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('Keep 跑步（实验性）', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Keep 使用非官方接口，可能随平台变更失效'),
              SizedBox(height: 4),
              Text('仅使用你自己的账号。此方式可能受平台条款限制，存在接口停用或账号受限风险。'),
              SelectableText(
                'Keep 用户协议：https://m.gotokeep.com/fd-page/document/show?param=tos',
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      if (_loading && !_configured)
        const Center(child: CircularProgressIndicator())
      else if (_statusError)
        _recoveryCard()
      else if (!_configured)
        _loginCard()
      else
        ..._activities(),
      if (_configured) ...[
        const SizedBox(height: 16),
        WorkoutExportControls(
          key: const ValueKey('keepExport'),
          activities: [
            for (final activity in _workouts)
              if (_selected.contains(activity.id)) _exportActivity(activity),
          ],
          disabled: _loggingOut || _loading || _error != null,
          onBusyChanged: (value) {
            if (mounted) setState(() => _exporting = value);
          },
          currentTimeZoneIdentifier: Platform.isWindows || Platform.isLinux
              ? null
              : const HealthKitChannel().currentTimeZoneIdentifier,
          loadOriginalFit: (activity) => _source.fetchFit(
            _workouts.firstWhere((workout) => workout.id == activity.id),
          ),
        ),
      ],
    ],
  );

  Widget _recoveryCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_error ?? '无法读取 Keep 登录状态，请重试'),
          const SizedBox(height: 8),
          const Text('安全存储可能暂时不可用，请先重试。若仍无法读取，可重置本机 Keep 登录信息后重新登录。'),
          TextButton(
            onPressed: _loggingOut || _loading
                ? null
                : () => unawaited(_refreshConfiguration()),
            child: const Text('重试读取登录状态'),
          ),
          TextButton(
            onPressed: _loggingOut || _loading
                ? null
                : () => unawaited(_resetAuthorization()),
            child: const Text('重置本机 Keep 登录信息'),
          ),
        ],
      ),
    ),
  );

  Widget _loginCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('登录 Keep 后加载室内和户外跑步'),
          const SizedBox(height: 12),
          TextField(
            key: const Key('keepAccount'),
            controller: _account,
            enabled: !_loggingIn,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: const InputDecoration(labelText: '账号 / 手机号'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('keepPassword'),
            controller: _password,
            enabled: !_loggingIn,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
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
            child: Text(_loggingIn ? '登录中…' : '登录 Keep'),
          ),
          if (_loggingIn)
            TextButton(
              onPressed: _savingAuthorization ? null : _cancelLogin,
              child: const Text('取消登录'),
            ),
          const SizedBox(height: 8),
          const Text('密码仅用于本次登录，不会保存，也不会自动重试。系统安全存储仅保留账号和登录凭据。'),
        ],
      ),
    ),
  );

  List<Widget> _activities() => [
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
            onSelected: _exporting || _loggingOut || _loading
                ? null
                : (_) {
                    setState(() => _preset = preset);
                    unawaited(_loadWorkouts());
                  },
          ),
      ],
    ),
    if (_preset == ActivityDatePreset.custom) ...[
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: _exporting || _loggingOut ? null : () => _selectDate(true),
        child: Text('开始：${_dateText(_customStart)}'),
      ),
      OutlinedButton(
        onPressed: _exporting || _loggingOut ? null : () => _selectDate(false),
        child: Text('结束：${_dateText(_customEnd)}'),
      ),
    ],
    const SizedBox(height: 8),
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
          onPressed: _loggingOut || _exporting
              ? null
              : () => unawaited(_logout()),
          child: const Text('退出登录'),
        ),
      ],
    ),
    if (_loading)
      const Center(child: CircularProgressIndicator())
    else if (_error case final error?)
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(error),
              if (_sessionExpired)
                TextButton(
                  onPressed: _loggingOut ? null : _reconnect,
                  child: const Text('重新登录'),
                ),
            ],
          ),
        ),
      )
    else if (_workouts.isEmpty)
      const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('当前时间范围内没有跑步活动'),
        ),
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
      for (final workout in _workouts) _workoutCard(workout),
      const SizedBox(height: 8),
      const Text('同步将向 Strava 上传跑步记录，可能包含路线和心率；可见范围遵循你的 Strava 账号设置。'),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: _selected.isEmpty || _exporting || _loggingOut
            ? null
            : () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AutoSyncPage(
                      entrySource: WorkoutSourceId.keep,
                      selected: [
                        for (final activity in _workouts)
                          if (_selected.contains(activity.id)) activity,
                      ],
                    ),
                  ),
                );
              },
        child: const Text('自动同步所选'),
      ),
    ],
  ];

  Widget _workoutCard(WorkoutActivity activity) => Card(
    key: ValueKey('keep-${activity.id}'),
    child: CheckboxListTile(
      value: _selected.contains(activity.id),
      onChanged: _exporting || _loggingOut
          ? null
          : (_) => setState(() {
              if (!_selected.add(activity.id)) _selected.remove(activity.id);
            }),
      title: Row(
        children: [
          const Icon(Icons.directions_run),
          const SizedBox(width: 8),
          Expanded(child: Text(activity.title)),
        ],
      ),
      secondary: IconButton(
        tooltip: '活动详情',
        icon: const Icon(Icons.info_outline),
        onPressed: _exporting || _loggingOut
            ? null
            : () => showWorkoutActivityDetails(
                context,
                sourceId: 'keep',
                sourceTitle: 'Keep',
                activityId: activity.id,
                title: activity.title,
                start: activity.start,
                end: activity.end,
                durationSeconds: activity.durationSeconds,
                distanceMeters: activity.distanceMeters,
                workout: activity,
              ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_dateText(activity.start)} · ${_durationText(activity.durationSeconds)}'
            '${activity.distanceMeters == null ? '' : ' · ${(activity.distanceMeters! / 1000).toStringAsFixed(2)} 公里'}',
          ),
          ActivitySyncBadges(sourceId: 'keep', activityId: activity.id),
        ],
      ),
    ),
  );

  Future<void> _refreshConfiguration() async {
    setState(() => _loading = true);
    final requestId = ++_requestId;
    try {
      final status = await widget.vault.status();
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _configured = status.isConfigured;
        _statusError = false;
        _loading = false;
        _error = null;
      });
      if (_configured) unawaited(_loadWorkouts());
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _statusError = true;
        _error = '无法读取 Keep 登录状态，请重试';
      });
    }
  }

  void _cancelLogin() {
    if (!_loggingIn || _savingAuthorization) return;
    ++_loginRequest;
    _cancelLoginOperation();
    _password.clear();
    setState(() {
      _loggingIn = false;
      _error = null;
    });
  }

  Future<void> _login() async {
    if (_loggingIn || _statusError || _loading || _loggingOut) return;
    final account = _account.text.trim();
    final password = _password.text;
    if (account.isEmpty || password.isEmpty) return;
    final requestId = ++_loginRequest;
    // Clear the controller before awaiting network I/O, on success and failure alike.
    _password.clear();
    setState(() {
      _loggingIn = true;
      _error = null;
    });
    try {
      final token = await (widget.login ?? _loginWithKeep)(
        account: account,
        password: password,
      );
      if (!mounted || requestId != _loginRequest) return;
      setState(() => _savingAuthorization = true);
      await widget.vault.commitAuthorization(account: account, token: token);
      if (!mounted || requestId != _loginRequest) return;
      _account.clear();
      setState(() {
        _configured = true;
        _sessionExpired = false;
        _loggingIn = false;
        _savingAuthorization = false;
      });
      await _loadWorkouts();
    } catch (_) {
      if (!mounted || requestId != _loginRequest) return;
      setState(() => _error = 'Keep 登录失败，请检查账号、密码和网络后手动重试');
    } finally {
      if (mounted && requestId == _loginRequest) {
        setState(() {
          _loggingIn = false;
          _savingAuthorization = false;
        });
      }
    }
  }

  Future<String> _loginWithKeep({
    required String account,
    required String password,
  }) async {
    final reservation = rust.keepReserveOperation(
      operationId: 'keep-login-${DateTime.now().microsecondsSinceEpoch}',
    );
    final handle = reservation.handle;
    _loginHandle = handle;
    try {
      final result = await rust.keepLogin(
        operationHandle: handle,
        account: account,
        password: password,
      );
      return result.token;
    } finally {
      if (_loginHandle == handle) _loginHandle = null;
      rust.keepReleaseOperation(operationHandle: handle);
    }
  }

  Future<void> _loadWorkouts() async {
    if (!_configured || _exporting || _loggingOut) return;
    _cancelSource();
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
      _selected.clear();
    });
    try {
      final activities = await _source.listActivities(
        _preset.resolve(
          now: DateTime.now(),
          customStart: _customStart,
          customEnd: _customEnd,
        ),
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _workouts = activities;
        _loading = false;
        _sessionExpired = false;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      // Only inspect the stable code; never display raw server or credential errors.
      final expired = error.toString().contains('KeepSessionExpired');
      setState(() {
        _loading = false;
        _sessionExpired = expired;
        _error = expired ? 'Keep 登录已失效，请重新登录' : 'Keep 跑步活动加载失败，请稍后重试';
      });
    }
  }

  void _reconnect() {
    ++_requestId;
    _cancelSource();
    _password.clear();
    setState(() {
      _configured = false;
      _loading = false;
      _sessionExpired = false;
      _workouts = const [];
      _selected.clear();
      _error = null;
    });
  }

  Future<void> _resetAuthorization() async {
    if (_loggingOut || _loading || _exporting || !_statusError) return;
    setState(() => _loggingOut = true);
    final accepted = await confirmDestructiveAction(
      context,
      title: '重置本机 Keep 登录信息？',
      message:
          '将直接删除本机 Keep 账号、登录凭据和未完成的凭据事务；其他账号、已同步的 FIT 文件和历史记录会保留。重置后需要重新登录。',
      confirmLabel: '确认重置',
    );
    if (!mounted) return;
    if (!accepted) {
      setState(() => _loggingOut = false);
      return;
    }
    ++_requestId;
    _cancelSource();
    try {
      await widget.vault.resetAuthorization();
      if (!mounted) return;
      _account.clear();
      _password.clear();
      setState(() {
        _configured = false;
        _sessionExpired = false;
        _workouts = const [];
        _selected.clear();
      });
      // Re-read before enabling login; a successful deletion does not imply the
      // secure store is currently readable (for example, a device may lock).
      await _refreshConfiguration();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '重置失败，登录信息尚未确认清除，请重试';
        });
      }
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  Future<void> _logout() async {
    if (_loggingOut || _exporting) return;
    setState(() => _loggingOut = true);
    final accepted = await confirmDestructiveAction(
      context,
      title: '退出 Keep 登录？',
      message: '将清除本机保存的 Keep 账号和登录凭据；已同步的 FIT 文件和历史记录会保留。',
      confirmLabel: '退出登录',
    );
    if (!mounted) return;
    if (!accepted) {
      setState(() => _loggingOut = false);
      return;
    }
    ++_requestId;
    _cancelSource();
    try {
      await widget.vault.clearAuthorization();
      if (!mounted) return;
      _account.clear();
      _password.clear();
      setState(() {
        _configured = false;
        _loading = false;
        _sessionExpired = false;
        _workouts = const [];
        _selected.clear();
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '退出失败，登录信息尚未确认清除，请重试';
        });
      }
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  Future<void> _selectDate(bool start) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: start ? _customStart : _customEnd,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: start ? '选择开始日期' : '选择结束日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (!mounted || selected == null) return;
    setState(() {
      if (start) {
        _customStart = selected;
      } else {
        _customEnd = selected;
      }
    });
    await _loadWorkouts();
  }

  WorkoutExportActivity _exportActivity(WorkoutActivity activity) =>
      WorkoutExportActivity(
        id: activity.id,
        sourceId: 'keep',
        title: activity.title,
        start: activity.start,
        end: activity.end,
        durationSeconds: activity.durationSeconds,
        distanceMeters: activity.distanceMeters,
      );
}

String _dateText(DateTime date) {
  final local = date.toLocal();
  String pad(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${pad(local.month)}-${pad(local.day)} ${pad(local.hour)}:${pad(local.minute)}';
}

String _durationText(double seconds) {
  final duration = Duration(seconds: seconds.round());
  return '${duration.inHours}:${duration.inMinutes.remainder(60).toString().padLeft(2, '0')}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}';
}
