import 'package:flutter/material.dart';

import 'auto_sync_controller.dart';
import 'auto_sync_session.dart';
import 'date_range.dart';
import 'native_channels.dart';
import 'src/rust/api/simple.dart' as rust;
import 'sync_history_page.dart';
import 'workout_source.dart';

class AutoSyncPage extends StatefulWidget {
  const AutoSyncPage({
    super.key,
    required this.entrySource,
    this.selected = const [],
  });

  final WorkoutSourceId entrySource;
  final List<WorkoutActivity> selected;

  @override
  State<AutoSyncPage> createState() => _AutoSyncPageState();
}

class _AutoSyncPageState extends State<AutoSyncPage> {
  var _primary = WorkoutSourceId.healthkit;
  final _supplements = <WorkoutSourceId>{};
  var _preset = ActivityDatePreset.days7;
  var _busy = false;
  var _skipLocalHistory = true;
  DateTime _customStart = DateTime.now().subtract(const Duration(days: 7));
  DateTime _customEnd = DateTime.now();
  final _authenticated = <WorkoutSourceId, bool>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    _primary = widget.entrySource;
    _loadAuthentication();
    AutoSyncSession.instance.restore();
  }

  @override
  Widget build(BuildContext context) {
    final session = AutoSyncSession.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('自动同步'),
        actions: [
          IconButton(
            tooltip: '同步记录',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const SyncHistoryPage(),
                ),
              );
            },
            icon: const Icon(Icons.history),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (session.restoreError != null) Text(session.restoreError!),
              if (session.isRunning || session.progress.total > 0) ...[
                LinearProgressIndicator(
                  value: session.progress.total == 0
                      ? null
                      : session.progress.processed / session.progress.total,
                ),
                const SizedBox(height: 8),
                Text(
                  '${session.progress.message}  上传 ${session.progress.uploaded} · 去重 ${session.progress.deduped} · 失败 ${session.progress.failed}',
                ),
                if (session.isRunning)
                  TextButton(
                    onPressed: session.cancel,
                    child: const Text('停止同步'),
                  ),
                if (!session.isRunning)
                  Wrap(
                    spacing: 8,
                    children: [
                      if (session.canContinue)
                        TextButton(
                          onPressed: () => _restart(session, remaining: true),
                          child: const Text('继续剩余活动'),
                        ),
                      if (session.canRetry)
                        TextButton(
                          onPressed: () => _restart(session, remaining: false),
                          child: const Text('按原配置重试整批'),
                        ),
                    ],
                  ),
                const SizedBox(height: 16),
              ],
              Text('主数据源', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final source in WorkoutSourceId.values)
                    ChoiceChip(
                      label: Text(source.title),
                      selected: _primary == source,
                      onSelected:
                          session.isRunning ||
                              widget.selected.isNotEmpty ||
                              _busy ||
                              _authenticated[source] != true
                          ? null
                          : (_) => setState(() {
                              _primary = source;
                              _supplements.remove(source);
                            }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text('自动跳过已有同步记录'),
                value: _skipLocalHistory,
                onChanged: session.isRunning || _busy
                    ? null
                    : (value) => setState(() => _skipLocalHistory = value),
              ),
              Text('补源', style: Theme.of(context).textTheme.titleMedium),
              Wrap(
                spacing: 8,
                children: [
                  for (final source in WorkoutSourceId.values.where(
                    (value) => value != _primary,
                  ))
                    FilterChip(
                      label: Text(source.title),
                      selected: _supplements.contains(source),
                      onSelected:
                          session.isRunning ||
                              _busy ||
                              _authenticated[source] != true
                          ? null
                          : (selected) => setState(() {
                              if (selected) {
                                if (_supplements.length >= 2) return;
                                _supplements.add(source);
                              } else {
                                _supplements.remove(source);
                              }
                            }),
                    ),
                ],
              ),
              if (widget.selected.isEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final preset in [
                      ActivityDatePreset.today,
                      ActivityDatePreset.days7,
                      ActivityDatePreset.days30,
                      ActivityDatePreset.days90,
                      ActivityDatePreset.all,
                      ActivityDatePreset.custom,
                    ])
                      ChoiceChip(
                        label: Text(preset.title),
                        selected: _preset == preset,
                        onSelected: session.isRunning
                            ? null
                            : (_) => setState(() => _preset = preset),
                      ),
                  ],
                ),
                if (_preset == ActivityDatePreset.custom)
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: session.isRunning || _busy
                            ? null
                            : () => _selectDate(true),
                        child: Text('从 ${_dateText(_customStart)}'),
                      ),
                      TextButton(
                        onPressed: session.isRunning || _busy
                            ? null
                            : () => _selectDate(false),
                        child: Text('至 ${_dateText(_customEnd)}'),
                      ),
                    ],
                  ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text('将同步已选 ${widget.selected.length} 条活动'),
                ),
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: session.isRunning || _busy
                    ? null
                    : () => _start(session),
                icon: const Icon(Icons.sync),
                label: Text(_busy ? '准备中…' : '开始同步'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _loadAuthentication() async {
    for (final id in WorkoutSourceId.values) {
      var ready = false;
      try {
        ready = await workoutSourceFor(id).isAuthenticated();
      } catch (_) {}
      if (!mounted) return;
      setState(() => _authenticated[id] = ready);
    }
  }

  Future<void> _selectDate(bool start) async {
    final value = await showDatePicker(
      context: context,
      initialDate: start ? _customStart : _customEnd,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      helpText: start ? '选择开始日期' : '选择结束日期',
    );
    if (value == null || !mounted) return;
    setState(() {
      if (start) {
        _customStart = value;
      } else {
        _customEnd = value;
      }
    });
  }

  String _dateText(DateTime date) => '${date.year}-${date.month}-${date.day}';

  Future<void> _restart(
    AutoSyncSession session, {
    required bool remaining,
  }) async {
    setState(() => _error = null);
    try {
      Future<DuplicateDecision> prompt({
        required String title,
        required String remoteId,
        required String reason,
      }) => _askDuplicate(title, remoteId, reason);
      if (remaining) {
        await session.continueRemaining(onDuplicate: prompt);
      } else {
        await session.retryLastBatch(onDuplicate: prompt);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '恢复同步失败，请检查授权与网络后重试');
    }
  }

  Future<void> _start(AutoSyncSession session) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final primary = workoutSourceFor(_primary);
      if (!await primary.isAuthenticated()) {
        if (mounted) setState(() => _error = '${_primary.title}尚未授权或登录');
        return;
      }
      final supplementSources = <WorkoutSource>[];
      for (final id in _supplements) {
        final source = workoutSourceFor(id);
        if (!await source.isAuthenticated()) {
          throw AutoSyncUploadException('${id.title}尚未授权或登录，请取消该补源后重试');
        }
        supplementSources.add(source);
      }
      final activities = widget.selected.isNotEmpty
          ? widget.selected
          : await primary.listActivities(
              _preset.resolve(
                now: DateTime.now(),
                customStart: _customStart,
                customEnd: _customEnd,
              ),
            );
      if (activities.isEmpty) {
        if (mounted) setState(() => _error = '当前范围内没有活动');
        return;
      }
      final settings = await const StravaSettingsStore().load();
      final preferences = const PreferencesChannel();
      final enabled = await preferences.read('virtualPower.enabled') == true;
      rust.VirtualPowerFillInput? virtualPower;
      if (enabled) {
        virtualPower = rust.VirtualPowerFillInput(
          includeInertia:
              await preferences.read('virtualPower.includeInertia') != false,
          riderMassKg:
              (await preferences.read('virtualPower.riderMassKg') as num?)
                  ?.toDouble() ??
              70,
          bikeMassKg:
              (await preferences.read('virtualPower.bikeMassKg') as num?)
                  ?.toDouble() ??
              8.5,
          cda:
              (await preferences.read('virtualPower.cda') as num?)
                  ?.toDouble() ??
              0.3,
        );
      }
      if (!mounted) return;
      await session.run(
        primary: primary,
        supplements: supplementSources,
        activities: activities,
        gcjEnabled: settings.gcjCorrectionEnabled,
        skipLocalHistory: _skipLocalHistory,
        virtualPower: virtualPower,
        onDuplicate: ({required title, required remoteId, required reason}) {
          return _askDuplicate(title, remoteId, reason);
        },
      );
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AutoSyncUploadException
              ? error.message
              : '准备同步失败，请检查授权与网络后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<DuplicateDecision> _askDuplicate(
    String title,
    String remoteId,
    String reason,
  ) async {
    if (!mounted) return DuplicateDecision.skip;
    final decision = await showDialog<DuplicateDecision>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(
          '$reason\n远端 ID：$remoteId\n覆盖会先保存最终 FIT，再永久删除原 Strava 活动并上传。原活动评论、点赞和链接无法恢复；需要网页登录。',
        ),
        actions: [
          TextButton(
            onPressed: isValidStravaActivityId(remoteId)
                ? () async {
                    try {
                      await const StravaWebChannel().openActivity(remoteId);
                    } catch (_) {
                      if (mounted) setState(() => _error = '无法打开 Strava 活动');
                    }
                  }
                : null,
            child: const Text('打开远端活动'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, DuplicateDecision.skip),
            child: const Text('跳过'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, DuplicateDecision.skipAll),
            child: const Text('全部跳过'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, DuplicateDecision.overwrite),
            child: const Text('删除并覆盖此条'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, DuplicateDecision.overwriteAll),
            child: const Text('本批重复项全部覆盖'),
          ),
        ],
      ),
    );
    return decision ?? DuplicateDecision.skip;
  }
}
