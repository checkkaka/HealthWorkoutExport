import 'dart:convert';
import 'dart:typed_data';

/// A bounded, credential-free batch snapshot. Activity bytes remain in the
/// protected FIT/recovery store; an app restart never resumes network work itself.
final class AutoSyncCheckpoint {
  const AutoSyncCheckpoint({
    required this.configuration,
    required this.completedIds,
  });
  final Map<String, Object?> configuration;
  final Set<String> completedIds;
  static const maxBytes = 4 * 1024 * 1024;

  Uint8List encode() {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'configuration': configuration,
          'completedIds': completedIds.toList()..sort(),
        }),
      ),
    );
    AutoSyncCheckpoint.decode(bytes);
    return bytes;
  }

  static void _keys(Map value, Set<String> allowed) {
    if (value.keys.any((key) => key is! String || !allowed.contains(key))) {
      throw const FormatException('批次文件包含未知字段');
    }
  }

  factory AutoSyncCheckpoint.decode(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('批次文件大小无效');
    }
    final root = jsonDecode(utf8.decode(bytes));
    if (root is! Map<String, dynamic> ||
        root['version'] != 1 ||
        root['configuration'] is! Map<String, dynamic> ||
        root['completedIds'] is! List) {
      throw const FormatException('批次文件格式无效');
    }
    _keys(root, const {'version', 'configuration', 'completedIds'});
    final config = root['configuration'] as Map<String, dynamic>;
    _keys(config, const {
      'primary',
      'supplements',
      'activities',
      'gcjEnabled',
      'skipLocalHistory',
      'mode',
      'virtualPower',
      'customTitle',
      'previewPolicy',
      'uploadToStrava',
      'writeToHealth',
    });
    const sources = {'healthkit', 'xingzhe', 'onelap'};
    final title = config['customTitle'];
    if ((title != null &&
            (title is! String ||
                utf8.encode(title).length > 8192 ||
                RegExp(r'[\x00-\x1f\x7f]').hasMatch(title))) ||
        (config['previewPolicy'] != null &&
            !{
              'issuesOnly',
              'everyActivity',
            }.contains(config['previewPolicy'])) ||
        (config['uploadToStrava'] != null &&
            config['uploadToStrava'] is! bool) ||
        (config['writeToHealth'] != null && config['writeToHealth'] is! bool) ||
        (config['uploadToStrava'] == false &&
            config['writeToHealth'] != true)) {
      throw const FormatException('同步目标或预览配置无效');
    }
    final primary = config['primary'];
    final supplements = config['supplements'];
    final activities = config['activities'];
    final completed = root['completedIds'] as List;
    if (!sources.contains(primary) ||
        supplements is! List ||
        supplements.length > 2 ||
        supplements.toSet().length != supplements.length ||
        supplements.contains(primary) ||
        supplements.any((value) => !sources.contains(value)) ||
        activities is! List ||
        activities.isEmpty ||
        activities.length > 10000 ||
        config['gcjEnabled'] is! bool ||
        config['skipLocalHistory'] is! bool ||
        !{'api', 'web'}.contains(config['mode'])) {
      throw const FormatException('批次配置无效');
    }
    final ids = <String>{};
    for (final raw in activities) {
      if (raw is! Map<String, dynamic>) throw const FormatException('批次活动无效');
      _keys(raw, const {
        'id',
        'title',
        'startMs',
        'endMs',
        'durationSeconds',
        'distanceMeters',
      });
      final id = raw['id'];
      final title = raw['title'];
      final start = raw['startMs'];
      final end = raw['endMs'];
      final duration = raw['durationSeconds'];
      final distance = raw['distanceMeters'];
      if (id is! String ||
          id.isEmpty ||
          id.length > 1024 ||
          !ids.add(id) ||
          title is! String ||
          title.length > 4096 ||
          start is! int ||
          end is! int ||
          end <= start ||
          start < -2208988800000 ||
          end > 7258118400000 ||
          duration is! num ||
          !duration.isFinite ||
          duration <= 0 ||
          (distance != null &&
              (distance is! num || !distance.isFinite || distance < 0))) {
        throw const FormatException('批次活动字段无效');
      }
    }
    if (completed.any((id) => id is! String || !ids.contains(id)) ||
        completed.toSet().length != completed.length) {
      throw const FormatException('批次进度无效');
    }
    final power = config['virtualPower'];
    if (power != null) {
      if (power is! Map || power['includeInertia'] is! bool) {
        throw const FormatException('虚拟功率配置无效');
      }
      _keys(power, const {
        'riderMassKg',
        'bikeMassKg',
        'cda',
        'includeInertia',
      });
      for (final key in ['riderMassKg', 'bikeMassKg', 'cda']) {
        final value = power[key];
        if (value is! num || !value.isFinite || value <= 0) {
          throw const FormatException('虚拟功率配置无效');
        }
      }
    }
    return AutoSyncCheckpoint(
      configuration: Map.unmodifiable(config),
      completedIds: Set.unmodifiable(completed.cast<String>()),
    );
  }
}
