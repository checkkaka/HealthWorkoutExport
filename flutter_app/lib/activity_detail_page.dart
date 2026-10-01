import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'sync_preview_models.dart';

/// UI-only detail view. Native data access, inspection and side effects are injected.
class WorkoutActivityDetailPage extends StatefulWidget {
  const WorkoutActivityDetailPage({
    super.key,
    required this.title,
    required this.sourceTitle,
    required this.loadOriginal,
    this.loadSynced,
    required this.inspect,
    required this.onExport,
    this.onPreview,
    this.onOverwrite,
    this.onOpenRemote,
    this.statusDetails,
    this.mapBuilder,
  });
  final String title, sourceTitle;
  final Future<Uint8List> Function() loadOriginal;
  final Future<Uint8List?> Function()? loadSynced;
  final Future<FitPreviewInspection> Function(Uint8List) inspect;
  final Future<void> Function(BuildContext, Uint8List, bool) onExport;
  final Future<void> Function()? onPreview, onOverwrite, onOpenRemote;
  final Widget? statusDetails;
  final Widget Function(BuildContext, FitPreviewInspection, bool)? mapBuilder;
  @override
  State<WorkoutActivityDetailPage> createState() =>
      _WorkoutActivityDetailPageState();
}

class _WorkoutActivityDetailPageState extends State<WorkoutActivityDetailPage> {
  Uint8List? _original, _synced;
  FitPreviewInspection? _originalInspection, _syncedInspection;
  bool _selectedSynced = false, _loading = true, _acting = false;
  String? _originalError, _savedError, _actionError;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _originalError = null;
      _savedError = null;
    });
    Uint8List? original, synced;
    FitPreviewInspection? originalInspection, syncedInspection;
    try {
      synced = await widget.loadSynced?.call();
      if (synced != null) {
        _validate(synced);
        syncedInspection = await widget.inspect(synced);
      }
    } catch (_) {
      _savedError = '已保存同步版读取失败';
      synced = null;
    }
    try {
      original = await widget.loadOriginal();
      _validate(original);
      originalInspection = await widget.inspect(original);
    } catch (_) {
      _originalError = '原始 FIT 读取失败，可重试或查看已保存同步版';
      original = null;
    }
    if (!mounted) return;
    setState(() {
      _original = original;
      _synced = synced;
      _originalInspection = originalInspection;
      _syncedInspection = syncedInspection;
      _selectedSynced = original == null && synced != null;
      _loading = false;
    });
  }

  void _validate(Uint8List value) {
    if (value.isEmpty || value.length > 64 * 1024 * 1024) {
      throw const FormatException('FIT大小无效');
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _acting = true;
      _actionError = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _actionError = '操作未完成，请检查授权或网络后重试');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _overwrite() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新生成并配置覆盖？'),
        content: const Text(
          '覆盖会删除原 Strava 活动，已有点赞、评论和照片可能丢失。下一步先检查配置和最终 FIT；确认覆盖后才保存恢复文件、删除并上传。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续配置'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _act(widget.onOverwrite!);
  }

  @override
  Widget build(BuildContext context) {
    final inspection = _selectedSynced
        ? _syncedInspection
        : _originalInspection;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('来源：${widget.sourceTitle}'),
          ?widget.statusDetails,
          if (_loading) const LinearProgressIndicator(),
          if (_originalError case final error?) Text(error),
          if (_savedError case final error?) Text(error),
          if (_originalError != null || _savedError != null)
            TextButton(
              onPressed: _loading ? null : _load,
              child: const Text('重新读取'),
            ),
          if (_original != null || _synced != null)
            Wrap(
              spacing: 8,
              children: [
                if (_original != null)
                  ChoiceChip(
                    label: const Text('原始文件'),
                    selected: !_selectedSynced,
                    onSelected: _acting
                        ? null
                        : (_) => setState(() => _selectedSynced = false),
                  ),
                if (_synced != null)
                  ChoiceChip(
                    label: const Text('Strava 同步版'),
                    selected: _selectedSynced,
                    onSelected: _acting
                        ? null
                        : (_) => setState(() => _selectedSynced = true),
                  ),
              ],
            ),
          if (_selectedSynced) const Text('这是上传成功时保存的最终字节，原始 FIT 未被覆盖'),
          if (inspection != null) ...[
            const SizedBox(height: 12),
            Text('概览', style: Theme.of(context).textTheme.titleLarge),
            Text(
              inspection.hasDistance
                  ? '${((inspection.summary['distanceMeters'] ?? 0) / 1000).toStringAsFixed(2)} 公里'
                  : '距离未提供',
            ),
            Text(
              inspection.hasDuration
                  ? '${((inspection.summary['durationSeconds'] ?? 0) / 60).toStringAsFixed(1)} 分钟'
                  : '时长未提供',
            ),
            Wrap(
              spacing: 12,
              children: [
                for (final item in const {
                  'gpsCount': 'GPS',
                  'heartRateCount': '心率',
                  'cadenceCount': '踏频',
                  'powerCount': '功率',
                }.entries)
                  Text(
                    '${item.value} ${(inspection.summary[item.key] ?? 0).toInt()} 点',
                  ),
              ],
            ),
            if (widget.mapBuilder != null)
              widget.mapBuilder!(context, inspection, _selectedSynced),
            const SizedBox(height: 12),
            Text('质量与字段覆盖', style: Theme.of(context).textTheme.titleLarge),
            if (inspection.issues.isEmpty) const Text('未发现已检查的质量问题'),
            for (final issue in inspection.issues)
              ListTile(
                dense: true,
                leading: Icon(
                  issue.severity == 'error'
                      ? Icons.error_outline
                      : issue.severity == 'warning'
                      ? Icons.warning_amber
                      : Icons.info_outline,
                ),
                title: Text(issue.title),
                subtitle: Text(issue.detail),
              ),
            Text('五项曲线', style: Theme.of(context).textTheme.titleLarge),
            for (final metric in const {
              'speed': '速度（km/h）',
              'altitude': '海拔（m）',
              'heartRate': '心率（bpm）',
              'cadence': '踏频（rpm）',
              'power': '功率（W）',
            }.entries)
              ExpansionTile(
                title: Text(metric.value),
                children: [
                  if ((inspection.series[metric.key] ?? []).isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('暂无数据'),
                    )
                  else
                    SizedBox(
                      height: 140,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _MetricPainter(
                          inspection.series[metric.key]!,
                          Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
          ],
          const SizedBox(height: 16),
          if (_original case final original?)
            OutlinedButton(
              onPressed: _acting
                  ? null
                  : () => _act(() => widget.onExport(context, original, false)),
              child: const Text('导出原始 FIT'),
            ),
          if (_synced case final synced?)
            OutlinedButton(
              onPressed: _acting
                  ? null
                  : () => _act(() => widget.onExport(context, synced, true)),
              child: const Text('导出 Strava 同步版 FIT'),
            ),
          if (widget.onPreview != null)
            FilledButton(
              onPressed: _acting || _original == null
                  ? null
                  : () => _act(widget.onPreview!),
              child: const Text('配置并预览同步'),
            ),
          if (widget.onOverwrite != null)
            TextButton(
              onPressed: _acting || _original == null ? null : _overwrite,
              child: const Text('重新生成并配置覆盖'),
            ),
          if (widget.onOpenRemote != null)
            TextButton(
              onPressed: _acting ? null : () => _act(widget.onOpenRemote!),
              child: const Text('打开 Strava'),
            ),
          if (_actionError case final error?) Text(error),
        ],
      ),
    );
  }
}

class _MetricPainter extends CustomPainter {
  _MetricPainter(this.points, this.color);
  final List<FitPreviewPoint> points;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.isEmpty) return;
    final minX = points.map((p) => p.x).reduce(math.min),
        maxX = points.map((p) => p.x).reduce(math.max);
    final minY = points.map((p) => p.y).reduce(math.min),
        maxY = points.map((p) => p.y).reduce(math.max);
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final x = 8 + (p.x - minX) / math.max(1, maxX - minX) * (size.width - 16);
      final y =
          size.height -
          8 -
          (p.y - minY) / math.max(1, maxY - minY) * (size.height - 16);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_MetricPainter old) =>
      old.points != points || old.color != color;
}

class ActivityHealthStatusView extends StatelessWidget {
  const ActivityHealthStatusView({
    super.key,
    this.uuid,
    this.skipped = false,
    this.error,
  });
  final String? uuid, error;
  final bool skipped;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (uuid != null)
        Chip(label: Text(error == null ? '已写入健康' : '已写入健康（有警告）'))
      else if (skipped)
        const Chip(label: Text('已跳过健康写入')),
      if (error != null) Text(error!),
    ],
  );
}
