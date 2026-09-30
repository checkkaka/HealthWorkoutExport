import 'package:flutter/material.dart';

import 'native_channels.dart';

class VirtualPowerSettingsCard extends StatefulWidget {
  const VirtualPowerSettingsCard({
    super.key,
    this.preferences = const PreferencesChannel(),
  });
  final PreferencesChannel preferences;
  @override
  State<VirtualPowerSettingsCard> createState() =>
      _VirtualPowerSettingsCardState();
}

class _VirtualPowerSettingsCardState extends State<VirtualPowerSettingsCard> {
  final _rider = TextEditingController(text: '70');
  final _bike = TextEditingController(text: '8.5');
  final _cda = TextEditingController(text: '0.3');
  var _enabled = false;
  var _inertia = true;
  var _loading = true;
  var _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _rider.dispose();
    _bike.dispose();
    _cda.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final enabled = await widget.preferences.read('virtualPower.enabled');
      final inertia = await widget.preferences.read(
        'virtualPower.includeInertia',
      );
      final rider = await widget.preferences.read('virtualPower.riderMassKg');
      final bike = await widget.preferences.read('virtualPower.bikeMassKg');
      final cda = await widget.preferences.read('virtualPower.cda');
      if (!mounted) return;
      setState(() {
        _enabled = enabled == true;
        _inertia = inertia != false;
        if (rider is num && rider.isFinite && rider > 0) _rider.text = '$rider';
        if (bike is num && bike.isFinite && bike > 0) _bike.text = '$bike';
        if (cda is num && cda.isFinite && cda > 0) _cda.text = '$cda';
      });
    } catch (_) {
      if (mounted) setState(() => _message = '无法读取虚拟功率设置');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('虚拟功率', style: Theme.of(context).textTheme.titleMedium),
          const Text(
            '开启后会把路线位置与活动日期发送给 Open-Meteo 获取历史天气，并估算和覆盖骑行功率。同步 FIT 会随活动上传到 Strava。默认关闭。',
          ),
          if (_loading) const LinearProgressIndicator(),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            key: const Key('virtualPowerEnabled'),
            title: const Text('估算虚拟功率'),
            value: _enabled,
            onChanged: _busy || _loading
                ? null
                : (value) async {
                    setState(() => _busy = true);
                    try {
                      await widget.preferences.write(
                        'virtualPower.enabled',
                        value,
                      );
                      if (mounted) setState(() => _enabled = value);
                    } catch (_) {
                      if (mounted) setState(() => _message = '保存失败，请重试');
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
          ),
          if (_enabled) ...[
            TextField(
              key: const Key('virtualPowerRider'),
              controller: _rider,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '骑手质量（kg）'),
            ),
            TextField(
              key: const Key('virtualPowerBike'),
              controller: _bike,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '车重（kg）'),
            ),
            TextField(
              key: const Key('virtualPowerCda'),
              controller: _cda,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '气动阻力面积 CdA（m²）'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('计入加速惯性'),
              value: _inertia,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _inertia = value),
            ),
            OutlinedButton(
              onPressed: _busy ? null : _save,
              child: const Text('保存功率参数'),
            ),
          ],
          if (_message case final message?) Text(message),
        ],
      ),
    ),
  );

  Future<void> _save() async {
    final rider = double.tryParse(_rider.text.trim());
    final bike = double.tryParse(_bike.text.trim());
    final cda = double.tryParse(_cda.text.trim());
    if ([
      rider,
      bike,
      cda,
    ].any((value) => value == null || !value.isFinite || value <= 0)) {
      setState(() => _message = '质量与 CdA 必须为大于 0 的有限数值');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.preferences.write('virtualPower.riderMassKg', rider!);
      await widget.preferences.write('virtualPower.bikeMassKg', bike!);
      await widget.preferences.write('virtualPower.cda', cda!);
      await widget.preferences.write('virtualPower.includeInertia', _inertia);
      if (mounted) setState(() => _message = '功率参数已保存');
    } catch (_) {
      if (mounted) setState(() => _message = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
