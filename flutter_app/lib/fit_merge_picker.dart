import 'package:flutter/material.dart';

final class FitMergePickItem {
  const FitMergePickItem({
    required this.id,
    required this.title,
    required this.start,
  });
  final String id;
  final String title;
  final DateTime start;
}

/// A bounded selection UI; data loading and authorization remain with the source.
class FitMergePicker extends StatefulWidget {
  const FitMergePicker({super.key, required this.activities});
  final List<FitMergePickItem> activities;
  @override
  State<FitMergePicker> createState() => _FitMergePickerState();
}

class _FitMergePickerState extends State<FitMergePicker> {
  final _selected = <String>{};
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                Text('选择健康训练（${_selected.length}）'),
                TextButton(
                  onPressed: () => setState(() {
                    if (_selected.length == widget.activities.length) {
                      _selected.clear();
                    } else {
                      _selected.addAll(widget.activities.map((a) => a.id));
                    }
                  }),
                  child: Text(
                    _selected.length == widget.activities.length
                        ? '取消全选'
                        : '全选',
                  ),
                ),
                FilledButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.pop(
                          context,
                          widget.activities
                              .where((a) => _selected.contains(a.id))
                              .map((a) => a.id)
                              .toList(),
                        ),
                  child: const Text('添加'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final activity in widget.activities)
                  CheckboxListTile(
                    value: _selected.contains(activity.id),
                    title: Text(activity.title),
                    subtitle: Text(activity.start.toString()),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        _selected.add(activity.id);
                      } else {
                        _selected.remove(activity.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
