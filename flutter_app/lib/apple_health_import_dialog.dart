import 'package:flutter/material.dart';

import 'apple_health_import.dart';

/// Dismissal/back and a vanished host skip this attempt only. Permanent skips
/// require an explicit choice; stopping never persists a skip for future runs.
Future<AppleHealthNearbyDecision> showAppleHealthNearbyDialog(
  BuildContext context,
  AppleHealthNearbyPrompt prompt,
) async {
  if (!context.mounted) return AppleHealthNearbyDecision.skipOnce;
  final choice = await showDialog<AppleHealthNearbyDecision>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text('确认写入健康：${prompt.activityTitle}'),
      content: Text(prompt.nearbySummary),
      actions: [
        for (final choice in AppleHealthNearbyDecision.values)
          TextButton(
            key: ValueKey('health-decision-${choice.name}'),
            onPressed: () => Navigator.pop(context, choice),
            child: Text(switch (choice) {
              AppleHealthNearbyDecision.write => '仍然写入',
              AppleHealthNearbyDecision.writeRestOfBatch => '本批接近训练都写入',
              AppleHealthNearbyDecision.skip => '跳过此训练',
              AppleHealthNearbyDecision.skipRestOfBatch => '跳过本批接近训练',
              AppleHealthNearbyDecision.skipOnce => '仅本次不写',
              AppleHealthNearbyDecision.cancelBatch => '停止本批健康写入',
            }),
          ),
      ],
    ),
  );
  return choice ?? AppleHealthNearbyDecision.skipOnce;
}
