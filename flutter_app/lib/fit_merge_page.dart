import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'date_range.dart';
import 'native_channels.dart';
import 'src/rust/api/simple.dart' as rust;
import 'workout_source.dart';

class FitMergePage extends StatefulWidget {
  const FitMergePage({super.key});

  @override
  State<FitMergePage> createState() => _FitMergePageState();
}

class _FitMergePageState extends State<FitMergePage> {
  final _files = <_MergeFile>[];
  var _primaryIndex = 0;
  var _alignment = 'auto';
  var _busy = false;
  String? _error;
  String? _resultPath;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('合并 FIT')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final mode in const ['auto', 'absolute', 'manual'])
                ChoiceChip(
                  label: Text(switch (mode) {
                    'auto' => '自动对齐',
                    'absolute' => '绝对时间',
                    _ => '手动 0 秒',
                  }),
                  selected: _alignment == mode,
                  onSelected: (_) => setState(() => _alignment = mode),
                ),
            ],
          ),
          const SizedBox(height: 12),
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
              selected: _primaryIndex == index,
              onTap: () => setState(() => _primaryIndex = index),
              title: Text(_files[index].name),
              subtitle: const Text('点选作为主源'),
              leading: Icon(
                _primaryIndex == index
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
            ),
          if (_error case final error?) Text(error),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy || _files.length < 2 ? null : _merge,
            icon: const Icon(Icons.merge_type),
            label: Text(_busy ? '合并中…' : '合并并分享'),
          ),
          if (_resultPath case final path?) Text('结果：$path'),
        ],
      ),
    );
  }

  Future<void> _addHealthKit() async {
    setState(() => _error = null);
    try {
      final source = HealthKitWorkoutSource();
      if (!await source.isAuthenticated()) {
        setState(() => _error = 'HealthKit 不可用');
        return;
      }
      final activities = await source.listActivities(
        ActivityDatePreset.days30.resolve(now: DateTime.now()),
      );
      if (!mounted || activities.isEmpty) {
        setState(() => _error = '近 30 天没有健康训练');
        return;
      }
      final chosen = await showModalBottomSheet<WorkoutActivity>(
        context: context,
        builder: (context) => ListView(
          children: [
            for (final activity in activities.take(40))
              ListTile(
                title: Text(activity.title),
                subtitle: Text(activity.start.toString()),
                onTap: () => Navigator.pop(context, activity),
              ),
          ],
        ),
      );
      if (chosen == null) return;
      final fit = await source.fetchFit(chosen);
      setState(() => _files.add(_MergeFile(name: '${chosen.title}.fit', data: fit)));
    } catch (error) {
      setState(() => _error = error.toString());
    }
  }

  Future<void> _addPickedFiles() async {
    try {
      final paths = await const FilesChannel().pickFits();
      for (final path in paths) {
        final file = File(path);
        _files.add(
          _MergeFile(name: file.uri.pathSegments.last, data: await file.readAsBytes()),
        );
      }
      setState(() {});
    } catch (error) {
      setState(() => _error = '无法选择文件：$error');
    }
  }

  Future<void> _merge() async {
    if (_files.length < 2) {
      setState(() => _error = '多文件必须选择主源');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final primary = _files[_primaryIndex];
      final supplements = [
        for (var index = 0; index < _files.length; index++)
          if (index != _primaryIndex) _files[index].data,
      ];
      final merged = rust.mergeFitFiles(
        primary: primary.data,
        supplements: supplements,
        sensorsOnly: true,
        alignment: _alignment,
        manualOffsetSeconds: 0,
      );
      final directory = await Directory.systemTemp.createTemp('fit-merge-');
      final file = File('${directory.path}/merged.fit');
      await file.writeAsBytes(merged, flush: true);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
      setState(() => _resultPath = file.path);
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      setState(() => _busy = false);
    }
  }
}

final class _MergeFile {
  const _MergeFile({required this.name, required this.data});
  final String name;
  final Uint8List data;
}
