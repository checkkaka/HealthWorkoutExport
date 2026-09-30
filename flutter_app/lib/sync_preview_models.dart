import 'dart:convert';
import 'dart:math' as math;

enum SyncPreviewPolicy { issuesOnly, everyActivity }

enum SyncPreviewAction { upload, forceUpload, skip, stop, rebuild }

final class SyncPreviewDecision {
  const SyncPreviewDecision(this.action, [this.selections = const {}]);
  final SyncPreviewAction action;
  final Map<String, String> selections;
}

final class FitQualityIssue {
  const FitQualityIssue(this.id, this.severity, this.title, this.detail);
  final String id, severity, title, detail;
}

final class FitPreviewPoint {
  const FitPreviewPoint(this.x, this.y);
  final double x, y;
}

final class FitPreviewInspection {
  const FitPreviewInspection({
    this.summary = const {},
    this.issues = const [],
    this.track = const [],
    this.series = const {},
    this.coordinateShapeHash,
    this.coordinateValueHash,
    bool? hasDistance,
    bool? hasDuration,
    // Public constructor names differ from the private nullable fallback flags.
    // ignore: prefer_initializing_formals
  }) : _hasDistance = hasDistance,
       // ignore: prefer_initializing_formals
       _hasDuration = hasDuration;
  final Map<String, double> summary;
  final List<FitQualityIssue> issues;
  final List<FitPreviewPoint> track;
  final Map<String, List<FitPreviewPoint>> series;
  final String? coordinateShapeHash, coordinateValueHash;
  final bool? _hasDistance, _hasDuration;
  bool get hasDistance => _hasDistance ?? summary.containsKey('distanceMeters');
  bool get hasDuration =>
      _hasDuration ?? summary.containsKey('durationSeconds');
  factory FitPreviewInspection.decode(String json) {
    if (json.length > 4 * 1024 * 1024) {
      throw const FormatException('FIT 检查结果过大');
    }
    final value = jsonDecode(json);
    if (value is! Map ||
        value['summary'] is! Map ||
        value['issues'] is! List ||
        value['track'] is! List ||
        value['series'] is! Map) {
      throw const FormatException('FIT 检查结果无效');
    }
    double number(Object? value) {
      if (value is! num || !value.isFinite) {
        throw const FormatException('FIT 检查数值无效');
      }
      return value.toDouble();
    }

    final summary = <String, double>{};
    for (final entry in (value['summary'] as Map).entries) {
      if (entry.key is! String) throw const FormatException('FIT 检查摘要无效');
      if (entry.value is num) {
        summary[entry.key as String] = number(entry.value);
      }
    }
    final issues = <FitQualityIssue>[];
    if ((value['issues'] as List).length > 256) {
      throw const FormatException('FIT 检查问题过多');
    }
    for (final issue in value['issues'] as List) {
      if (issue is! Map ||
          !{'info', 'warning', 'error'}.contains(issue['severity']) ||
          ['id', 'title', 'detail'].any(
            (key) =>
                issue[key] is! String || (issue[key] as String).length > 8192,
          )) {
        throw const FormatException('FIT 质量问题无效');
      }
      issues.add(
        FitQualityIssue(
          issue['id'] as String,
          issue['severity'] as String,
          issue['title'] as String,
          issue['detail'] as String,
        ),
      );
    }
    final track = <FitPreviewPoint>[];
    if ((value['track'] as List).length > 2000) {
      throw const FormatException('轨迹预览超过上限');
    }
    for (final point in value['track'] as List) {
      if (point is! Map) throw const FormatException('轨迹预览点无效');
      final lat = number(point['latitude']), lon = number(point['longitude']);
      if (lat.abs() > 90 || lon.abs() > 180) {
        throw const FormatException('轨迹坐标无效');
      }
      track.add(FitPreviewPoint(lon, lat));
    }
    final series = <String, List<FitPreviewPoint>>{};
    for (final entry in (value['series'] as Map).entries) {
      if (!{
            'speed',
            'altitude',
            'heartRate',
            'cadence',
            'power',
          }.contains(entry.key) ||
          entry.value is! List ||
          (entry.value as List).length > 600) {
        throw const FormatException('FIT 曲线无效');
      }
      series[entry.key as String] = [
        for (final point in entry.value as List)
          if (point is Map)
            FitPreviewPoint(
              number(point['timeSeconds']),
              number(point['value']),
            )
          else
            throw const FormatException('FIT 曲线点无效'),
      ];
    }
    String? hash(String key) {
      final field = value[key];
      if (field == null) return null;
      if (field is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(field)) {
        throw const FormatException('坐标校验摘要无效');
      }
      return field;
    }

    bool? flag(String key) {
      final raw = (value['summary'] as Map)[key];
      if (raw != null && raw is! bool) {
        throw const FormatException('FIT 摘要可用性标记无效');
      }
      return raw as bool?;
    }

    return FitPreviewInspection(
      summary: Map.unmodifiable(summary),
      issues: List.unmodifiable(issues),
      track: List.unmodifiable(track),
      series: Map.unmodifiable(series),
      coordinateShapeHash: hash('coordinateShapeHash'),
      coordinateValueHash: hash('coordinateValueHash'),
      hasDistance: flag('hasDistance'),
      hasDuration: flag('hasDuration'),
    );
  }
}

List<FitQualityIssue> processingQualityIssues({
  required FitPreviewInspection original,
  required FitPreviewInspection finalFit,
  required bool gcjEnabled,
  required int repairedSpeedCount,
  required int rewrittenCoordinateCount,
  required int virtualPowerCount,
  double averageCoordinateDisplacementMeters = 0,
}) {
  final issues = <FitQualityIssue>[];
  if (original.coordinateShapeHash != null &&
      finalFit.coordinateShapeHash != null &&
      original.coordinateShapeHash != finalFit.coordinateShapeHash) {
    issues.add(
      const FitQualityIssue(
        'coordinate-shape-changed',
        'error',
        '坐标结构发生变化',
        '坐标字段数量、时间戳或空值位置发生变化，禁止上传',
      ),
    );
  } else if (!gcjEnabled &&
      original.coordinateValueHash != null &&
      finalFit.coordinateValueHash != null &&
      original.coordinateValueHash != finalFit.coordinateValueHash) {
    issues.add(
      const FitQualityIssue(
        'coordinate-changed-while-disabled',
        'error',
        '坐标被意外修改',
        'GCJ 转换已关闭，但完整坐标校验不一致，禁止上传',
      ),
    );
  }
  for (final item in {
    'gpsCount': 'GPS',
    'heartRateCount': '心率',
    'cadenceCount': '踏频',
    'powerCount': '功率',
  }.entries) {
    final before = original.summary[item.key] ?? 0,
        after = finalFit.summary[item.key] ?? 0;
    if (after < before) {
      issues.add(
        FitQualityIssue(
          '${item.key}-lost',
          'error',
          '处理后丢失${item.value}点',
          '${before.toInt()} → ${after.toInt()}',
        ),
      );
    }
  }
  final oldDistance = original.summary['distanceMeters'] ?? 0,
      newDistance = finalFit.summary['distanceMeters'] ?? 0;
  if ((newDistance - oldDistance).abs() > math.max(200, oldDistance * .02)) {
    issues.add(
      const FitQualityIssue(
        'distance-changed',
        'warning',
        '距离变化较大',
        '处理前后距离差超过 200 米或原距离的 2%',
      ),
    );
  }
  if (repairedSpeedCount > 0) {
    issues.add(
      FitQualityIssue(
        'speed-repaired',
        'warning',
        '速度字段已修复',
        '修复 $repairedSpeedCount 个异常速度/距离点',
      ),
    );
  }
  if (gcjEnabled) {
    issues.add(
      FitQualityIssue(
        'gcj-conversion',
        'info',
        'GCJ→WGS 转换',
        '转换 $rewrittenCoordinateCount 组坐标，平均位移 ${averageCoordinateDisplacementMeters.toStringAsFixed(1)} 米',
      ),
    );
  }
  if (virtualPowerCount > 0) {
    issues.add(
      FitQualityIssue(
        'virtual-power',
        'info',
        '虚拟功率已写入',
        '写入 $virtualPowerCount 个功率点',
      ),
    );
  }
  return issues;
}

final class PreviewCandidate {
  const PreviewCandidate({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.durationSeconds,
    this.score = 0,
    this.eligible = false,
    this.reason = '',
  });
  final String id, title, reason;
  final DateTime start, end;
  final double durationSeconds, score;
  final bool eligible;
}

List<PreviewCandidate> rankPreviewCandidates(
  PreviewCandidate primary,
  List<PreviewCandidate> candidates,
) {
  final ranked = <PreviewCandidate>[];
  for (final c in candidates) {
    final pDuration = math.max(
      1,
      math.max(
        primary.durationSeconds,
        primary.end.difference(primary.start).inMilliseconds / 1000,
      ),
    );
    final cDuration = math.max(
      1,
      math.max(
        c.durationSeconds,
        c.end.difference(c.start).inMilliseconds / 1000,
      ),
    );
    final delta = primary.start.difference(c.start).inMilliseconds.abs() / 1000;
    final ratio =
        (pDuration - cDuration).abs() / math.max(pDuration, cDuration);
    final overlap =
        math.min(
          primary.end.millisecondsSinceEpoch,
          c.end.millisecondsSinceEpoch,
        ) -
        math.max(
          primary.start.millisecondsSinceEpoch,
          c.start.millisecondsSinceEpoch,
        );
    final union =
        math.max(
          primary.end.millisecondsSinceEpoch,
          c.end.millisecondsSinceEpoch,
        ) -
        math.min(
          primary.start.millisecondsSinceEpoch,
          c.start.millisecondsSinceEpoch,
        );
    final iou = union > 0 ? overlap / union : 0.0;
    double? score;
    if (iou >= .5) {
      score = iou;
    } else if (delta <= 900 && ratio <= .2) {
      score = math.max(0, 1 - delta / 900) * (1 - ratio);
    }
    final manualRatio =
        (math.max(primary.durationSeconds, 1) - math.max(c.durationSeconds, 1))
            .abs() /
        math.max(1, math.max(primary.durationSeconds, c.durationSeconds));
    if (score == null && !(delta <= 1800 && manualRatio <= .5)) continue;
    ranked.add(
      PreviewCandidate(
        id: c.id,
        title: c.title,
        start: c.start,
        end: c.end,
        durationSeconds: c.durationSeconds,
        score: score ?? 0,
        eligible: score != null,
        reason: iou >= .5
            ? '时间重叠 ${(iou * 100).toStringAsFixed(0)}%'
            : '${score == null ? '仅供手工选择：' : ''}开始差 ${(delta / 60).toStringAsFixed(1)} 分钟 · 时长差 ${(ratio * 100).toStringAsFixed(0)}%',
      ),
    );
  }
  ranked.sort((a, b) {
    if (a.eligible != b.eligible) return a.eligible ? -1 : 1;
    final score = b.score.compareTo(a.score);
    if (score != 0) return score;
    return a.start
        .difference(primary.start)
        .abs()
        .compareTo(b.start.difference(primary.start).abs());
  });
  return ranked;
}

bool requiresMatchConfirmation(List<PreviewCandidate> candidates) {
  final eligible = candidates.where((c) => c.eligible).toList();
  return eligible.isEmpty
      ? candidates.isNotEmpty
      : eligible.first.score < .6 ||
            eligible.length > 1 &&
                eligible.first.score - eligible[1].score < .15;
}

final class PreviewCandidateGroup {
  const PreviewCandidateGroup({
    required this.sourceId,
    required this.sourceTitle,
    required this.candidates,
    required this.selectedId,
  });
  final String sourceId, sourceTitle;
  final List<PreviewCandidate> candidates;
  final String? selectedId;
}

final class SyncPreviewPrompt {
  const SyncPreviewPrompt({
    required this.title,
    required this.original,
    required this.finalFit,
    required this.issues,
    required this.groups,
    required this.fieldSources,
    this.originalCoordinatesWgs84 = false,
    this.finalCoordinatesWgs84 = false,
  });
  final String title;
  final FitPreviewInspection original, finalFit;
  final List<FitQualityIssue> issues;
  final List<PreviewCandidateGroup> groups;
  final Map<String, String> fieldSources;
  final bool originalCoordinatesWgs84, finalCoordinatesWgs84;
  bool get hasErrors => issues.any((i) => i.severity == 'error');
  bool get hasWarnings => issues.any((i) => i.severity == 'warning');
}

typedef SyncPreviewChooser =
    Future<SyncPreviewDecision> Function(SyncPreviewPrompt prompt);

Future<SyncPreviewDecision> coordinateSyncPreview(
  SyncPreviewPrompt prompt, {
  required SyncPreviewChooser? chooser,
  required void Function() onStop,
}) async {
  final decision =
      await chooser?.call(prompt) ??
      const SyncPreviewDecision(SyncPreviewAction.stop);
  if (decision.action == SyncPreviewAction.stop) onStop();
  return decision;
}

SyncPreviewPolicy resolveSyncPreviewPolicy(
  Object? saved, {
  SyncPreviewPolicy? explicit,
}) =>
    explicit ??
    (saved == 'everyActivity'
        ? SyncPreviewPolicy.everyActivity
        : SyncPreviewPolicy.issuesOnly);

final class PreviewSupplementReport {
  const PreviewSupplementReport({
    required this.index,
    required this.offsetSeconds,
    required this.filledCounts,
    required this.notes,
  });
  final int index;
  final int? offsetSeconds;
  final Map<String, int> filledCounts;
  final List<String> notes;
}

List<PreviewSupplementReport> parseSupplementReports(
  String json, {
  required int expectedCount,
}) {
  if (json.length > 1024 * 1024 || expectedCount < 0 || expectedCount > 32) {
    throw const FormatException('补源报告大小无效');
  }
  final value = jsonDecode(json);
  if (value is! List || value.length != expectedCount) {
    throw const FormatException('补源报告数量不符');
  }
  final reports = <PreviewSupplementReport>[];
  const fields = {'heartRate', 'cadence', 'power', 'temperature', 'grade'};
  for (var i = 0; i < value.length; i++) {
    final item = value[i];
    if (item is! Map ||
        item['index'] != i ||
        item['filledCounts'] is! Map ||
        item['notes'] is! List) {
      throw const FormatException('补源报告无效');
    }
    final offset = item['offsetSeconds'];
    if (offset != null && (offset is! int || offset.abs() > 0xffffffff)) {
      throw const FormatException('补源时间偏移无效');
    }
    final counts = <String, int>{};
    for (final field in fields) {
      final count = (item['filledCounts'] as Map)[field];
      if (count is! int || count < 0 || count > 1000000) {
        throw const FormatException('补源填充计数无效');
      }
      counts[field] = count;
    }
    final notes = item['notes'] as List;
    if (notes.length > 100 ||
        notes.any((note) => note is! String || note.length > 8192)) {
      throw const FormatException('补源报告备注无效');
    }
    reports.add(
      PreviewSupplementReport(
        index: i,
        offsetSeconds: offset as int?,
        filledCounts: Map.unmodifiable(counts),
        notes: List.unmodifiable(notes.cast<String>()),
      ),
    );
  }
  return List.unmodifiable(reports);
}

Map<String, String> previewFieldSources({
  required String primaryName,
  required FitPreviewInspection original,
  required FitPreviewInspection finalFit,
  required List<PreviewSupplementReport> reports,
  required List<String> supplementNames,
  required bool virtualPower,
}) {
  if (reports.length != supplementNames.length) {
    throw const FormatException('补源名称顺序不符');
  }
  final result = <String, String>{
    'speed': primaryName,
    'altitude': primaryName,
  };
  for (final pair in const {
    'heartRate': 'heartRateCount',
    'cadence': 'cadenceCount',
    'power': 'powerCount',
  }.entries) {
    if (pair.key == 'power' && virtualPower) {
      result[pair.key] = '虚拟功率';
      continue;
    }
    if ((original.summary[pair.value] ?? 0) > 0) {
      result[pair.key] = primaryName;
      continue;
    }
    final actual = reports
        .where((r) => (r.filledCounts[pair.key] ?? 0) > 0)
        .firstOrNull;
    if (actual != null) {
      result[pair.key] = supplementNames[actual.index];
    } else if ((finalFit.summary[pair.value] ?? 0) > 0) {
      result[pair.key] = '最终 FIT';
    }
  }
  return result;
}

List<FitQualityIssue> supplementQualityIssues(
  List<PreviewSupplementReport> reports,
  List<String> names,
) {
  if (reports.length != names.length) throw const FormatException('补源名称顺序不符');
  final issues = <FitQualityIssue>[];
  for (final report in reports) {
    final name = names[report.index];
    final total = report.filledCounts.values.fold<int>(0, (a, b) => a + b);
    if (total == 0) {
      issues.add(
        FitQualityIssue(
          'supplement-empty-${report.index}',
          'warning',
          '补源未补入字段',
          '$name 未补入传感器字段',
        ),
      );
    }
    issues.add(
      FitQualityIssue(
        'supplement-report-${report.index}',
        'info',
        '$name 补源报告',
        '${report.offsetSeconds == null ? '无可靠偏移' : '偏移 ${report.offsetSeconds} 秒'}；心率 ${report.filledCounts['heartRate']}、踏频 ${report.filledCounts['cadence']}、功率 ${report.filledCounts['power']}、温度 ${report.filledCounts['temperature']}、坡度 ${report.filledCounts['grade']} 点',
      ),
    );
    for (var i = 0; i < report.notes.length; i++) {
      issues.add(
        FitQualityIssue(
          'supplement-note-${report.index}-$i',
          'info',
          name,
          report.notes[i],
        ),
      );
    }
  }
  return issues;
}
