import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'sync_preview_models.dart';
import 'route_map.dart';

Future<SyncPreviewDecision> showSyncPreview(
  BuildContext context,
  SyncPreviewPrompt prompt,
) async =>
    await Navigator.of(context).push<SyncPreviewDecision>(
      MaterialPageRoute(builder: (_) => SyncPreviewPage(prompt: prompt)),
    ) ??
    const SyncPreviewDecision(SyncPreviewAction.stop);

class SyncPreviewPage extends StatefulWidget {
  const SyncPreviewPage({super.key, required this.prompt});
  final SyncPreviewPrompt prompt;
  @override
  State<SyncPreviewPage> createState() => _SyncPreviewPageState();
}

class _SyncPreviewPageState extends State<SyncPreviewPage> {
  late final Map<String, String> _selected = {
    for (final g in widget.prompt.groups) g.sourceId: g.selectedId ?? '',
  };
  var _changed = false;
  var _showOriginalTrack = false;
  @override
  Widget build(BuildContext context) {
    final p = widget.prompt;
    return Scaffold(
      appBar: AppBar(title: Text('上传预览：${p.title}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('本页展示最终准备的 FIT。确认后才会保存恢复事务、删除原活动或上传。'),
          const SizedBox(height: 12),
          for (final issue in p.issues)
            ListTile(
              leading: Icon(
                issue.severity == 'error'
                    ? Icons.error
                    : issue.severity == 'warning'
                    ? Icons.warning_amber
                    : Icons.info_outline,
              ),
              title: Text(issue.title),
              subtitle: Text(issue.detail),
            ),
          Text('处理前 → 最终 FIT', style: Theme.of(context).textTheme.titleMedium),
          for (final metric in const {
            'distanceMeters': '距离(m)',
            'durationSeconds': '时长(s)',
            'recordCount': '记录点',
            'gpsCount': 'GPS点',
            'heartRateCount': '心率点',
            'cadenceCount': '踏频点',
            'powerCount': '功率点',
            'averageSpeedKph': '均速(km/h)',
            'maximumSpeedKph': '最高速度(km/h)',
            'averageHeartRateBpm': '平均心率',
            'averagePowerWatts': '平均功率',
            'totalAscentMeters': '爬升(m)',
            'totalCalories': '热量(kcal)',
          }.entries)
            if (p.original.summary[metric.key] != null ||
                p.finalFit.summary[metric.key] != null)
              Text(
                '${metric.value}：${_metricValue(p.original, metric.key)} → ${_metricValue(p.finalFit, metric.key)}',
              ),
          const SizedBox(height: 12),
          for (final group in p.groups)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${group.sourceTitle} 补源',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                DropdownButton<String>(
                  isExpanded: true,
                  value: _selected[group.sourceId],
                  items: [
                    const DropdownMenuItem(value: '', child: Text('本条不使用该补源')),
                    for (final candidate in group.candidates)
                      DropdownMenuItem(
                        value: candidate.id,
                        child: Text(
                          '${candidate.title} · ${candidate.reason}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    _selected[group.sourceId] = value ?? '';
                    _changed = true;
                  }),
                ),
              ],
            ),
          if (_changed)
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                SyncPreviewDecision(
                  SyncPreviewAction.rebuild,
                  Map.unmodifiable(_selected),
                ),
              ),
              child: const Text('按所选补源重新生成并检查'),
            ),
          for (final entry in p.fieldSources.entries)
            Text('${_seriesName(entry.key)}来源：${entry.value}'),
          if (p.finalFit.track.isNotEmpty || p.original.track.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('最终轨迹'),
                  selected: !_showOriginalTrack,
                  onSelected: (_) => setState(() => _showOriginalTrack = false),
                ),
                ChoiceChip(
                  label: const Text('原始轨迹'),
                  selected: _showOriginalTrack,
                  onSelected: (_) => setState(() => _showOriginalTrack = true),
                ),
              ],
            ),
            WorkoutRouteMap(
              contentId:
                  '${p.title}-${identityHashCode(p)}-${_showOriginalTrack ? 'original' : 'final'}',
              height: 260,
              lines: [
                RouteMapLine(
                  id: _showOriginalTrack ? 'original' : 'final',
                  color: _showOriginalTrack ? Colors.grey : Colors.blue,
                  coordinateSystem:
                      (_showOriginalTrack
                          ? p.originalCoordinatesWgs84
                          : p.finalCoordinatesWgs84)
                      ? RouteCoordinateSystem.wgs84
                      : RouteCoordinateSystem.unknown,
                  points: [
                    for (final point
                        in (_showOriginalTrack
                            ? p.original.track
                            : p.finalFit.track))
                      RouteMapPoint(latitude: point.y, longitude: point.x),
                  ],
                ),
              ],
            ),
          ],
          for (final key in const [
            'speed',
            'altitude',
            'heartRate',
            'cadence',
            'power',
          ])
            if ((p.finalFit.series[key] ?? []).isNotEmpty) ...[
              Text('${_seriesName(key)}：灰色原始 / 蓝色最终'),
              Semantics(
                label: '${_seriesName(key)}对比曲线',
                child: SizedBox(
                  height: 130,
                  child: CustomPaint(
                    painter: _PreviewPainter(
                      p.original.series[key] ?? [],
                      p.finalFit.series[key] ?? [],
                    ),
                  ),
                ),
              ),
            ],
          const SizedBox(height: 16),
          if (p.hasErrors) const Text('存在不可强传错误，修正后才可上传。'),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(
                  context,
                  const SyncPreviewDecision(SyncPreviewAction.stop),
                ),
                child: const Text('停止本批'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(
                  context,
                  const SyncPreviewDecision(SyncPreviewAction.skip),
                ),
                child: const Text('跳过本条'),
              ),
              FilledButton(
                onPressed: p.hasErrors || _changed
                    ? null
                    : () => Navigator.pop(
                        context,
                        SyncPreviewDecision(
                          p.hasWarnings
                              ? SyncPreviewAction.forceUpload
                              : SyncPreviewAction.upload,
                        ),
                      ),
                child: Text(p.hasWarnings ? '确认警告并上传' : '确认上传'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _metricValue(FitPreviewInspection inspection, String key) {
    if (key == 'distanceMeters' && !inspection.hasDistance ||
        key == 'durationSeconds' && !inspection.hasDuration) {
      return '未提供';
    }
    return _value(inspection.summary[key]);
  }

  String _value(double? value) => value == null
      ? '—'
      : value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1);
}

String _seriesName(String key) =>
    const {
      'speed': '速度',
      'altitude': '海拔',
      'heartRate': '心率',
      'cadence': '踏频',
      'power': '功率',
    }[key] ??
    key;

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.original, this.finalPoints);
  final List<FitPreviewPoint> original, finalPoints;
  @override
  void paint(Canvas canvas, Size size) {
    final all = [...original, ...finalPoints];
    if (all.isEmpty) return;
    final minX = all.map((p) => p.x).reduce(math.min),
        maxX = all.map((p) => p.x).reduce(math.max);
    final minY = all.map((p) => p.y).reduce(math.min),
        maxY = all.map((p) => p.y).reduce(math.max);
    final width = math.max(maxX - minX, 1e-9),
        height = math.max(maxY - minY, 1e-9);
    for (final (points, color) in [
      (original, Colors.grey),
      (finalPoints, Colors.blue),
    ]) {
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final x = 8 + (points[i].x - minX) / width * (size.width - 16);
        final y =
            size.height -
            8 -
            (points[i].y - minY) / height * (size.height - 16);
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
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PreviewPainter old) =>
      old.original != original || old.finalPoints != finalPoints;
}
