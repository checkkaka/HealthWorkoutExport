import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// Copies only synthetic test evidence to the host artifact directory.
Future<void> main() async {
  final output = Platform.environment['HWE_RUNTIME_OUTPUT'];
  if (output == null || output.isEmpty) {
    throw StateError('HWE_RUNTIME_OUTPUT is required');
  }
  final directory = Directory(output);
  await directory.create(recursive: true);
  await integrationDriver(
    timeout: const Duration(minutes: 15),
    writeResponseOnFailure: true,
    responseDataCallback: (data) async {
      final report = Map<String, dynamic>.from(data ?? <String, dynamic>{});
      final screenshots = report.remove('screenshots') as List<dynamic>? ?? [];
      final filenames = <String>[];
      for (final value in screenshots) {
        final screenshot = Map<String, dynamic>.from(value as Map);
        final name = screenshot['name'] as String;
        if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name)) {
          throw StateError('Invalid screenshot name');
        }
        final filename = '$name.png';
        await File('${directory.path}/$filename').writeAsBytes(
          base64Decode(screenshot['pngBase64'] as String),
          flush: true,
        );
        filenames.add(filename);
      }
      report['screenshots'] = filenames;
      report['screenshotScope'] =
          'Flutter rendered surface; native dialogs and OS chrome excluded';
      await File('${directory.path}/results.json').writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
        flush: true,
      );
    },
  );
}
