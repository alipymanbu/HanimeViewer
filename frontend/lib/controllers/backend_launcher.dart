import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_config.dart';

/// 后端进程的启动与退出管理。
///
/// 目标：用户双击 App 就能用，不需要自己去开调试 Chrome、也不需要在终端起 uvicorn。
///
/// 两种情况：
/// 1. **已打包**：同目录下有 `hanime_backend.exe`（PyInstaller 产物），直接启动它。
/// 2. **开发中**：回退到用项目里的 `.venv` 跑 `python -m uvicorn`。
///
/// 后端自己负责把调试 Chrome 拉起来（见 backend/browser.py），
/// 所以这里只需要管后端进程。
/// 后端启动结果：(是否成功, 是不是外部已经在跑, 失败原因)
typedef BackendStart = (bool ok, bool alreadyRunning, String error);

class BackendLauncher {
  BackendLauncher._();

  static Process? _process;

  /// 后端是不是我们自己启动的（如果是连的别人已经开好的后端，就不该去杀它）
  static bool _startedByUs = false;

  static bool get startedByUs => _startedByUs;

  /// 项目根目录（开发模式下用）。
  ///
  /// 打包后 exe 在 `frontend/build/windows/x64/runner/Release/`，
  /// 往上四层是项目根；开发时进程在 `frontend/`，往上两层是项目根。
  static String? _findProjectRoot() {
    var dir = File(Platform.resolvedExecutable).parent;

    for (var i = 0; i < 6; i++) {
      final backendDir = Directory('${dir.path}${Platform.pathSeparator}backend');

      if (backendDir.existsSync()) {
        return dir.path;
      }

      final parent = dir.parent;

      if (parent.path == dir.path) break;

      dir = parent;
    }

    return null;
  }

  /// 打包后可执行文件的位置。
  static String? _findBundledBackend() {
    final exeDir = File(Platform.resolvedExecutable).parent;

    final candidates = [
      '${exeDir.path}${Platform.pathSeparator}hanime_backend.exe',
      '${exeDir.path}${Platform.pathSeparator}backend'
          '${Platform.pathSeparator}hanime_backend.exe',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) return path;
    }

    return null;
  }

  /// 后端是否已经在跑（可能是我们自己起的，也可能是外部起好的）。
  static Future<bool> isBackendAlive({Duration? timeout}) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = timeout ?? const Duration(seconds: 2);

      final request = await client.getUrl(
        Uri.parse('${AppConfig.backendBase}/'),
      );

      final response = await request.close();

      await response.drain<void>();

      client.close();

      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 启动后端。返回 (成功, 错误信息)。
  ///
  /// 如果后端已经在跑，会直接复用，不会重复启动。
  /// 和 [start] 一样，但顺带算出「是不是外部已经在跑」。
  ///
  /// **返回 Future 而不是 await 完再返回**：调用方（`main()`）拿到 Future
  /// 就往下走、先把界面推出来，等它的活儿交给启动页。
  /// 冷启动时 [start] 要 2100ms 左右（`isBackendAlive()` 探测端口的超时），
  /// 挡在首帧前面的话窗口要 2 秒之后才出现。
  static Future<BackendStart> startWithStatus() async {
    final (ok, error) = await start();

    return (ok, ok && !startedByUs, error);
  }

  static Future<(bool, String)> start() async {
    if (await isBackendAlive()) {
      _startedByUs = false;

      return (true, '');
    }

    if (!Platform.isWindows) {
      return (false, '目前只支持 Windows 自动启动后端');
    }

    final bundled = _findBundledBackend();

    try {
      if (bundled != null) {
        _process = await Process.start(
          bundled,
          [
            '--port', '${AppConfig.backendPort}',
            '--cdp-port', '${AppConfig.cdpPort}',
          ],
          workingDirectory: File(bundled).parent.path,
          // 注意：这里**不能**用 detachedWithStdio。
          // 那个模式会让后端脱离 App 独立存活，
          // 结果 App 关掉了后端还在跑、端口一直占着。
          mode: ProcessStartMode.normal,
        );
      } else {
        // 开发模式：用项目里的 venv 跑 uvicorn
        final root = _findProjectRoot();

        if (root == null) {
          return (
            false,
            '找不到后端程序。请确认 hanime_backend.exe 与 App 在同一目录。',
          );
        }

        final python = '$root${Platform.pathSeparator}.venv'
            '${Platform.pathSeparator}Scripts'
            '${Platform.pathSeparator}python.exe';

        if (!File(python).existsSync()) {
          return (
            false,
            '找不到 Python 环境：$python\n'
                '开发模式下需要项目里的 .venv。',
          );
        }

        _process = await Process.start(
          python,
          [
            '-m', 'uvicorn', 'main:app',
            '--host', '127.0.0.1',
            '--port', '${AppConfig.backendPort}',
          ],
          workingDirectory:
              '$root${Platform.pathSeparator}backend',
          environment: {
            'HANIME_CDP_PORT': '${AppConfig.cdpPort}',
          },
          mode: ProcessStartMode.normal,
        );
      }

      _startedByUs = true;

      // 必须**主动把这些管道读空**。
      //
      // 踩过的坑：之前用 debugPrint 输出后端日志，但
      //   - debugPrint 带限流（每约 12KB 就暂停一下）
      //   - 而且 release 构建下 print() 根本不输出
      // 结果管道没人读 -> 子进程写日志时阻塞 -> 后端起不来，
      // 表现就是「后端启动超时」，但手动跑 hanime_backend.exe 却正常。
      //
      // 所以这里只管把数据读走丢掉，不依赖 debugPrint。
      _drain(_process!.stdout);
      _drain(_process!.stderr);

      return (true, '');
    } catch (e) {
      return (false, '启动后端失败：$e');
    }
  }

  /// 把管道读空（内容丢弃，只为了防止子进程写阻塞）。
  static void _drain(Stream<List<int>> stream) {
    final lastLines = <String>[];

    stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
      (line) {
        // 只留最后几行，出错时能拿出来给用户看
        lastLines.add(line);

        if (lastLines.length > _recentOutputLimit) {
          lastLines.removeAt(0);
        }

        _recentOutput = List<String>.unmodifiable(lastLines);
      },
      onError: (_) {},
      cancelOnError: false,
    );
  }

  static const int _recentOutputLimit = 30;

  static List<String> _recentOutput = const [];

  /// 后端最近的输出（用来在启动失败时给出真实原因，而不是一句「超时」）。
  static List<String> get recentOutput => _recentOutput;

  /// 等后端就绪。
  static Future<bool> waitUntilReady({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      if (await isBackendAlive()) return true;

      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    return false;
  }

  /// 退出时收尾：只结束我们自己启动的后端。
  ///
  /// **发完关闭请求就返回，不等浏览器收尾。**
  ///
  /// 后端是独立进程：它收到 `/api/shutdown` 后会自己起一个后台线程，
  /// 先把隐藏的调试浏览器收掉、再 `os._exit(0)` —— 这跟我们还在不在
  /// 完全无关。所以没必要在这儿干等。
  ///
  /// 以前这里会轮询 `/api/status` 等 `cdp_alive` 变 false（最多 20 秒），
  /// 等完再 `taskkill /T /F`。两个问题：
  ///   1. 开了 preventClose 之后这段时间窗口就卡着不动（用户反馈 4~5 秒）；
  ///   2. `taskkill /T /F` 会**打断**后端正在做的收尾，
  ///      反而留下 13 个隐藏的 chrome.exe（当初就是为了这个才加的等待）。
  ///
  /// 现在：请求发出去就结束。只有请求**没发出去**（后端已经卡死或没了）
  /// 才退回强杀。
  static Future<void> stop() async {
    if (!_startedByUs) return;

    final process = _process;

    _process = null;
    _startedByUs = false;

    if (process == null) return;

    var requestSent = false;

    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);

      final request = await client.postUrl(
        Uri.parse('${AppConfig.backendBase}/api/shutdown'),
      );

      final response = await request.close();

      await response.drain<void>();

      client.close();

      requestSent = response.statusCode == 200;
    } catch (_) {
      // 后端可能已经自己退了，也可能卡住了 —— 下面按情况处理
    }

    if (requestSent) {
      // 后端答应了，剩下的交给它自己。这里**不能**再 taskkill，
      // 那会把正在收尾的进程打断，浏览器就留在后台了。
      return;
    }

    // 请求都没发成功：后端多半已经不动了，只好强杀进程树。
    // 只杀外层是不够的：PyInstaller onefile 是「引导进程 + 应用进程」两层。
    try {
      if (Platform.isWindows) {
        await Process.run(
          'taskkill',
          ['/PID', '${process.pid}', '/T', '/F'],
        );
      } else {
        process.kill();
      }
    } catch (_) {
      try {
        process.kill();
      } catch (_) {}
    }
  }
}
