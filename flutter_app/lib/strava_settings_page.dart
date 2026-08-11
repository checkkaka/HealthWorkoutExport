import 'package:flutter/material.dart';

import 'native_channels.dart';
import 'src/rust/api/simple.dart';

typedef StravaCodeExchange =
    Future<StravaTokenResult> Function({
      required String clientId,
      required String clientSecret,
      required String code,
    });

class StravaSettingsPage extends StatefulWidget {
  const StravaSettingsPage({
    super.key,
    this.store = const StravaSettingsStore(),
    this.oauth = const StravaOAuthChannel(),
    this.exchangeCode = stravaExchangeCode,
  });

  final StravaSettingsStore store;
  final StravaOAuthChannel oauth;
  final StravaCodeExchange exchangeCode;

  @override
  State<StravaSettingsPage> createState() => _StravaSettingsPageState();
}

class _StravaSettingsPageState extends State<StravaSettingsPage> {
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  StravaSettingsSnapshot? _settings;
  String? _message;
  var _loading = true;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _clientId.dispose();
    _clientSecret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Strava 设置')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : settings == null
          ? _errorCard()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SegmentedButton<StravaUploadMode>(
                  segments: const [
                    ButtonSegment(
                      value: StravaUploadMode.api,
                      label: Text('API'),
                    ),
                    ButtonSegment(
                      value: StravaUploadMode.web,
                      label: Text('网页'),
                    ),
                  ],
                  selected: {settings.mode},
                  onSelectionChanged: _busy
                      ? null
                      : (selection) => _setMode(selection.single),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('上传前 GCJ-02 → WGS-84'),
                  subtitle: const Text('默认关闭；仅轨迹在 Strava 偏移时开启。'),
                  value: settings.gcjCorrectionEnabled,
                  onChanged: _busy ? null : _setGcjCorrection,
                ),
                const Divider(height: 32),
                if (settings.mode == StravaUploadMode.api)
                  ..._apiSettings(settings)
                else
                  ..._webSettings(settings),
                if (_message != null) ...[
                  const SizedBox(height: 16),
                  Text(_message!, key: const Key('stravaSettingsMessage')),
                ],
              ],
            ),
    );
  }

  List<Widget> _apiSettings(StravaSettingsSnapshot settings) => [
    TextField(
      key: const Key('stravaClientId'),
      controller: _clientId,
      enabled: !_busy,
      keyboardType: TextInputType.number,
      autocorrect: false,
      decoration: const InputDecoration(labelText: 'Client ID'),
      onChanged: (_) => setState(() {}),
    ),
    const SizedBox(height: 12),
    TextField(
      key: const Key('stravaClientSecret'),
      controller: _clientSecret,
      enabled: !_busy,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      decoration: const InputDecoration(labelText: 'Client Secret'),
      onChanged: (_) => setState(() {}),
    ),
    const SizedBox(height: 16),
    FilledButton(
      onPressed:
          _busy ||
              _clientId.text.trim().isEmpty ||
              _clientSecret.text.trim().isEmpty
          ? null
          : _authorize,
      child: Text(_busy ? '授权中…' : '保存并授权 Strava'),
    ),
    const SizedBox(height: 12),
    Text(settings.isApiReady ? '已授权' : '未授权'),
    const SizedBox(height: 8),
    const Text(
      '授权回调域填写 localhost；App 回调为 '
      'healthworkoutexport://localhost/callback。',
    ),
  ];

  List<Widget> _webSettings(StravaSettingsSnapshot settings) => [
    Text(settings.webCookieHeader.isEmpty ? '未登录' : '已有 Cookie'),
    const SizedBox(height: 8),
    const Text('网页登录与彻底清除 WKWebView Cookie 将在网页同步切片接入。'),
  ];

  Widget _errorCard() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_message ?? '无法读取 Strava 设置'),
          const SizedBox(height: 12),
          FilledButton(onPressed: _load, child: const Text('重试')),
        ],
      ),
    ),
  );

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final settings = await widget.store.load();
      if (!mounted) return;
      _clientId.text = settings.clientId;
      _clientSecret.text = settings.clientSecret;
      setState(() {
        _settings = settings;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _settings = null;
        _loading = false;
        _message = error.toString();
      });
    }
  }

  Future<void> _authorize() async {
    final clientId = _clientId.text.trim();
    final clientSecret = _clientSecret.text.trim();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final code = await widget.oauth.authorize(
        StravaOAuthChannel.authorizationUri(clientId),
      );
      final token = await widget.exchangeCode(
        clientId: clientId,
        clientSecret: clientSecret,
        code: code,
      );
      await widget.store.saveAuthorization(
        clientId: clientId,
        clientSecret: clientSecret,
        accessToken: token.accessToken,
        refreshToken: token.refreshToken,
        expiresAtSeconds: token.expiresAt.toDouble(),
      );
      final settings = await widget.store.load();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _message = 'Strava API 授权成功';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setMode(StravaUploadMode mode) async {
    setState(() => _busy = true);
    try {
      await widget.store.setMode(mode);
      final settings = await widget.store.load();
      if (!mounted) return;
      setState(() => _settings = settings);
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setGcjCorrection(bool enabled) async {
    setState(() => _busy = true);
    try {
      await widget.store.setGcjCorrectionEnabled(enabled);
      final settings = await widget.store.load();
      if (mounted) setState(() => _settings = settings);
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
