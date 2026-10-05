import 'package:flutter/material.dart';

import 'auto_sync_controller.dart';
import 'auto_sync_session.dart';
import 'native_channels.dart';
import 'sync_state_store.dart';
import 'recovery_legacy_dialog.dart';
import 'recovery_batch_checkpoint.dart';
import 'apple_health_import.dart';
import 'apple_health_import_dialog.dart';
import 'sync_history_logic.dart';
import 'strava_remote_repository.dart';
import 'src/rust/api/simple.dart' as rust;

class SyncHistoryPage extends StatefulWidget {
  const SyncHistoryPage({super.key, this.stateStore, this.resumeRecovery});
  final SyncStateStore? stateStore;
  final Future<AutoSyncResult> Function(String fingerprint)? resumeRecovery;

  @override
  State<SyncHistoryPage> createState() => _SyncHistoryPageState();
}

class _SyncHistoryPageState extends State<SyncHistoryPage> {
  late final _store = widget.stateStore ?? SyncStateStore();
  var _records = <String, Map<String, Object?>>{};
  var _filter = 'all';
  final _selected = <String>{};
  var _loading = true;
  var _busy = false;
  String? _error;
  final _remote = StravaRemoteRepository();
  final _anomalies = <String, rust.StravaActivitySpeedResult>{};
  var _stopRequested = false;
  var _recovering = false;
  var _canWriteHealth = false;
  @override
  void dispose() {
    _stopRequested = true;
    _remote.cancel();
    super.dispose();
  }

  bool get _stopped => _stopRequested || !mounted;

  @override
  void initState() {
    super.initState();
    _reload();
    const HealthKitChannel().canWriteWorkouts().then((value) {
      if (mounted) setState(() => _canWriteHealth = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered();
    return Scaffold(
      appBar: AppBar(title: const Text('同步记录')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final entry in const {
                      'all': '全部',
                      'failed': '失败',
                      'pending': '待处理',
                      'noRemote': '无远端 ID',
                      'duplicate': '去重',
                      'api': 'API',
                      'web': '网页',
                      'anomalous': '异常速度',
                    }.entries)
                      ChoiceChip(
                        label: Text(entry.value),
                        selected: _filter == entry.key,
                        onSelected: _busy
                            ? null
                            : (_) => setState(() {
                                _filter = entry.key;
                                _selected.retainAll(_filtered());
                              }),
                      ),
                  ],
                ),
                Row(
                  children: [
                    Text('已选择 ${_selected.length}/${items.length}'),
                    TextButton(
                      onPressed: _busy || items.isEmpty
                          ? null
                          : () => setState(() => _selected.addAll(items)),
                      child: const Text('全选'),
                    ),
                    TextButton(
                      onPressed: _busy || _selected.isEmpty
                          ? null
                          : () => setState(_selected.clear),
                      child: const Text('取消全选'),
                    ),
                  ],
                ),
                if (_error case final error?)
                  Padding(padding: const EdgeInsets.all(8), child: Text(error)),
                if (_busy) ...[
                  const LinearProgressIndicator(),
                  TextButton(
                    onPressed: () {
                      _stopRequested = true;
                      _remote.cancel();
                      if (_recovering) AutoSyncSession.instance.cancel();
                    },
                    child: const Text('停止当前操作'),
                  ),
                ],
                if (_anomalies.isNotEmpty)
                  SizedBox(
                    height: 160,
                    child: ListView(
                      children: [
                        for (final info in _anomalies.values)
                          ListTile(
                            title: Text(
                              '${info.name} · ${(info.maxSpeedMps * 3.6).toStringAsFixed(1)} km/h',
                            ),
                            subtitle: Text(
                              '摘要 ${(info.listedMaxSpeedMps * 3.6).toStringAsFixed(1)} · 最佳/速度流 ${(info.bestEffortPeakMps * 3.6).toStringAsFixed(1)} km/h',
                            ),
                            onTap: () async {
                              try {
                                await const StravaWebChannel().openActivity(
                                  info.id,
                                );
                              } catch (_) {}
                            },
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: items.isEmpty
                      ? const Center(child: Text('没有符合条件的同步记录'))
                      : ListView(
                          children: [
                            for (final fingerprint in items)
                              CheckboxListTile(
                                key: ValueKey(fingerprint),
                                value: _selected.contains(fingerprint),
                                onChanged: _busy
                                    ? null
                                    : (_) => setState(() {
                                        if (!_selected.add(fingerprint)) {
                                          _selected.remove(fingerprint);
                                        }
                                      }),
                                title: Text(
                                  '${_records[fingerprint]?['title'] ?? (fingerprint.length > 8 ? fingerprint.substring(0, 8) : fingerprint)}',
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(_statusLine(fingerprint)),
                                    if (_records[fingerprint]?['remoteId']
                                        case final String remoteId)
                                      if (isValidStravaActivityId(remoteId))
                                        TextButton(
                                          onPressed: () async {
                                            try {
                                              await const StravaWebChannel()
                                                  .openActivity(remoteId);
                                            } catch (_) {
                                              if (mounted) {
                                                setState(
                                                  () =>
                                                      _error = '无法打开 Strava 活动',
                                                );
                                              }
                                            }
                                          },
                                          child: const Text('打开 Strava 活动'),
                                        ),
                                  ],
                                ),
                                secondary:
                                    _records[fingerprint]?['batchAt'] == null
                                    ? null
                                    : IconButton(
                                        tooltip: '选择同批次',
                                        icon: const Icon(Icons.select_all),
                                        onPressed: _busy
                                            ? null
                                            : () => setState(() {
                                                final batch =
                                                    _records[fingerprint]?['batchAt'];
                                                _selected.addAll(
                                                  items.where(
                                                    (id) =>
                                                        _records[id]?['batchAt'] ==
                                                        batch,
                                                  ),
                                                );
                                              }),
                                      ),
                              ),
                          ],
                        ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: _busy || _selected.isEmpty
                              ? null
                              : () => _resync(),
                          child: const Text('继续恢复所选'),
                        ),
                        OutlinedButton(
                          onPressed: _busy || _selected.isEmpty
                              ? null
                              : _confirmOverwrite,
                          child: const Text('覆盖重传所选'),
                        ),
                        if (_canWriteHealth)
                          OutlinedButton(
                            onPressed: _busy || _selected.isEmpty
                                ? null
                                : () => _resync(
                                    uploadToStrava: false,
                                    writeToHealth: true,
                                  ),
                            child: const Text('写入健康所选'),
                          ),
                        OutlinedButton(
                          onPressed: _busy ? null : _backfill,
                          child: const Text('补全远端 ID'),
                        ),
                        OutlinedButton(
                          onPressed: _busy ? null : _scanSpeeds,
                          child: const Text('扫描异常速度'),
                        ),
                        TextButton(
                          onPressed: _busy || _selected.isEmpty
                              ? null
                              : _delete,
                          child: const Text('删除所选'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  List<String> _filtered() {
    final values = _records.keys.where((fingerprint) {
      final record = _records[fingerprint]!;
      final status = record['status'] as String? ?? '';
      final remoteId = record['remoteId'] as String?;
      return switch (_filter) {
        'failed' => status == 'failed',
        'pending' => status == 'pending',
        'noRemote' => remoteId == null || remoteId.isEmpty,
        'duplicate' => record['isDuplicate'] == true,
        'api' || 'web' => record['uploadChannel'] == _filter,
        'anomalous' => _anomalies.containsKey(remoteId),
        _ => true,
      };
    }).toList();
    values.sort(
      (a, b) => ((_records[b]?['updatedAt'] as num?) ?? 0).compareTo(
        (_records[a]?['updatedAt'] as num?) ?? 0,
      ),
    );
    return values;
  }

  String _statusLine(String fingerprint) {
    final record = _records[fingerprint];
    final status = switch (record?['status']) {
      'uploaded' => '已上传',
      'pending' => '待处理',
      'failed' => '失败',
      _ => '未知状态',
    };
    final remoteId = record?['remoteId'];
    final message = record?['message'];
    return '$status${record?['isDuplicate'] == true ? ' · 去重' : ''}${remoteId == null ? '' : ' · $remoteId'}${message == null ? '' : '\n$message'}';
  }

  Future<void> _reload({bool preserveMessage = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      if (!preserveMessage) _error = null;
    });
    try {
      final records = await _store.allRecords();
      if (!mounted) return;
      setState(() {
        _records = {
          for (final entry in records.entries)
            if (entry.value is Map)
              entry.key: Map<String, Object?>.from(entry.value as Map),
        };
        _selected.retainAll(_filtered());
      });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取同步记录，请稍后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _delete() async {
    if (AutoSyncSession.instance.isRunning) {
      setState(() => _error = '请等待同步结束后再删除记录');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${_selected.length} 条本地同步记录？'),
        content: const Text('会同时删除本机同步 FIT 和恢复文件，不会删除 Strava 上的活动。'),
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
    if (confirmed != true || !mounted) return;
    if (AutoSyncSession.instance.isRunning) {
      setState(() => _error = '请等待同步结束后再删除记录');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _stopRequested = false;
    });
    try {
      for (final fingerprint in _selected.toList()) {
        if (_stopped) break;
        await _store.remove(fingerprint);
        _selected.remove(fingerprint);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '部分记录未删除，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload(preserveMessage: true);
  }

  Future<void> _confirmOverwrite() async {
    var title = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('覆盖所选 ${_selected.length} 条活动？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '先保存最终 FIT，再永久删除对应 Strava 活动并上传。评论、点赞和旧链接无法恢复。需要网页登录；缺少远端 ID 或同步 FIT 的记录不会删除。',
            ),
            TextField(
              onChanged: (value) => title = value,
              decoration: const InputDecoration(labelText: '本批新标题（可选）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除并覆盖'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _resync(replaceExisting: true, customTitle: title);
    }
  }

  Future<void> _backfill() async {
    if (AutoSyncSession.instance.isRunning) {
      setState(() => _error = '请等待同步结束');
      return;
    }
    final missing = _records.values
        .where(
          (r) =>
              r['startDate'] is num &&
              !isValidStravaActivityId(r['remoteId'] as String? ?? ''),
        )
        .toList();
    if (missing.isEmpty) {
      setState(() => _error = '没有可补全的记录');
      return;
    }
    final starts = [for (final r in missing) (r['startDate'] as num).toDouble()]
      ..sort();
    DateTime fromApple(double value) => DateTime.fromMillisecondsSinceEpoch(
      ((value + 978307200) * 1000).round(),
      isUtc: true,
    );
    setState(() {
      _busy = true;
      _error = '正在读取 Strava 活动…';
      _stopRequested = false;
    });
    var count = 0;
    try {
      final remotes = await _remote.list(
        after: fromApple(starts.first - 120),
        before: fromApple(starts.last + 120),
      );
      if (_stopped) return;
      final pairs = remoteIdAssignments(_records, remotes);
      for (final pair in pairs.entries) {
        if (_stopped || AutoSyncSession.instance.isRunning) break;
        await _store.setRemoteId(fingerprint: pair.key, remoteId: pair.value);
        count++;
      }
      if (mounted) setState(() => _error = '已补全 $count 条远端 ID');
    } catch (_) {
      if (mounted) {
        setState(() => _error = _stopRequested ? '已停止补全' : '补全失败，请检查授权与网络');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload(preserveMessage: true);
  }

  Future<void> _scanSpeeds() async {
    if (AutoSyncSession.instance.isRunning) {
      setState(() => _error = '请等待同步结束');
      return;
    }
    setState(() {
      _busy = true;
      _error = '正在拉取活动列表…';
      _stopRequested = false;
      _anomalies.clear();
    });
    var skipped = 0;
    try {
      final listed = await _remote.listedSpeeds();
      if (_stopped) return;
      final details = <String>{};
      for (final info in listed) {
        if (isAnomalousStravaSpeed(info)) _anomalies[info.id] = info;
        if (info.listedMaxSpeedMps < 80 / 3.6) details.add(info.id);
      }
      for (final record in _records.values) {
        final id = record['remoteId'];
        if (id is String && isValidStravaActivityId(id)) details.add(id);
      }
      var index = 0;
      for (final id in details) {
        if (_stopped) break;
        setState(() => _error = '复查速度 ${++index}/${details.length}…');
        try {
          final info = await _remote.speed(id);
          if (_stopped) break;
          if (info == null) {
            skipped++;
          } else if (isAnomalousStravaSpeed(info)) {
            _anomalies[id] = info;
          }
        } on RemoteReadCancelled {
          break;
        } catch (_) {
          skipped++;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (mounted) {
        setState(
          () => _error =
              '${_stopRequested ? '已停止，' : ''}发现 ${_anomalies.length} 条异常，详情跳过 $skipped 条',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = _stopRequested ? '已停止扫描' : '扫描未完成，请检查授权与网络');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resync({
    bool replaceExisting = false,
    bool uploadToStrava = true,
    bool writeToHealth = false,
    String? customTitle,
  }) async {
    if (AutoSyncSession.instance.isRunning) {
      setState(() => _error = '已有同步批次在运行');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    _stopRequested = false;
    _recovering = true;
    var completed = 0;
    final failures = <String>[];
    try {
      final fingerprints = _selected.toList();
      final List<AutoSyncResult> outcomes;
      if (widget.resumeRecovery == null) {
        outcomes = await AutoSyncSession.instance.runRecoveryBatch(
          fingerprints,
          replaceExisting: replaceExisting,
          uploadToStrava: uploadToStrava,
          writeToHealth: writeToHealth,
          customTitle: customTitle,
          onHealthNearby: (prompt) => mounted
              ? showAppleHealthNearbyDialog(context, prompt)
              : Future.value(AppleHealthNearbyDecision.skipOnce),
          onLegacy: (prompt) => mounted
              ? showLegacyRecoveryDialog(context, prompt)
              : Future.value(LegacyRecoveryDecision.stop),
        );
      } else {
        outcomes = [];
        for (final fingerprint in fingerprints) {
          if (_stopped) break;
          outcomes.add(await widget.resumeRecovery!(fingerprint));
        }
      }
      for (final result in outcomes) {
        if (result.succeeded) {
          completed++;
        } else {
          failures.add(result.message ?? '恢复失败');
        }
      }
      if (mounted) {
        setState(
          () => _error =
              '已处理 $completed 条${failures.isEmpty ? '' : '，失败 ${failures.length} 条：${failures.first}'}',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = '恢复同步失败，请检查授权与网络后重试');
    } finally {
      _recovering = false;
      if (mounted) setState(() => _busy = false);
    }
    await _reload(preserveMessage: true);
  }
}
