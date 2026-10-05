import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'date_range.dart';
import 'fit_merge_picker.dart';
import 'native_channels.dart';
import 'src/rust/api/simple.dart' as rust;
import 'workout_export.dart';
import 'workout_source.dart';

typedef FitMerger =
    Uint8List Function({
      required List<int> primary,
      required List<Uint8List> supplements,
      required bool sensorsOnly,
      required String alignment,
      required int manualOffsetSeconds,
    });

class FitMergePage extends StatefulWidget {
  const FitMergePage({
    super.key,
    this.pickFits,
    this.readFit,
    this.validateFit,
    this.mergeFits,
    this.shareResult,
    this.healthSource,
    this.requestHealthAuthorization,
  });

  final Future<List<String>> Function()? pickFits;
  final Future<Uint8List> Function(String path)? readFit;
  final void Function(Uint8List data)? validateFit;
  final FitMerger? mergeFits;
  final Future<void> Function(WorkoutExportResult result)? shareResult;
  final WorkoutSource? healthSource;
  final Future<void> Function()? requestHealthAuthorization;

  @override
  State<FitMergePage> createState() => _FitMergePageState();
}

class _FitMergePageState extends State<FitMergePage> {
  static const _maximumFitBytes = 64 * 1024 * 1024;
  final _files = <_MergeFile>[];
  final _manualOffset = TextEditingController(text: '0');
  int? _primaryIndex;
  var _alignment = 'auto';
  var _sensorsOnly = false;
  var _busy = false;
  String? _error;
  String? _alignmentResult;
  var _healthPreset = ActivityDatePreset.days30;
  DateTimeRange? _customHealthRange;
  var _healthRangeRevision = 0;
  WorkoutExportResult? _result;

  @override
  void dispose() {
    _manualOffset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('合并 FIT')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_files.length > 1) ...[
          Wrap(
            spacing: 8,
            children: [
              for (final mode in const ['auto', 'absolute', 'manual'])
                ChoiceChip(
                  label: Text(switch (mode) {
                    'auto' => '自动对齐',
                    'absolute' => '绝对时间',
                    _ => '手动偏移',
                  }),
                  selected: _alignment == mode,
                  onSelected: _busy
                      ? null
                      : (_) => setState(() => _alignment = mode),
                ),
            ],
          ),
          if (_alignment == 'manual')
            TextField(
              key: const Key('mergeManualOffset'),
              controller: _manualOffset,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              decoration: const InputDecoration(
                labelText: '副文件偏移秒数（-7200 至 7200）',
                helperText: '加到副文件时间戳；副设备时钟偏快请填负数',
              ),
            ),
          SwitchListTile(
            title: const Text('仅补传感器'),
            subtitle: const Text('关闭时可补齐缺失路线、事件与分段字段'),
            value: _sensorsOnly,
            onChanged: _busy
                ? null
                : (value) => setState(() => _sensorsOnly = value),
          ),
        ],
        const SizedBox(height: 12),
        DropdownButtonFormField<ActivityDatePreset>(
          key: ValueKey('$_healthPreset:$_healthRangeRevision'),
          initialValue: _healthPreset,
          decoration: const InputDecoration(labelText: '健康训练范围'),
          items: [
            for (final preset in const [
              ActivityDatePreset.today,
              ActivityDatePreset.days7,
              ActivityDatePreset.days30,
              ActivityDatePreset.days90,
              ActivityDatePreset.thisYear,
              ActivityDatePreset.all,
              ActivityDatePreset.custom,
            ])
              DropdownMenuItem(value: preset, child: Text(preset.title)),
          ],
          onChanged: _busy ? null : (value) => _selectHealthRange(value!),
        ),
        FilledButton(
          onPressed: _busy ? null : _addHealthKit,
          child: const Text('从健康训练加入'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy ? null : _addPickedFiles,
          child: const Text('从文件加入'),
        ),
        const SizedBox(height: 16),
        for (var index = 0; index < _files.length; index++)
          ListTile(
            key: ValueKey('mergeFile-$index'),
            selected: _primaryIndex == index,
            onTap: _busy ? null : () => setState(() => _primaryIndex = index),
            title: Text(_files[index].name),
            subtitle: Text(_primaryIndex == index ? '主数据源' : '点选作为主源'),
            leading: Icon(
              _primaryIndex == index
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
            ),
            trailing: IconButton(
              tooltip: '移除文件',
              onPressed: _busy ? null : () => _remove(index),
              icon: const Icon(Icons.close),
            ),
          ),
        if (_error case final error?)
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy || _files.isEmpty ? null : _merge,
          icon: const Icon(Icons.merge_type),
          label: Text(
            _busy
                ? '处理中…'
                : _files.length <= 1
                ? '导出 FIT'
                : '合并 FIT',
          ),
        ),
        if (_alignmentResult case final summary?) Text(summary),
        if (_result != null) ...[
          const Text('结果已生成'),
          OutlinedButton(
            onPressed: _busy ? null : _share,
            child: const Text('分享结果'),
          ),
          TextButton(
            onPressed: _busy ? null : _deleteResult,
            child: const Text('删除结果'),
          ),
        ],
      ],
    ),
  );

  void _remove(int index) {
    setState(() {
      _files.removeAt(index);
      final primary = _primaryIndex;
      if (primary == index) {
        _primaryIndex = null;
      } else if (primary != null && primary > index) {
        _primaryIndex = primary - 1;
      }
    });
  }

  void _validate(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > _maximumFitBytes) {
      throw const FormatException('FIT 文件大小必须为 1 至 64 MiB');
    }
    final validate = widget.validateFit;
    if (validate != null) {
      validate(bytes);
    } else {
      rust.reencodeFit(data: bytes);
    }
  }

  void _addCandidate(_MergeFile file) {
    if (_files.any(
      (value) =>
          value.sourceId == file.sourceId || listEquals(value.data, file.data),
    )) {
      return;
    }
    if (_files.length >= 9 ||
        _files.fold<int>(0, (total, value) => total + value.data.length) +
                file.data.length >
            32 * 1024 * 1024) {
      throw const FormatException('一次最多合并 9 个文件，总大小不得超过 32 MiB');
    }
    _validate(file.data);
    _files.add(file);
  }

  Future<void> _selectHealthRange(ActivityDatePreset preset) async {
    if (preset != ActivityDatePreset.custom) {
      setState(() => _healthPreset = preset);
      return;
    }
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: now,
      initialDateRange: _customHealthRange,
      helpText: '选择健康训练日期范围',
    );
    if (!mounted) return;
    if (range == null) {
      setState(() => _healthRangeRevision++);
      return;
    }
    setState(() {
      _healthPreset = preset;
      _customHealthRange = range;
    });
  }

  Future<void> _addHealthKit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final source = widget.healthSource ?? HealthKitWorkoutSource();
      if (!await source.isAuthenticated()) {
        throw const FormatException('此平台健康数据不可用，请从文件加入 FIT');
      }
      await (widget.requestHealthAuthorization?.call() ??
          const HealthKitChannel().requestAuthorization());
      final activities = await source.listActivities(
        _healthPreset.resolve(
          now: DateTime.now(),
          customStart: _customHealthRange?.start,
          customEnd: _customHealthRange?.end,
        ),
      );
      if (!mounted) return;
      if (activities.isEmpty) throw const FormatException('所选范围内没有健康训练');
      final chosen = await showModalBottomSheet<List<String>>(
        context: context,
        isScrollControlled: true,
        builder: (context) => FitMergePicker(
          activities: [
            for (final activity in activities)
              FitMergePickItem(
                id: activity.id,
                title: activity.title,
                start: activity.start,
              ),
          ],
        ),
      );
      if (chosen == null || chosen.isEmpty) return;
      if (chosen.length + _files.length > 9) {
        throw const FormatException('一次最多合并 9 个文件，请减少选择');
      }
      // Stage the complete selection first so a failed download never silently adds a subset.
      final candidates = <_MergeFile>[];
      for (final activity in activities.where((a) => chosen.contains(a.id))) {
        final fit = await source.fetchFit(activity);
        if (!mounted) return;
        _validate(fit);
        candidates.add(
          _MergeFile(
            name: '${activity.title}.fit',
            data: fit,
            sourceId: 'health:${activity.id}',
          ),
        );
      }
      final totalBytes = [
        ..._files,
        ...candidates,
      ].fold<int>(0, (n, file) => n + file.data.length);
      if (totalBytes > 32 * 1024 * 1024) {
        throw const FormatException('合并总大小不得超过 32 MiB');
      }
      setState(() {
        for (final candidate in candidates) {
          _addCandidate(candidate);
        }
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '无法读取健康训练，请检查授权后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addPickedFiles() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final paths =
          await (widget.pickFits?.call() ?? const FilesChannel().pickFits());
      for (final path in paths) {
        final file = File(path);
        if (widget.readFit == null && await file.length() > _maximumFitBytes) {
          throw const FormatException('FIT 文件超过 64 MiB');
        }
        final bytes = await (widget.readFit?.call(path) ?? file.readAsBytes());
        if (!mounted) return;
        setState(
          () => _addCandidate(
            _MergeFile(
              name: file.uri.pathSegments.last,
              data: bytes,
              sourceId: 'file:$path',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '无法读取 FIT，请确认文件完整且可访问',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _merge() async {
    if (_files.isEmpty) return;
    if (_files.length > 1 && _primaryIndex == null) {
      setState(() => _error = '多文件必须选择主源');
      return;
    }
    final offset = _alignment == 'manual'
        ? int.tryParse(_manualOffset.text.trim())
        : 0;
    if (offset == null || offset < -7200 || offset > 7200) {
      setState(() => _error = '偏移必须为 -7200 至 7200 之间的整数秒');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    Directory? directory;
    try {
      final primaryIndex = _primaryIndex ?? 0;
      final primary = _files[primaryIndex];
      final supplements = [
        for (var i = 0; i < _files.length; i++)
          if (i != primaryIndex) _files[i],
      ];
      late final Uint8List merged;
      String? alignmentResult;
      if (supplements.isEmpty) {
        merged = primary.data;
      } else if (widget.mergeFits case final merge?) {
        merged = merge(
          primary: primary.data,
          supplements: [for (final file in supplements) file.data],
          sensorsOnly: _sensorsOnly,
          alignment: _alignment,
          manualOffsetSeconds: offset,
        );
      } else {
        final output = await rust.mergeFitFilesDetailed(
          primary: primary.data,
          supplements: [for (final file in supplements) file.data],
          sensorsOnly: _sensorsOnly,
          alignment: _alignment,
          manualOffsetSeconds: offset,
        );
        merged = output.data;
        alignmentResult =
            '对齐偏移（加到副文件）：\n${[for (var i = 0; i < supplements.length; i++) '${supplements[i].name}：${output.offsetsSeconds[i]} 秒'].join('\n')}';
      }
      directory = await Directory.systemTemp.createTemp(
        'health-workout-export-merge-',
      );
      final file = File('${directory.path}${Platform.pathSeparator}merged.fit');
      await file.writeAsBytes(merged, flush: true);
      if (!mounted) {
        await directory.delete(recursive: true);
        return;
      }
      await _result?.dispose();
      if (!mounted) {
        await directory.delete(recursive: true);
        return;
      }
      final result = WorkoutExportResult(file: file, directory: directory);
      setState(() {
        _result = result;
        _alignmentResult = alignmentResult;
      });
      directory = null;
    } catch (error) {
      if (directory != null && await directory.exists()) {
        await directory.delete(recursive: true);
      }
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : 'FIT 合并失败，请检查文件是否属于同一次活动及时间对齐设置',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    final result = _result;
    if (result == null) return;
    try {
      if (widget.shareResult case final share?) {
        await share(result);
      } else {
        final render = context.findRenderObject();
        final origin = render is RenderBox && render.hasSize
            ? render.localToGlobal(Offset.zero) & render.size
            : const Rect.fromLTWH(0, 0, 1, 1);
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(result.file.path)],
            sharePositionOrigin: origin,
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = '分享失败，请重试');
    }
  }

  Future<void> _deleteResult() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本次结果？'),
        content: const Text('只删除本次临时结果，保留导入文件与同步 FIT。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _result?.dispose();
      if (mounted) setState(() => _result = null);
    } catch (_) {
      if (mounted) setState(() => _error = '删除结果失败，请重试');
    }
  }
}

final class _MergeFile {
  const _MergeFile({
    required this.name,
    required this.data,
    required this.sourceId,
  });
  final String name;
  final Uint8List data;
  final String sourceId;
}
