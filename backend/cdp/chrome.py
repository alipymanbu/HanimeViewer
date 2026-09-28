import json
import os
import threading
import time

import requests
import websocket


def _resolve_cdp_port():
    """调试端口。

    支持用环境变量覆盖，这样「后端自己拉起 Chrome」时可以统一改成别的端口
    （默认仍是历史行为的 9222）。
    """
    raw = os.environ.get("HANIME_CDP_PORT", "").strip()

    if raw.isdigit():
        return int(raw)

    return 9222


CDP_PORT = _resolve_cdp_port()

CDP_URL = f"http://127.0.0.1:{CDP_PORT}"

# 所有请求共用同一个 Chrome 标签页，必须串行，否则并发请求会互相把页面导航走，
# 导致 A 请求读到 B 请求的页面内容。这把锁保证「导航 + 取结果」是一个整体。
_NAVIGATE_LOCK = threading.RLock()

# 每个线程各持一条 CDP WebSocket。
# FastAPI 的同步接口跑在线程池里，多个线程共用一个 socket 会串包。
_LOCAL = threading.local()


def list_page_targets(timeout=5):
    """列出当前所有 page target。"""
    response = requests.get(f"{CDP_URL}/json", timeout=timeout)

    return [
        target
        for target in response.json()
        if target.get("type") == "page"
        and target.get("webSocketDebuggerUrl")
    ]


def _pick_page(pages):
    # 优先选择普通 http/https 页面，避免选到 devtools:// 之类的内部页面
    for target in pages:
        url = target.get("url", "")

        if url.startswith("http://") or url.startswith("https://"):
            return target["webSocketDebuggerUrl"]

    return pages[0]["webSocketDebuggerUrl"]


class ChromeCDP:
    def __init__(self):
        self.ws_url = self._get_page_websocket()

    # ---------- 连接管理 ----------

    def _get_page_websocket(self):
        """找到可用的 page target。

        如果浏览器没在跑，就自己把它拉起来 —— 这样用户不需要
        事先手动开一个带调试端口的 Chrome。
        """
        try:
            pages = list_page_targets()
        except Exception:
            pages = []

        if not pages:
            # 调试端口不通，尝试自己启动浏览器
            import browser as browser_module

            ok, message, _ = browser_module.ensure_browser(
                port=CDP_PORT
            )

            if not ok:
                raise Exception(
                    f"调试浏览器不可用：{message}"
                )

            pages = list_page_targets()

        if not pages:
            raise Exception("没有找到 Chrome page target")

        return _pick_page(pages)

    def _get_socket(self, timeout):
        # 同一个线程复用同一条连接，省掉每次 evaluate 都重新握手
        cached = getattr(_LOCAL, "socket", None)

        if cached is not None and getattr(_LOCAL, "ws_url", None) == self.ws_url:
            return cached

        # suppress_origin=True 是必须的：
        # Chrome 111 以后，CDP 的 WebSocket 会拒绝带 Origin 头的连接
        # （返回 403 Rejected an incoming WebSocket connection ...）。
        # websocket-client 默认会带上 Origin，所以要关掉。
        ws = websocket.create_connection(
            self.ws_url,
            timeout=timeout,
            suppress_origin=True,
        )
        _LOCAL.socket = ws
        _LOCAL.ws_url = self.ws_url

        return ws

    def _reconnect(self, timeout):
        """标签页可能被重建（webSocketDebuggerUrl 变了），重新解析一次。"""
        self.close()
        self.ws_url = self._get_page_websocket()
        _LOCAL.ws_url = None

        return self._get_socket(timeout)

    def close(self):
        ws = getattr(_LOCAL, "socket", None)

        if ws is not None:
            try:
                ws.close()
            except Exception:
                pass

            _LOCAL.socket = None
            _LOCAL.ws_url = None

    # ---------- 执行 ----------

    def evaluate(self, expression, timeout=30, await_promise=False):
        """在页面里执行 JS。

        await_promise=True 时等待返回的 Promise 结果
        （比如 `(async()=>{...})()` 里 fetch 的响应内容）。
        不开这个的话，Promise 会被当成普通对象返回 {},
        调用方会误以为"拿到了空结果"。
        """
        for attempt in (1, 2):
            ws = (
                self._get_socket(timeout)
                if attempt == 1
                else self._reconnect(timeout)
            )

            command = {
                "id": 1,
                "method": "Runtime.evaluate",
                "params": {
                    "expression": expression,
                    "returnByValue": True,
                    "awaitPromise": bool(await_promise),
                }
            }

            try:
                ws.send(json.dumps(command))

                while True:
                    message = json.loads(ws.recv())

                    if message.get("id") == 1:
                        return message["result"]["result"]
            except Exception:
                # 连接失效：丢掉并重建，重试一次
                self.close()

                if attempt == 2:
                    raise

    def get_title(self):
        result = self.evaluate("document.title")
        return result.get("value")

    def get_url(self):
        result = self.evaluate("location.href")
        return result.get("value")

    def get_html(self):
        result = self.evaluate("document.documentElement.outerHTML")
        return result.get("value")

    # ---------- 导航与就绪等待 ----------

    def navigate(self, url):
        expression = f"location.href = {json.dumps(url)}"
        self.evaluate(expression)

    @staticmethod
    def _normalize(url):
        """比较 URL 时忽略结尾斜杠和 #片段。"""
        if not url:
            return ""

        url = url.split("#", 1)[0].rstrip("/")

        return url

    def is_ready(
        self,
        target_url="",
        ready_selector="",
        ready_expr="",
        all_selectors=None,
    ):
        """页面是否已经可以安全读取。

        关键点一：`location.href = url` 是异步的，赋值完立刻返回，
        此时页面还是**旧的**。所以必须先确认当前 URL 已经变成目标 URL。

        关键点二：不要等 document.readyState === 'complete'。
        Hanime 的页面在内容早就画完之后，还会挂着广告/统计请求不放，
        实测 readyState 要 5.2 秒才 complete，而真正的视频列表
        1.2 秒左右就已经在 DOM 里了。

        关键点三：**必须要求所有关键元素都出现**（all_selectors）。
        只判断一个元素会踩坑：详情页的 #video-artist-name 会比
        <video>、.video-description-panel、相关影片区更早出现，
        只等它就可能在「页面画了一半」时把 HTML 取走，
        结果 sources / related 全是空 —— 这就是之前
        「有些视频进详情页后底下没有相关影片」的原因。
        """
        if target_url:
            try:
                current = self.evaluate("location.href").get("value") or ""
            except Exception:
                return False

            if self._normalize(current) != self._normalize(target_url):
                return False

        if all_selectors:
            checks = [
                f"!!document.querySelector({json.dumps(sel)})"
                for sel in all_selectors
            ]

            check = " && ".join(checks)
        elif ready_expr:
            check = ready_expr
        elif ready_selector:
            check = f"!!document.querySelector({json.dumps(ready_selector)})"
        else:
            check = "document.readyState === 'complete'"

        try:
            return bool(self.evaluate(check))
        except Exception:
            return False

    def wait_until_ready(
        self,
        target_url="",
        ready_selector="",
        ready_expr="",
        all_selectors=None,
        timeout=20.0,
        interval=0.15,
        min_stable=0.5,
    ):
        """轮询等待页面就绪，返回是否在超时前就绪。

        替换原来固定的 time.sleep(5)：
        - 内容就绪约 1.2 秒就返回，不再干等 5 秒
        - 页面慢时也不会过早取到半成品（旧写法固定 5 秒，
          而首页 readyState 要 5.2 秒才 complete，本来就不够）

        min_stable：要求就绪状态持续这么久才返回，
        避免刚好抓在 DOM 还在收尾的一瞬间。
        """
        deadline = time.monotonic() + timeout
        ready_since = None

        while True:
            if self.is_ready(
                target_url,
                ready_selector,
                ready_expr,
                all_selectors=all_selectors,
            ):
                if min_stable <= 0:
                    return True

                if ready_since is None:
                    ready_since = time.monotonic()
                elif time.monotonic() - ready_since >= min_stable:
                    return True
            else:
                ready_since = None

            if time.monotonic() >= deadline:
                return False

            time.sleep(interval)

    def navigate_and_wait(
        self,
        url,
        ready_selector="",
        ready_expr="",
        all_selectors=None,
        timeout=20.0,
        min_stable=0.5,
    ):
        """导航并等待就绪。整段过程持锁，避免并发请求互相抢标签页。

        返回 (ready, html)。ready 为 False 表示超时（HTML 仍会返回，
        调用方可以决定是否使用）。
        """
        with _NAVIGATE_LOCK:
            self.navigate(url)

            ready = self.wait_until_ready(
                target_url=url,
                ready_selector=ready_selector,
                ready_expr=ready_expr,
                all_selectors=all_selectors,
                timeout=timeout,
                min_stable=min_stable,
            )

            html = self.get_html()

            return ready, html

    # ---------- 快速取页（不导航）----------

    def current_host(self):
        try:
            return self.evaluate("location.host") or ""
        except Exception:
            return ""

    def fetch_document(self, url, timeout=45.0):
        """在**当前已加载的页面里**用 fetch() 取目标页面的 HTML。

        为什么不直接导航：
        整页导航要拆掉旧页面、重建 DOM、再加载图片和脚本，
        实测 1130ms 左右；而在常驻页里 fetch 一次只要约 540ms
        （**快 2 倍多**）。

        为什么结果是可信的：
        本站页面是服务端渲染的（Laravel Blade），HTML 里本来就有全部内容。
        逐项对比过 navigate / fetch / 普通HTTP 三种取法的解析结果：
        影片卡片数、播放地址、清晰度列表、互动状态完全一致。

        返回 (ok, html)。
        ok=False 时 `html` 里是原因（WRONG_ORIGIN / HTTP:xxx / CHALLENGE / ERR:...），
        调用方应该退回整页导航。
        """
        expression = """
        (async () => {
            // 必须同源才能 fetch，否则会被 CORS 拦掉
            if (location.host.indexOf('hanime1.me') === -1) {
                return 'WRONG_ORIGIN';
            }

            try {
                const r = await fetch(%s, {
                    credentials: 'same-origin',
                    redirect: 'follow',
                });

                if (!r.ok) return 'HTTP:' + r.status;

                const t = await r.text();

                // 万一拿到的是 Cloudflare 拦截页，交给调用方去导航
                if (t.indexOf('__cf_chl') !== -1 ||
                    t.indexOf('Just a moment') !== -1 ||
                    t.indexOf('Attention Required') !== -1) {
                    return 'CHALLENGE';
                }

                return t;
            } catch (e) {
                return 'ERR:' + e;
            }
        })()
        """ % json.dumps(url)

        try:
            value = self.evaluate(
                expression, timeout=timeout, await_promise=True
            ).get("value")
        except Exception as exc:
            return False, f"ERR:{exc}"

        if not isinstance(value, str):
            return False, "ERR:非字符串结果"

        for bad in ("WRONG_ORIGIN", "CHALLENGE"):
            if value == bad:
                return False, bad

        for prefix in ("HTTP:", "ERR:"):
            if value.startswith(prefix):
                return False, value

        # 太短肯定不是正常页面（首页也有 20 万字符）
        if len(value) < 2000:
            return False, f"ERR:内容过短({len(value)})"

        return True, value

    def ensure_site_loaded(self, timeout=30.0):
        """确保浏览器停在本站（快速 fetch 需要同源）。

        只在不满足时导航一次，之后就一直复用这个页面。
        """
        if "hanime1.me" in self.current_host():
            return True

        ready, _ = self.navigate_and_wait(
            "https://hanime1.me/",
            timeout=timeout,
            min_stable=0.3,
        )

        return ready
