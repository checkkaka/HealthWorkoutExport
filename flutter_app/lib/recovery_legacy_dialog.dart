import 'package:flutter/material.dart';
import 'native_channels.dart';
import 'recovery_batch_checkpoint.dart';

Future<LegacyRecoveryDecision> showLegacyRecoveryDialog(
  BuildContext context,
  LegacyRecoveryPrompt prompt,
) async {
  final choice = await showDialog<LegacyRecoveryDecision>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text('确认旧恢复文件：${prompt.title}'),
      content: const Text(
        '旧版本没有记录原活动是否已删除，无法安全推断。请先检查 Strava：仅上传不会删除活动，但可能出现重复；删除并覆盖会永久丢失原评论、点赞和链接。取消会保留文件并暂停队列。',
      ),
      actions: [
        if (prompt.remoteId != null)
          TextButton(
            onPressed: () async {
              try {
                await const StravaWebChannel().openActivity(prompt.remoteId!);
              } catch (_) {}
            },
            child: const Text('检查原活动'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context, LegacyRecoveryDecision.stop),
          child: const Text('暂停队列'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, LegacyRecoveryDecision.skip),
          child: const Text('暂时跳过'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, LegacyRecoveryDecision.uploadOnly),
          child: const Text('仅上传，不删除'),
        ),
        if (prompt.remoteId != null)
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, LegacyRecoveryDecision.replaceRemote),
            child: const Text('删除原活动并覆盖'),
          ),
      ],
    ),
  );
  return choice ?? LegacyRecoveryDecision.stop;
}
