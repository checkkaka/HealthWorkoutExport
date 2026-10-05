import 'package:flutter/material.dart';

class SyncResultMessages extends StatelessWidget {
  const SyncResultMessages({super.key, required this.messages});
  final List<String> messages;
  @override
  Widget build(BuildContext context) => messages.isEmpty
      ? const SizedBox.shrink()
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '逐条结果（${messages.length}）',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            SizedBox(
              height: 220,
              child: ListView.separated(
                primary: false,
                itemCount: messages.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, index) => Text(messages[index]),
              ),
            ),
          ],
        );
}
