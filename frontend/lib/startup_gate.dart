import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'controllers/app_config.dart';
import 'controllers/backend_launcher.dart';
import 'widgets/hanime_logo.dart';

/// 启动页：负责把「后端 + 调试浏览器」等起来。
///
/// 以前是需要用户自己开调试 Chrome、再在终端起 uvicorn，缺一步就各种报错。
/// 现在 App 自己拉起后端，后端再自己拉起调试浏览器，
/// 这个页面负责显示进度并在就绪后进入主界面。
class StartupGate extends StatefulWidget {
  /// 启动后端的 Future（`BackendLauncher.startWithStatus()` 的结果）。
  ///
  /// 收 Future 而不是已经算好的值：后端冷启动要 2 秒左右，
  /// 在 `main()` 里等它算完的话首帧就得等到 2 秒之后 ——
  /// 窗口会一直不出现。所以界面先出来（本页就是加载页），
  /// 在这里再等这个 Future。
  final Future<BackendStart>? backendStart;

  /// 就绪后要展示的页面
  final Widget child;

  const StartupGate({
    super.key,
    required this.child,
    this.backendStart,
  });

  @override
  State<StartupGate> createState() => _StartupGateState();
}

enum _Phase { connecting, startingBrowser, ready, failed }

class _StartupGateState extends State<StartupGate> {
  _Phase _phase = _Phase.connecting;
  String _error = '';

  /// 后端本来就在跑（我们只负责等）—— 只用来选错误提示的措辞
  bool _alreadyRunning = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _pollStatus() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);

    try {
      final request = await client.getUrl(
        Uri.parse('${AppConfig.backendBase}/api/status'),
      );

      final response = await request.close();

      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        throw Exception('后端返回 ${response.statusCode}');
      }

      final data = jsonDecode(body);

      if (data is! Map) {
        throw Exception('状态返回格式不正确');
      }

      final cdpAlive = data['cdp_alive'] == true;
      final pageCount = int.tryParse('${data['page_count']}') ?? 0;
      final browserFound = data['browser_found'] == true;

      if (!browserFound) {
        _phase = _Phase.failed;
        _error = '找不到 Chrome 或 Edge。\n'
            '请安装 Chrome 后重试。';
        return;
      }

      if (cdpAlive && pageCount > 0) {
        _phase = _Phase.ready;
        return;
      }

      // 后端起来了但浏览器还没就绪：让后端把它拉起来
      _phase = _Phase.startingBrowser;

      await _requestBrowserStart(client);
    } finally {
      client.close();
    }
  }

  Future<void> _requestBrowserStart(HttpClient client) async {
    try {
      final request = await client.postUrl(
        Uri.parse('${AppConfig.backendBase}/api/browser/start'),
      );

      final response = await request.close();

      await response.drain<void>();
    } catch (_) {
      // 下一轮轮询会再试
    }
  }

  Future<void> _boot() async {
    // 0. 先等「启动后端」这一步出结果
    //    （main() 里只是把 Future 递过来，没等它）
    if (widget.backendStart != null) {
      final (ok, alreadyRunning, error) = await widget.backendStart!;

      if (!mounted) return;

      _alreadyRunning = alreadyRunning;

      if (!ok) {
        // 启动后端这一步就失败了，没必要再去等超时
        setState(() {
          _phase = _Phase.failed;
          _error = error;
        });

        return;
      }
    }

    // 1. 等后端起来（可能已经在跑，也可能是刚启动的）
    final ready = await _waitBackend();

    if (!mounted) return;

    if (!ready) {
      final lines = BackendLauncher.recentOutput;

      setState(() {
        _phase = _Phase.failed;
        _error = _alreadyRunning
            ? '连接后端超时。\n请确认后端已在 ${AppConfig.backendBase} 运行。'
            : '后端启动超时。\n\n'
                '程序位置：${Platform.resolvedExecutable}\n'
                '当前目录：${Directory.current.path}\n'
                '${lines.isEmpty ? '后端没有任何输出。' : '后端最后的输出：\n${lines.join('\n')}'}';
      });

      return;
    }

    // 2. 等后端把调试浏览器拉起来
    final deadline = DateTime.now().add(const Duration(seconds: 90));

    while (DateTime.now().isBefore(deadline)) {
      if (!mounted) return;

      try {
        await _pollStatus();
      } catch (_) {
        // 后端还没起来时会连不上，忽略，下一轮继续等
      }

      if (_phase == _Phase.ready) {
        if (mounted) setState(() {});
        return;
      }

      if (_phase == _Phase.failed) {
        if (mounted) {
          setState(() => _error = _error.isEmpty ? '启动失败' : _error);
        }
        return;
      }

      if (mounted) setState(() {});

      await Future<void>.delayed(const Duration(milliseconds: 700));
    }

    if (!mounted) return;

    setState(() {
      _phase = _Phase.failed;
      _error = '调试浏览器启动超时。\n'
          '请确认本机装有 Chrome，且端口 ${AppConfig.cdpPort} 没有被占用。';
    });
  }

  Future<bool> _waitBackend() async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));

    while (DateTime.now().isBefore(deadline)) {
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 2);

        final request = await client.getUrl(
          Uri.parse('${AppConfig.backendBase}/'),
        );

        final response = await request.close();

        await response.drain<void>();
        client.close();

        if (response.statusCode == 200) return true;
      } catch (_) {
        // 还没起来，继续等
      }

      if (!mounted) return false;


      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_phase == _Phase.ready) {
      return widget.child;
    }

    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const HanimeLogo(height: 80),
                const SizedBox(height: 28),
                const Text(
                  'HanimeViewer',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                // 启动中：不放加载动画，也不放"正在启动后端…"那行字 ——
                // 用户要求去掉，界面上只留图标和名字。
                if (_phase == _Phase.failed) ...[
                  const SizedBox(height: 28),
                  Icon(
                    Icons.error_outline,
                    size: 40,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 13),
                  Text(
                    _error,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      height: 1.6,
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () {
                      setState(() {
                        _phase = _Phase.connecting;
                        _error = '';
                      });

                      _boot();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}