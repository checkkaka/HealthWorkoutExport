import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'native_channels.dart';
import 'src/rust/api/simple.dart';
import 'strava_upload_api.dart' show stravaUploadSession;
import 'virtual_power_settings.dart';

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
    this.web = const StravaWebChannel(),
    this.exchangeCode = stravaExchangeCode,
    this.loadRateLimit,
  });

  final StravaSettingsStore store;
  final StravaOAuthChannel oauth;
  final StravaWebChannel web;
  final StravaCodeExchange exchangeCode;
  final Future<StravaRateLimitResult> Function()? loadRateLimit;

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
  var _authorizing = false;
  var _authGeneration = 0;
  StravaRateLimitResult? _quota;
  var _quotaLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _authGeneration++;
    if (_authorizing) widget.oauth.cancel().catchError((Object _) {});
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
                if (settings.mode == StravaUploadMode.api) ...[
                  const Divider(height: 32),
                  Text(
                    'API 请求限额',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (_quota case final quota?) ...[
                    Text(
                      '15 分钟：${quota.overall.fifteenMinutesUsed}/${quota.overall.fifteenMinutesLimit}',
                    ),
                    Text(
                      '每日：${quota.overall.dailyUsed}/${quota.overall.dailyLimit}',
                    ),
                    if (quota.read case final read?)
                      Text(
                        '读取请求：15 分钟 ${read.fifteenMinutesUsed}/${read.fifteenMinutesLimit}；每日 ${read.dailyUsed}/${read.dailyLimit}',
                      ),
                    if (quota.rateLimited) const Text('已触发限流，请等待配额恢复'),
                  ] else
                    const Text('刷新后显示 Strava 响应头中的当前限额'),
                  TextButton(
                    onPressed: _quotaLoading || !settings.isApiReady
                        ? null
                        : _refreshQuota,
                    child: Text(_quotaLoading ? '读取中…' : '刷新限额'),
                  ),
                ],
                const VirtualPowerSettingsCard(),
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
      decoration: InputDecoration(
        labelText: 'Client Secret',
        helperText: settings.hasClientSecret ? 'Client Secret 已保存' : null,
      ),
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
    if (_authorizing)
      TextButton(onPressed: _cancelAuthorization, child: const Text('取消授权')),
    const SizedBox(height: 12),
    Text(settings.isApiReady ? '已授权' : '未授权'),
    const SizedBox(height: 8),
    const Text(
      '授权回调域填写 localhost；App 回调为 '
      'healthworkoutexport://localhost/callback；Windows 使用本机 127.0.0.1 临时回调。',
    ),
  ];

  List<Widget> _webSettings(StravaSettingsSnapshot settings) => [
    Text(settings.isWebReady ? '已有网页登录凭据' : '无网页登录凭据'),
    const SizedBox(height: 12),
    FilledButton(
      key: const Key('stravaWebLogin'),
      onPressed: _busy ? null : _loginWeb,
      child: Text(_busy ? '处理中…' : '打开 Strava 登录'),
    ),
    const SizedBox(height: 8),
    OutlinedButton(
      key: const Key('stravaWebClear'),
      onPressed: _busy ? null : _clearWebCookies,
      child: const Text('彻底清除网页登录'),
    ),
    const SizedBox(height: 8),
    const Text('登录凭据仅保存在系统安全存储中。'),
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
      // 原生状态只返回是否已保存；旧 secret 永不回填到 Flutter 控件。
      _clientSecret.clear();
      setState(() {
        _settings = settings;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _settings = null;
        _loading = false;
        _message = _safeErrorMessage(error);
      });
    }
  }

  Future<void> _refreshQuota() async {
    setState(() => _quotaLoading = true);
    try {
      final override = widget.loadRateLimit;
      StravaRateLimitResult value;
      if (override != null) {
        value = await override();
      } else {
        final token = await stravaUploadSession.accessToken();
        final handle = stravaReserveRemoteRead(
          operationId: 'quota-${DateTime.now().microsecondsSinceEpoch}',
        ).handle;
        try {
          value = await stravaFetchRateLimitUsage(
            operationHandle: handle,
            accessToken: token,
          );
        } finally {
          stravaReleaseRemoteRead(operationHandle: handle);
        }
      }
      if (mounted) setState(() => _quota = value);
    } catch (_) {
      if (mounted) setState(() => _message = '无法读取限额，请检查授权和网络后重试');
    } finally {
      if (mounted) setState(() => _quotaLoading = false);
    }
  }

  Future<void> _cancelAuthorization() async {
    _authGeneration++;
    try {
      await widget.oauth.cancel();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _authorizing = false;
        _busy = false;
        _message = '已取消授权';
      });
    }
  }

  Future<void> _authorize() async {
    if (_busy) return;
    final generation = ++_authGeneration;
    final clientId = _clientId.text.trim();
    final clientSecret = _clientSecret.text.trim();
    setState(() {
      _busy = true;
      _authorizing = true;
      _message = null;
    });
    try {
      final code = await widget.oauth.authorize(
        StravaOAuthChannel.authorizationUri(clientId),
      );
      if (!mounted || generation != _authGeneration) return;
      final token = await widget.exchangeCode(
        clientId: clientId,
        clientSecret: clientSecret,
        code: code,
      );
      if (!mounted || generation != _authGeneration) return;
      await widget.store.saveAuthorization(
        clientId: clientId,
        clientSecret: clientSecret,
        accessToken: token.accessToken,
        refreshToken: token.refreshToken,
        expiresAtSeconds: token.expiresAt.toDouble(),
      );
      _clientSecret.clear();
      final settings = await widget.store.load();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _message = 'Strava API 授权成功';
      });
    } catch (error) {
      if (!mounted || generation != _authGeneration) return;
      setState(() => _message = _safeErrorMessage(error));
    } finally {
      if (mounted && generation == _authGeneration) {
        setState(() {
          _busy = false;
          _authorizing = false;
        });
      }
    }
  }

  Future<void> _loginWeb() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (!await widget.web.login()) {
        throw const FormatException('Strava 网页登录未完成');
      }
      final settings = await widget.store.load();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _message = 'Strava 网页登录成功';
      });
    } catch (error) {
      if (mounted) setState(() => _message = _safeErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearWebCookies() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除 Strava 网页登录？'),
        content: const Text('会移除本机网页登录凭据，需要重新登录才能继续网页同步，不会删除活动。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除登录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.web.clearCookies();
      final settings = await widget.store.load();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _message = 'Strava 网页登录已彻底清除';
      });
    } catch (error) {
      if (mounted) setState(() => _message = _safeErrorMessage(error));
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
      if (mounted) setState(() => _message = _safeErrorMessage(error));
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
      if (mounted) setState(() => _message = _safeErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

String _safeErrorMessage(Object error) {
  if (error is PlatformException && error.message?.isNotEmpty == true) {
    return error.message!;
  }
  if (error case FormatException(message: final message)) {
    return message.toString();
  }
  return 'Strava 操作失败，请重试';
}
