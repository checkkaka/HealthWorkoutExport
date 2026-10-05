import 'dart:convert';

import 'native_channels.dart';
import 'src/rust/api/simple.dart' as rust;
import 'strava_upload_api.dart';

/// Fixed-purpose, cancellable reads. A native web request may finish after Stop,
/// but its result is discarded and no following page/detail request is started.
final class StravaRemoteRepository {
  StravaRemoteRepository({StravaWebChannel? web, StravaUploadSession? api})
    : _web = web ?? const StravaWebChannel(),
      _api = api ?? stravaUploadSession;
  final StravaWebChannel _web;
  final StravaUploadSession _api;
  final Set<String> _handles = {};
  int _generation = 0;

  void cancel() {
    _generation++;
    for (final handle in _handles.toList()) {
      rust.stravaCancelRemoteRead(operationHandle: handle);
    }
  }

  void _check(int generation) {
    if (generation != _generation) throw const RemoteReadCancelled();
  }

  Future<T> _withApi<T>(
    Future<T> Function(String handle, String token) read,
  ) async {
    final generation = _generation;
    final token = await _api.accessToken();
    _check(generation);
    final handle = rust
        .stravaReserveRemoteRead(
          operationId: 'history-${DateTime.now().microsecondsSinceEpoch}',
        )
        .handle;
    _handles.add(handle);
    try {
      final result = await read(handle, token);
      _check(generation);
      return result;
    } finally {
      _handles.remove(handle);
      rust.stravaReleaseRemoteRead(operationHandle: handle);
    }
  }

  Future<List<rust.StravaRemoteActivityResult>> list({
    required DateTime after,
    required DateTime before,
    bool preferWeb = false,
    bool webOnly = false,
  }) async {
    final generation = _generation;
    if (webOnly || preferWeb && await _web.hasCookie()) {
      _check(generation);
      return _webList(after: after, before: before);
    }
    try {
      return await _withApi(
        (handle, token) => rust.stravaListRemoteActivities(
          operationHandle: handle,
          accessToken: token,
          afterSeconds: after.millisecondsSinceEpoch ~/ 1000,
          beforeSeconds: before.millisecondsSinceEpoch ~/ 1000,
        ),
      );
    } on RemoteReadCancelled {
      rethrow;
    } catch (_) {
      _check(generation);
      if (!await _web.hasCookie()) rethrow;
      _check(generation);
      return _webList(after: after, before: before);
    }
  }

  Future<List<String>> _webPages({
    required DateTime after,
    required DateTime before,
  }) async {
    final generation = _generation;
    final result = <String>[];
    final seen = <String>{};
    var count = 0;
    for (var page = 1; page <= 200; page++) {
      _check(generation);
      final json = await _web.listActivityPage(
        page: page,
        after: after,
        before: before,
      );
      _check(generation);
      final root = jsonDecode(json);
      final models = root is Map ? root['models'] ?? root['activities'] : null;
      if (models is! List || models.length > 1000) {
        throw const FormatException('网页训练列表格式无效');
      }
      if (models.isEmpty) return result;
      if (!seen.add(json)) throw const FormatException('网页列表重复，未完成全部读取');
      count += models.length;
      result.add(json);
      final total = root['total'] ?? root['total_count'];
      if (total is num && total.isFinite && count >= total) return result;
      if (models.length < 10) return result;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw const FormatException('网页活动超过 200 页，请缩小日期范围');
  }

  Future<List<rust.StravaRemoteActivityResult>> _webList({
    required DateTime after,
    required DateTime before,
  }) async {
    final byId = <String, rust.StravaRemoteActivityResult>{};
    for (final page in await _webPages(after: after, before: before)) {
      for (final activity in rust.stravaParseWebRemoteActivities(
        responseJson: utf8.encode(page),
      )) {
        final seconds = activity.startTimeSeconds;
        if (seconds >= after.millisecondsSinceEpoch / 1000 &&
            seconds < before.millisecondsSinceEpoch / 1000) {
          byId[activity.id] = activity;
        }
      }
    }
    return byId.values.toList();
  }

  Future<List<rust.StravaActivitySpeedResult>> listedSpeeds() async {
    final generation = _generation;
    if (await _web.hasCookie()) {
      _check(generation);
      final byId = <String, rust.StravaActivitySpeedResult>{};
      for (final page in await _webPages(
        after: DateTime.utc(1900),
        before: DateTime.now().toUtc().add(const Duration(days: 1)),
      )) {
        for (final item in rust.stravaParseWebListedActivitySpeeds(
          responseJson: utf8.encode(page),
        )) {
          byId[item.id] = item;
        }
      }
      return byId.values.toList();
    }
    _check(generation);
    // List bounded history, then fetch complete speed summaries per ID.
    final activities = await list(
      after: DateTime.utc(1900),
      before: DateTime.now().add(const Duration(days: 1)),
    );
    return [
      for (final activity in activities)
        rust.StravaActivitySpeedResult(
          id: activity.id,
          name: '活动 ${activity.id}',
          startTimeSeconds: activity.startTimeSeconds,
          sportType: '',
          listedMaxSpeedMps: 0,
          bestEffortPeakMps: 0,
          maxSpeedMps: 0,
          averageSpeedMps: 0,
        ),
    ];
  }

  Future<rust.StravaActivitySpeedResult?> speed(String id) async {
    final generation = _generation;
    try {
      return await _withApi(
        (handle, token) => rust.stravaFetchRemoteActivitySpeed(
          operationHandle: handle,
          accessToken: token,
          activityId: id,
        ),
      );
    } on RemoteReadCancelled {
      rethrow;
    } catch (_) {
      _check(generation);
      if (!await _web.hasCookie()) rethrow;
      _check(generation);
      final data = await _web.readActivitySpeedData(id);
      _check(generation);
      return data == null
          ? null
          : rust.stravaParseWebActivitySpeed(
              activityId: id,
              pageHtml: data.pageHtml,
              streamsJson: data.streamsJson,
            );
    }
  }
}

final class RemoteReadCancelled implements Exception {
  const RemoteReadCancelled();
}
