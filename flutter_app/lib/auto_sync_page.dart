import 'package:flutter/material.dart';

import 'auto_sync_controller.dart';
import 'auto_sync_session.dart';
import 'recovery_legacy_dialog.dart';
import 'recovery_batch_checkpoint.dart';
import 'sync_preview_models.dart';
import 'sync_preview_page.dart';
import 'sync_result_messages.dart';
import 'sync_destination_flow.dart';
import 'apple_health_import.dart';
import 'apple_health_import_dialog.dart';
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
    this.initialPreviewPolicy,
    this.initialSkipLocalHistory = true,
  });

  final WorkoutSourceId entrySource;
  final List<WorkoutActivity> selected;
  final SyncPreviewPolicy? initialPreviewPolicy;
  final bool initialSkipLocalHistory;

  @override
  State<AutoSyncPage> createState() => _AutoSyncPageState();
}

class _AutoSyncPageState extends State<AutoSyncPage> {
  var _primary = WorkoutSourceId.healthkit;
  final _supplements = <WorkoutSourceId>{};
  var _preset = ActivityDatePreset.days7;
  var _busy = false;
  var _skipLocalHistory = true;
  final _customTitle = TextEditingController();
  var _previewPolicy = SyncPreviewPolicy.issuesOnly;
  var _uploadToStrava = true;
  var _writeToHealth = false;
  var _canWriteHealth = false;
  DateTime _customStart = DateTime.now().subtract(const Duration(days: 7));
  DateTime _customEnd = DateTime.now();
  final _authenticated = <WorkoutSourceId, bool>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    _primary = widget.entrySource;
    _previewPolicy =
        widget.initialPreviewPolicy ?? SyncPreviewPolicy.issuesOnly;
    _skipLocalHistory = widget.initialSkipLocalHistory;
    _loadAuthentication();
    _loadSyncPreferences();
    AutoSyncSession.instance.restore();
    const HealthKitChannel().canWriteWorkouts().then((value) {
      if (mounted) setState(() => _canWriteHealth = value);
    });
  }

  Future<void> _loadSyncPreferences() async {
    try {
      const preferences = PreferencesChannel();
      final policy = await preferences.read('sync_preview_policy');
      final health = await preferences.read('write_to_apple_health');
      if (!mounted) return;
      setState(() {
        _previewPolicy = resolveSyncPreviewPolicy(
          policy,
          explicit: widget.initialPreviewPolicy,
        );
        _writeToHealth = health == true;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取上次预览/健康写入设置，使用安全默认值');
    }
  }

  Future<void> _saveSyncPreference(String key, Object value) async {
    try {
      await const PreferencesChannel().write(key, value);
    } catch (_) {
      if (mounted) setState(() => _error = '本次设置未能保存，当前批次仍使用所选值');
    }
  }

  @override
  void dispose() {
    _customTitle.dispose();
    super.dispose();
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
                  '${session.progress.message}  成功 ${session.progress.uploaded} · 去重 ${session.progress.deduped} · 失败 ${session.progress.failed}',
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
              SyncResultMessages(
                messages: [
                  for (final result in session.results)
                    if (result.message != null &&
                        !{'skip-all', 'overwrite-all'}.contains(result.message))
                      '${result.workoutId}：${result.message}',
                ],
              ),
              TextField(
                controller: _customTitle,
                enabled: !session.isRunning && !_busy,
                decoration: const InputDecoration(
                  labelText: '本批 Strava 标题（可选）',
                  helperText: '留空时通勤用“通勤🚲”，其他用源标题；网页模式需要 API 授权才能修改标题',
                ),
              ),
              DropdownButton<SyncPreviewPolicy>(
                value: _previewPolicy,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                    value: SyncPreviewPolicy.issuesOnly,
                    child: Text('仅异常确认'),
                  ),
                  DropdownMenuItem(
                    value: SyncPreviewPolicy.everyActivity,
                    child: Text('每条上传前确认'),
                  ),
                ],
                onChanged: session.isRunning || _busy
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _previewPolicy = value);
                          _saveSyncPreference(
                            'sync_preview_policy',
                            value.name,
                          );
                        }
                      },
              ),
              SwitchListTile(
                title: const Text('上传到 Strava'),
                value: _uploadToStrava,
                onChanged:
                    session.isRunning ||
                        _busy ||
                        !_canWriteHealth ||
                        _primary == WorkoutSourceId.healthkit
                    ? null
                    : (value) => setState(() => _uploadToStrava = value),
              ),
              if (_canWriteHealth && _primary != WorkoutSourceId.healthkit)
                SwitchListTile(
                  title: const Text('写入苹果健康'),
                  subtitle: const Text('仅写入生成的训练；附近已有训练时先询问，不会删除健康中的训练'),
                  value: _writeToHealth,
                  onChanged: session.isRunning || _busy
                      ? null
                      : (value) async {
                          if (value) {
                            try {
                              await const HealthKitChannel()
                                  .requestWriteAuthorization();
                            } catch (_) {
                              if (mounted) setState(() => _error = '未获得健康写入授权');
                              return;
                            }
                          }
                          if (mounted) {
                            setState(() => _writeToHealth = value);
                            await _saveSyncPreference(
                              'write_to_apple_health',
                              value,
                            );
                          }
                        },
                ),
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
                              if (source == WorkoutSourceId.healthkit) {
                                _uploadToStrava = true;
                                _writeToHealth = false;
                              }
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
              const Text('历史同步可能较久，请保持应用在前台。中断后可按原配置继续剩余活动。'),
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
        await session.continueRemaining(
          onDuplicate: prompt,
          onHealthNearby: (value) => mounted
              ? showAppleHealthNearbyDialog(context, value)
              : Future.value(AppleHealthNearbyDecision.skipOnce),
          onPreview: (value) => mounted
              ? showSyncPreview(context, value)
              : Future.value(const SyncPreviewDecision(SyncPreviewAction.stop)),
          onLegacy: (value) => mounted
              ? showLegacyRecoveryDialog(context, value)
              : Future.value(LegacyRecoveryDecision.stop),
        );
      } else {
        await session.retryLastBatch(
          onDuplicate: prompt,
          onHealthNearby: (value) => mounted
              ? showAppleHealthNearbyDialog(context, value)
              : Future.value(AppleHealthNearbyDecision.skipOnce),
          onPreview: (value) => mounted
              ? showSyncPreview(context, value)
              : Future.value(const SyncPreviewDecision(SyncPreviewAction.stop)),
          onLegacy: (value) => mounted
              ? showLegacyRecoveryDialog(context, value)
              : Future.value(LegacyRecoveryDecision.stop),
        );
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
        customTitle: _customTitle.text,
        previewPolicy: _previewPolicy,
        uploadToStrava: _uploadToStrava,
        writeToHealth: healthWriteEnabled(
          requested: _writeToHealth,
          canWriteHealth: _canWriteHealth,
          sourceIsHealth: _primary == WorkoutSourceId.healthkit,
        ),
        onHealthNearby: (value) => mounted
            ? showAppleHealthNearbyDialog(context, value)
            : Future.value(AppleHealthNearbyDecision.skipOnce),
        onPreview: (value) => mounted
            ? showSyncPreview(context, value)
            : Future.value(const SyncPreviewDecision(SyncPreviewAction.stop)),
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
