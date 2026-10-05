import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'native_channels.dart';
import 'workout_export.dart';

/// 三个数据源共用格式、时区、同步 FIT 可用性及临时结果生命周期。
class WorkoutExportControls extends StatefulWidget {
  const WorkoutExportControls({
    super.key,
    required this.activities,
    this.initialFormat = WorkoutExportFormat.json,
    this.loadHealthBundle,
    this.loadOriginalFit,
    this.currentTimeZoneIdentifier,
    this.onBusyChanged,
    this.disabled = false,
    this.service,
    this.syncedStore,
    this.shareResult,
  });

  final List<WorkoutExportActivity> activities;
  final WorkoutExportFormat initialFormat;
  final Future<HealthWorkoutBundle> Function(String id)? loadHealthBundle;
  final Future<Uint8List> Function(WorkoutExportActivity activity)?
  loadOriginalFit;
  final Future<String> Function()? currentTimeZoneIdentifier;
  final ValueChanged<bool>? onBusyChanged;
  final bool disabled;
  final WorkoutExportService? service;
  final SyncedFitExportStore? syncedStore;
  final Future<void> Function(WorkoutExportResult result)? shareResult;

  @override
  State<WorkoutExportControls> createState() => _WorkoutExportControlsState();
}

class _WorkoutExportControlsState extends State<WorkoutExportControls>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  late final _service = widget.service ?? WorkoutExportService();
  late final _syncedStore = widget.syncedStore ?? SyncedFitExportStore();
  late WorkoutExportFormat _format;
  var _timeZone = WorkoutExportTimeZone.candidates.first;
  var _fitSource = WorkoutFitExportSource.original;
  var _busy = false;
  var _resultActionBusy = false;
  var _checkingAvailability = false;
  var _availabilityRequest = 0;
  Map<String, String> _syncedFits = const {};
  String? _availabilityError;
  String? _error;
  WorkoutExportProgress? _progress;
  WorkoutExportResult? _result;

  bool get _allSynced =>
      widget.activities.isNotEmpty &&
      widget.activities.every(
        (activity) => _syncedFits.containsKey(activity.key),
      );

  @override
  void initState() {
    super.initState();
    _format = widget.initialFormat;
    unawaited(_refreshAvailability());
  }

  @override
  void didUpdateWidget(WorkoutExportControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.activities
        .map((activity) => activity.key)
        .join('\n');
    final current = widget.activities
        .map((activity) => activity.key)
        .join('\n');
    if (previous != current) unawaited(_refreshAvailability());
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final disabled = _busy || _resultActionBusy || widget.disabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<WorkoutExportFormat>(
          initialValue: _format,
          decoration: const InputDecoration(labelText: '导出格式'),
          items: [
            for (final format in WorkoutExportFormat.values)
              DropdownMenuItem(value: format, child: Text(format.title)),
          ],
          onChanged: disabled
              ? null
              : (value) {
                  if (value != null) setState(() => _format = value);
                },
        ),
        if (_format == WorkoutExportFormat.fit) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<WorkoutFitExportSource>(
            key: ValueKey(_fitSource),
            initialValue: _fitSource,
            decoration: const InputDecoration(labelText: 'FIT 来源'),
            items: [
              for (final source in WorkoutFitExportSource.values)
                DropdownMenuItem(
                  value: source,
                  enabled:
                      source == WorkoutFitExportSource.original ||
                      (!_checkingAvailability && _allSynced),
                  child: Text(source.title),
                ),
            ],
            onChanged: disabled
                ? null
                : (value) {
                    if (value != null) setState(() => _fitSource = value);
                  },
          ),
          const SizedBox(height: 4),
          Text(
            _checkingAvailability
                ? '正在检查本地同步 FIT…'
                : _availabilityError ??
                      (_allSynced
                          ? '所选活动均有本地 Strava 同步版 FIT'
                          : '所选活动缺少同步 FIT，Strava 同步版暂不可选'),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: disabled || _checkingAvailability
                  ? null
                  : () => unawaited(_refreshAvailability()),
              child: const Text('刷新同步 FIT'),
            ),
          ),
        ],
        const SizedBox(height: 12),
        DropdownButtonFormField<WorkoutExportTimeZone>(
          initialValue: _timeZone,
          decoration: const InputDecoration(labelText: '导出时区'),
          items: [
            for (final zone in WorkoutExportTimeZone.candidates)
              DropdownMenuItem(value: zone, child: Text(zone.title)),
          ],
          onChanged: disabled
              ? null
              : (value) {
                  if (value != null) setState(() => _timeZone = value);
                },
        ),
        if (_format == WorkoutExportFormat.json &&
            widget.loadHealthBundle == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('第三方源 JSON 仅为活动摘要；完整轨迹请导出 FIT。'),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed:
              disabled ||
                  widget.activities.isEmpty ||
                  (_format == WorkoutExportFormat.fit &&
                      _fitSource == WorkoutFitExportSource.synced &&
                      (_checkingAvailability || !_allSynced))
              ? null
              : () => unawaited(_export()),
          icon: const Icon(Icons.ios_share),
          label: Text(_busy ? '正在导出…' : '导出并分享'),
        ),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_progress case final progress?) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress.fraction),
          Text('已处理 ${progress.completed}/${progress.total} 条训练'),
        ],
        if (_result case final result?) ...[
          const SizedBox(height: 8),
          Text('导出文件：${result.file.uri.pathSegments.last}'),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: disabled ? null : () => unawaited(_share(result)),
                child: const Text('再次分享'),
              ),
              TextButton(
                onPressed: disabled ? null : () => unawaited(_delete(result)),
                child: const Text('删除本次导出'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _refreshAvailability() async {
    final request = ++_availabilityRequest;
    setState(() {
      _checkingAvailability = true;
      _availabilityError = null;
      _syncedFits = const {};
    });
    try {
      final result = await _syncedStore.available(widget.activities);
      if (!mounted || request != _availabilityRequest) return;
      setState(() => _syncedFits = result);
    } catch (_) {
      if (!mounted || request != _availabilityRequest) return;
      setState(() => _availabilityError = '无法读取本地同步 FIT；仍可导出原始文件');
    } finally {
      if (mounted && request == _availabilityRequest) {
        setState(() => _checkingAvailability = false);
      }
    }
  }

  Future<void> _export() async {
    if (_busy ||
        _resultActionBusy ||
        widget.disabled ||
        widget.activities.isEmpty) {
      return;
    }
    final activities = List<WorkoutExportActivity>.of(widget.activities);
    final format = _format;
    final fitSource = _fitSource;
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.onBusyChanged?.call(true);
    try {
      final resolveZone = widget.currentTimeZoneIdentifier;
      final zone = _timeZone.id == null && resolveZone != null
          ? WorkoutExportTimeZone.resolvedCurrent(await resolveZone())
          : _timeZone;
      void onProgress(WorkoutExportProgress progress) {
        if (mounted) setState(() => _progress = progress);
      }

      final healthLoader = widget.loadHealthBundle;
      final WorkoutExportResult result;
      if (healthLoader != null &&
          (format == WorkoutExportFormat.json ||
              fitSource == WorkoutFitExportSource.original)) {
        result = await _service.exportFromLoader(
          workoutIds: activities.map((activity) => activity.id).toList(),
          loadBundle: healthLoader,
          format: format,
          timeZone: zone,
          onProgress: onProgress,
        );
      } else {
        // 在点击导出时重新校验，避免检查后删除文件或改写同步记录而静默回退。
        final fingerprints =
            format == WorkoutExportFormat.fit &&
                fitSource == WorkoutFitExportSource.synced
            ? await _syncedStore.available(activities)
            : const <String, String>{};
        if (format == WorkoutExportFormat.fit &&
            fitSource == WorkoutFitExportSource.synced) {
          for (final activity in activities) {
            if (!fingerprints.containsKey(activity.key)) {
              throw StateError('“${activity.title}”没有保存 Strava 同步版 FIT，请刷新后重试');
            }
          }
        }
        result = await _service.exportActivities(
          activities: activities,
          format: format,
          timeZone: zone,
          loadFit: fitSource == WorkoutFitExportSource.synced
              ? (activity) => _syncedStore.read(activity, fingerprints)
              : widget.loadOriginalFit,
          onProgress: onProgress,
        );
      }
      if (!mounted) {
        await result.dispose();
        return;
      }
      final previous = _result;
      setState(() => _result = result);
      // 新导出失败时保留上一份可分享结果；成功后才替换并清理。
      if (previous != null) {
        try {
          await previous.dispose();
        } catch (_) {
          /* 七天清理可再次回收。 */
        }
      }
      if (mounted) await _share(result);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
        widget.onBusyChanged?.call(false);
      }
    }
  }

  Future<void> _share(WorkoutExportResult result) async {
    if (_resultActionBusy || !mounted) return;
    setState(() => _resultActionBusy = true);
    try {
      if (widget.shareResult case final share?) {
        await share(result);
      } else {
        final render = context.findRenderObject();
        final origin = render is RenderBox && render.hasSize
            ? render.localToGlobal(Offset.zero) & render.size
            : const Rect.fromLTWH(0, 0, 1, 1);
        await _service.share(result, sharePositionOrigin: origin);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '分享失败，可再次尝试：$error');
    } finally {
      if (mounted) setState(() => _resultActionBusy = false);
    }
  }

  Future<void> _delete(WorkoutExportResult result) async {
    if (_resultActionBusy || _busy) return;
    setState(() => _resultActionBusy = true);
    final accepted = await confirmDestructiveAction(
      context,
      title: '删除本次导出？',
      message: '仅删除本次临时导出文件，不影响原始训练或已保存的同步 FIT。',
      confirmLabel: '删除',
    );
    if (!mounted) return;
    if (!accepted) {
      setState(() => _resultActionBusy = false);
      return;
    }
    try {
      await result.dispose();
      if (mounted && identical(result, _result)) setState(() => _result = null);
    } catch (error) {
      if (mounted) setState(() => _error = '删除失败：$error');
    } finally {
      if (mounted) setState(() => _resultActionBusy = false);
    }
  }
}

Future<bool> confirmDestructiveAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ) ??
    false;
