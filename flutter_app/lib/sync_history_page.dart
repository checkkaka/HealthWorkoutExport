import 'package:flutter/material.dart';

import 'auto_sync_session.dart';
import 'sync_state_store.dart';

class SyncHistoryPage extends StatefulWidget {
  const SyncHistoryPage({super.key});

  @override
  State<SyncHistoryPage> createState() => _SyncHistoryPageState();
}

class _SyncHistoryPageState extends State<SyncHistoryPage> {
  final _store = SyncStateStore();
  var _records = <String, Map<String, Object?>>{};
  var _filter = 'all';
  final _selected = <String>{};
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
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
                      'noRemote': '无远端 ID',
                    }.entries)
                      ChoiceChip(
                        label: Text(entry.value),
                        selected: _filter == entry.key,
                        onSelected: (_) => setState(() => _filter = entry.key),
                      ),
                  ],
                ),
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(error),
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final fingerprint in items)
                        CheckboxListTile(
                          value: _selected.contains(fingerprint),
                          onChanged: (_) => setState(() {
                            if (!_selected.add(fingerprint)) {
                              _selected.remove(fingerprint);
                            }
                          }),
                          title: Text(
                            '${_records[fingerprint]?['title'] ?? fingerprint.substring(0, 8)}',
                          ),
                          subtitle: Text(_statusLine(fingerprint)),
                        ),
                    ],
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        OutlinedButton(
                          onPressed: _selected.isEmpty ? null : _resync,
                          child: const Text('覆盖重传'),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: _selected.isEmpty ? null : _delete,
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
    return _records.keys.where((fingerprint) {
      final record = _records[fingerprint];
      final status = record?['status'] as String? ?? '';
      final remoteId = record?['remoteId'] as String?;
      return switch (_filter) {
        'failed' => status == 'failed',
        'noRemote' => remoteId == null || remoteId.isEmpty,
        _ => true,
      };
    }).toList();
  }

  String _statusLine(String fingerprint) {
    final record = _records[fingerprint];
    final status = record?['status'] ?? '';
    final remoteId = record?['remoteId'];
    return '$status${remoteId == null ? '' : ' · $remoteId'}';
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
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
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _delete() async {
    for (final fingerprint in _selected.toList()) {
      await _store.remove(fingerprint);
    }
    _selected.clear();
    await _reload();
  }

  Future<void> _resync() async {
    final session = AutoSyncSession.instance;
    try {
      for (final fingerprint in _selected.toList()) {
        await session.resumeRecovery(fingerprint);
      }
      await _reload();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }
}
