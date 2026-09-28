import time
import os
import sys
import threading
import json

from fastapi import FastAPI, HTTPException

from cache import (
    detail_cache,
    home_cache,
    playlist_cache,
    search_cache,
    tags_cache,
    user_cache,
)
from cdp.chrome import (
    ChromeCDP,
    _NAVIGATE_LOCK,
)
import cdp.chrome as cdp
from parser.hanime_parser import HanimeParser
from opencc import OpenCC

import auth


app = FastAPI(
    title="HanimeViewer API",
    version="1.0.0"
)


# ==========================================================
# 下载
# ==========================================================
#
# 官网的 mp4 地址是带签名的（?secure=...），直接用外部下载器会 403，
# 必须复用浏览器里那套 cookie 去取。所以这里由后端来下载。
#
# 为什么不用浏览器自己下载：CDP 的 Page.setDownloadBehavior 会把文件
# 丢到 Chrome 的下载目录，用户很难找到，也没法做进度。
# 自己用会话 cookie 拉流反而更可控。

_downloads = {}
_DOWNLOAD_LOCK = threading.Lock()


# ---------- 应用数据目录与设置 ----------
#
# 数据默认放在**程序根目录**下的 HanimeData 里：
#
#   <程序根目录>\HanimeData\              应用数据
#       settings.json                     设置
#       downloads.json                    下载记录
#       Downloads\                        默认下载目录（可在设置页改）
#
# 下载文件夹刻意**不直接放在程序根目录**，免得程序文件和下载文件混在一起。
#
# 但**装到系统里之后**（MSIX / Program Files）程序目录是只读的，
# 数据得换到用户的 LocalAppData 去 —— 见 _installed_root()。
# 想强制指定位置可以用环境变量 HANIME_DATA_DIR。

APP_NAME = "HanimeViewer"


def _packaged_exe():
    """是不是 MSIX / Store 装出来的（可执行文件在 WindowsApps 下面）。"""
    pathlib = __import__("pathlib")

    try:
        exe = str(pathlib.Path(sys.executable).resolve()).lower()
    except Exception:
        return False

    return "\\windowsapps\\" in exe


def _is_writable(path):
    """真往里写一个文件试试 —— 光看权限位不准。"""
    try:
        path.mkdir(parents=True, exist_ok=True)

        probe = path / ".write_probe"

        probe.write_text("x", encoding="utf-8")
        probe.unlink()

        return True
    except Exception:
        return False


def _installed_root():
    """装到系统里时数据放哪：%LOCALAPPDATA%\\HanimeViewer。"""
    pathlib = __import__("pathlib")

    base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")

    return pathlib.Path(base) / APP_NAME


def program_root():
    """程序根目录 —— 数据就存它下面。

    打包运行：可执行文件所在目录。
    源码运行：backend/main.py 的上一级（也就是项目根）。

    装到系统里（MSIX）则换成 %LOCALAPPDATA%\\HanimeViewer ——
    那种情况下程序目录是只读的，数据放进去写不了。
    """
    pathlib = __import__("pathlib")

    if getattr(sys, "frozen", False):
        base = pathlib.Path(sys.executable).resolve().parent
    else:
        base = pathlib.Path(__file__).resolve().parent.parent

    # 装到系统里（MSIX / Store）时程序目录是只读的，数据要放到用户的
    # LocalAppData 去。
    #
    # 这一步必须放在"往上找项目根"**之前**：万一安装路径的某一级上面
    # 碰巧有 .git 或者 backend + frontend，就会被认成项目根，
    # 数据又写回只读的安装目录里去了。
    #
    # 而且**不能只靠写测试**来判断：MSIX 有文件系统虚拟化，主进程往
    # 安装目录写会被重定向到包自己的私有目录，探针会"成功"；
    # 但后端的 exe 是**子进程**、没有包标识，同样的路径它会真的失败。
    # 所以 MSIX 直接看路径认，不猜。
    if _packaged_exe():
        return _installed_root()

    # 打包出来的 exe 常常躺在 build 输出目录里
    # （frontend\build\windows\x64\runner\Release\）。
    # 那个目录会被重新编译清掉 —— 数据放进去迟早丢，
    # 所以往上找到真正的项目根：认 .git，或者认 backend + frontend 同时在。
    for candidate in [base, *base.parents]:
        try:
            if (candidate / ".git").exists():
                return candidate

            if (candidate / "backend").is_dir() and (
                candidate / "frontend"
            ).is_dir():
                return candidate
        except Exception:
            continue

    # 没找到项目根 —— 说明是打包运行。这时看程序目录能不能写
    # （比如用户手动把便携版解压进了 Program Files）。
    if not _is_writable(base):
        return _installed_root()

    return base


def hanime_root():
    """应用数据目录。

    默认是 `<程序根目录>\\HanimeData`；
    环境变量 `HANIME_DATA_DIR` 可以**整个换掉**它
    （装出来的版本想跟便携版共用同一份数据时很有用）。
    """
    pathlib = __import__("pathlib")

    override = os.environ.get("HANIME_DATA_DIR", "").strip()

    if override:
        return pathlib.Path(override)

    return program_root() / "HanimeData"


def default_download_dir():
    """默认下载目录：<数据目录>\\Downloads"""
    return hanime_root() / "Downloads"


def _legacy_roots():
    """以前用过、需要搬家过来的位置。"""
    pathlib = __import__("pathlib")

    return [
        pathlib.Path(os.path.expanduser("~")) / "Downloads" / "Hanime",
    ]


def migrate_legacy_data():
    """把老位置的数据搬到新位置。

    只搬两个 JSON（设置和下载记录），**不动下载好的影片** ——
    记录里存的是绝对路径，老文件在原地照样能打开、能播放，
    没必要为此挪动几个 GB。
    """
    target = hanime_root()
    legacy_paths = _legacy_roots()

    for legacy in legacy_paths:
        if not legacy.is_dir() or legacy == target:
            continue

        try:
            target.mkdir(parents=True, exist_ok=True)

            moved = []

            for name in ("settings.json", "downloads.json"):
                source = legacy / name
                destination = target / name

                if source.is_file() and not destination.exists():
                    import shutil as _shutil

                    _shutil.copy2(source, destination)
                    moved.append(name)

            # 设置里的 download_dir 如果还指着老位置，就删掉它，
            # 让新默认值生效（用户要的就是"默认下载位置改到程序根目录下"）。
            # 只删"指向老默认位置"的那种；用户自己改过的路径保持不动。
            settings_file = target / "settings.json"

            if settings_file.is_file():
                data = json.loads(settings_file.read_text(encoding="utf-8"))

                configured = str(data.get("download_dir") or "")

                if configured:
                    import pathlib as _pathlib

                    try:
                        resolved = _pathlib.Path(configured).resolve()
                    except Exception:
                        resolved = None

                    if resolved is not None and any(
                        resolved == old.resolve()
                        or old.resolve() in resolved.parents
                        for old in legacy_paths
                    ):
                        data.pop("download_dir", None)

                        settings_file.write_text(
                            json.dumps(data, ensure_ascii=False, indent=2),
                            encoding="utf-8",
                        )

                        moved.append("(并把指向老位置的下载目录改回默认)")

            if moved:
                print(
                    f"[migrate] 已把 {legacy} 里的 "
                    f"{', '.join(moved)} 搬到 {target}"
                )
        except Exception as exc:
            print(f"[warn] 迁移老数据失败（不影响使用）: {exc}")


def _settings_path():
    return hanime_root() / "settings.json"


# 启动时就搬一次（必须在任何 load_settings() 之前）
migrate_legacy_data()


# 必须是 RLock：save_settings 会在持锁的情况下调用 load_settings，
# 用普通 Lock 会自己把自己锁死（写设置直接卡住不返回，踩过）。
_settings_lock = threading.RLock()
_settings_cache = None


def load_settings():
    """读设置（带内存缓存）。文件不存在就用默认值。"""
    global _settings_cache

    with _settings_lock:
        if _settings_cache is not None:
            return _settings_cache

        data = {}

        try:
            path = _settings_path()

            if path.is_file():
                data = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"[warn] 读取设置失败，改用默认值: {exc}")

        if not isinstance(data, dict):
            data = {}

        merged = {
            "download_dir": str(default_download_dir()),
        }

        merged.update(
            {k: v for k, v in data.items() if k in merged}
        )

        _settings_cache = merged

        return merged


def save_settings(patch):
    """合并写入设置。"""
    global _settings_cache

    with _settings_lock:
        current = dict(load_settings())
        current.update(
            {k: v for k, v in (patch or {}).items() if k in current}
        )

        try:
            path = _settings_path()
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                json.dumps(current, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except Exception as exc:
            print(f"[warn] 写设置失败: {exc}")

        _settings_cache = current

        return current


def downloads_dir():
    """实际使用的下载目录（设置里改过就用改过的）。"""
    configured = str(load_settings().get("download_dir") or "").strip()

    if configured:
        return __import__("pathlib").Path(configured)

    return default_download_dir()


# ---------- 下载记录（落盘，重启不丢） ----------

def _records_path():
    return hanime_root() / "downloads.json"

    # 说明：记录跟着「根目录」走，不跟着下载目录走 ——
    # 用户改下载目录时不该把历史记录一起丢掉。


def _load_records():
    try:
        path = _records_path()

        if path.is_file():
            data = json.loads(path.read_text(encoding="utf-8"))

            if isinstance(data, list):
                return {
                    str(r.get("video_id")): r
                    for r in data
                    if isinstance(r, dict) and r.get("video_id")
                }
    except Exception as exc:
        print(f"[warn] 读下载记录失败: {exc}")

    return {}


def _write_records(records):
    try:
        path = _records_path()
        path.parent.mkdir(parents=True, exist_ok=True)

        path.write_text(
            json.dumps(list(records.values()), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    except Exception as exc:
        print(f"[warn] 写下载记录失败: {exc}")


def _save_records():
    """把当前所有任务合并进记录文件。

    存的时候去掉 `url` —— 官网的视频地址带签名会过期，
    留着只会让下次重启后拿着一个失效链接去重试。
    """
    records = _load_records()

    with _DOWNLOAD_LOCK:
        for video_id, job in _downloads.items():
            records[video_id] = {
                k: v for k, v in job.items() if k != "url"
            }

    _write_records(records)


def _safe_filename(name, fallback="video"):
    """把标题变成合法文件名。

    Windows 不允许 \\ / : * ? " < > | 这些字符。
    另外详情页的 title 会带着站点后缀，比如
    「XXX - H動漫/裏番/線上看 - Hanime1.me」，要一起剪掉。
    """
    text = str(name)

    # 先把各种「看不见的空格」统一成普通空格。
    #
    # 官网标题用的其实是**不换行空格** \xa0：
    #   '...[中文字幕]\xa0-\xa0H動漫/裏番/線上看\xa0-\xa0Hanime1.me'
    # 以前直接按普通空格找 " - H動漫"，永远找不到，
    # 结果站点后缀原封不动留在了文件名里（下出来一个几十字的长名字）。
    for space in ("\u00a0", "\u3000", "\u2007", "\u202f", "\u2009"):
        text = text.replace(space, " ")

    # 剪掉站点后缀
    for sep in (" - H動漫", " - H动漫", " | Hanime1", " - Hanime1"):
        idx = text.find(sep)

        if idx != -1:
            text = text[:idx]

    # 兜底：万一还有 Hanime1 字样，从那里截断
    for tail in ("Hanime1.me", "Hanime1"):
        idx = text.find(tail)

        if idx != -1:
            text = text[:idx].rstrip(" -|")

    cleaned = "".join(
        ("_" if c in '\\/:*?"<>|' else c) for c in text
    )

    cleaned = " ".join(cleaned.split()).strip(" .")

    if not cleaned:
        cleaned = fallback

    # 留点余量给扩展名和可能的同名后缀
    return cleaned[:110]


def _browser_cookies():
    """取调试浏览器里 hanime1.me 的 cookie，拼成 Cookie 头。"""
    chrome = ChromeCDP()

    raw = chrome.evaluate(
        "(()=>{try{return document.cookie||'';}catch(e){return '';}})()"
    ).get("value") or ""

    return raw


def _download_worker(video_id):
    """后台下载线程。"""
    import urllib.request as _url
    import urllib.error as _urlerr

    with _DOWNLOAD_LOCK:
        job = _downloads.get(video_id)

    if not job:
        return

    url = job["url"]
    title = job["title"]

    try:
        target_dir = downloads_dir()
        target_dir.mkdir(parents=True, exist_ok=True)

        # 扩展名从 URL 推断，默认 mp4
        ext = ".mp4"

        low = url.split("?")[0].lower()

        for cand in (".mp4", ".mkv", ".webm", ".m3u8", ".ts"):
            if low.endswith(cand):
                ext = cand
                break

        base = _safe_filename(title, fallback=video_id)

        path = target_dir / f"{base}{ext}"

        # 重名就加序号，避免覆盖
        counter = 1

        while path.exists():
            path = target_dir / f"{base} ({counter}){ext}"
            counter += 1

        cookie = _browser_cookies()

        headers = {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/154.0.0.0 Safari/537.36"
            ),
            "Referer": "https://hanime1.me/",
        }

        if cookie:
            headers["Cookie"] = cookie

        request = _url.Request(url, headers=headers)

        with _url.urlopen(request, timeout=60) as response:
            total = int(response.headers.get("Content-Length") or 0)

            with _DOWNLOAD_LOCK:
                job["total"] = total
                job["path"] = str(path)

            received = 0
            chunk = 1024 * 256

            with open(path, "wb") as handle:
                while True:
                    with _DOWNLOAD_LOCK:
                        if job["status"] == "cancelled":
                            handle.close()

                            try:
                                path.unlink()
                            except Exception:
                                pass

                            return

                    block = response.read(chunk)

                    if not block:
                        break

                    handle.write(block)
                    received += len(block)

                    with _DOWNLOAD_LOCK:
                        job["received"] = received
                        job["percent"] = (
                            round(received * 100.0 / total, 1)
                            if total
                            else 0.0
                        )

        with _DOWNLOAD_LOCK:
            job["status"] = "done"
            job["percent"] = 100.0 if total else job["percent"]
            job["path"] = str(path)

        _save_records()

    except _urlerr.HTTPError as exc:
        with _DOWNLOAD_LOCK:
            job["status"] = "failed"
            job["error"] = (
                f"服务器返回 {exc.code}"
                + ("（登录状态可能已失效）" if exc.code in (401, 403) else "")
            )

        _save_records()

    except Exception as exc:
        with _DOWNLOAD_LOCK:
            job["status"] = "failed"
            job["error"] = str(exc)

        _save_records()


# ==========================================================
# 统一的「取页面 + 解析」入口
# ==========================================================
#
# 旧的写法在每个接口里重复这一套：
#
#     chrome = ChromeCDP()
#     chrome.navigate(url)
#     time.sleep(5)
#     html = chrome.get_html()
#     parser = HanimeParser(html)
#
# 有两个问题：
#
# 1. 每次固定等 5 秒。实测首页要 5.1 秒才加载完，也就是说固定 5 秒
#    有时候是「提前」取到半成品；而搜索页只要 3.2 秒，又白等了 2 秒。
#    现在改成轮询等待真正的目标元素出现。
#
# 2. 完全没有缓存。同一个页面来回切换就反复重新加载。
#    现在按 URL 缓存解析结果，短时间内的重复请求立即返回。
#
# 另外：整个「导航 -> 等就绪 -> 取 HTML -> 解析」都持有 _NAVIGATE_LOCK。
# 因为所有请求共用同一个 Chrome 标签页，如果解析期间别的请求把页面导航走了，
# 就会解析到错误的页面内容。

# 列表类页面（首页 / 搜索 / 筛选 / 播放清单）都有的元素
LIST_READY_SELECTOR = "a.video-link"

# 视频详情页需要的**全部**元素。
#
# 为什么不是只等一个：#video-artist-name 会比 <video>、简介面板和
# 相关影片区更早出现，只等它就可能在页面画了一半时取走 HTML，
# 结果 sources / related 全是空 —— 这正是之前
# 「有些视频进详情页后底下没有相关影片」的原因。
DETAIL_READY_SELECTORS = [
    "#video-artist-name",
    "video",
    ".video-description-panel",
    "#related-tabcontent",
]

# 兼容旧写法
DETAIL_READY_SELECTOR = DETAIL_READY_SELECTORS[0]


def fetch_html(
    url,
    ready_selector="",
    all_selectors=None,
    cache=None,
    timeout=20.0,
    min_stable=0.5,
):
    """取指定 URL 的 HTML。命中缓存时直接返回，不再访问 Chrome。

    取页分两级，先快后稳：

    1. **快速通道**：在常驻页里 `fetch()` 拿 HTML，**不做整页导航**。
       整页导航要拆旧页面 + 重建 DOM + 加载图片脚本，实测约 1130ms；
       在已加载的页里 fetch 一次只要约 540ms（快 2 倍多）。
       本站页面是服务端渲染的，HTML 里本来就有全部内容 ——
       逐项对比过 navigage / fetch / 普通 HTTP 三种取法，
       卡片数、播放地址、清晰度列表、互动状态完全一致。

    2. **兜底**：快速通道失败（浏览器不在本站、拿到 Cloudflare 拦截页、
       非 200）就退回整页导航，保证不会因为提速而拿不到数据。

    返回 (html, from_cache)。
    """
    if cache is not None:
        cached = cache.get(url)

        if cached is not None:
            return cached, True

    with _NAVIGATE_LOCK:
        chrome = ChromeCDP()

        html = ""
        via = ""

        try:
            ok, fast_html = chrome.fetch_document(url, timeout=timeout)

            if ok:
                html = fast_html
                via = "fetch"
            else:
                print(f"[info] 快速通道不可用（{fast_html}），改用整页导航: {url}")

                # 浏览器不在本站时先回一次首页（就这一次，之后一直复用）
                if fast_html == "WRONG_ORIGIN":
                    chrome.ensure_site_loaded(timeout=timeout)

                    ok, fast_html = chrome.fetch_document(url, timeout=timeout)

                    if ok:
                        html = fast_html
                        via = "fetch"
        except Exception as exc:
            print(f"[info] 快速通道异常（{exc}），改用整页导航: {url}")

        if not html:
            ready, nav_html = chrome.navigate_and_wait(
                url,
                ready_selector=ready_selector,
                all_selectors=all_selectors,
                timeout=timeout,
                min_stable=min_stable,
            )

            if not ready:
                print(f"[warn] 等待页面就绪超时: {url}")

            html = nav_html or ""
            via = "navigate"

        if not html:
            raise Exception(f"获取 HTML 失败: {url}")

        print(f"[fetch] {via}: {url}")

    if cache is not None:
        cache.set(url, html)

    return html, False


def parse_page(
    url,
    ready_selector="",
    all_selectors=None,
    cache=None,
    timeout=20.0,
    min_stable=0.5,
):
    """取页面并返回 (HanimeParser, from_cache)。"""
    html, from_cache = fetch_html(
        url,
        ready_selector=ready_selector,
        all_selectors=all_selectors,
        cache=cache,
        timeout=timeout,
        min_stable=min_stable,
    )

    return HanimeParser(html), from_cache


@app.get("/")
def root():
    return {
        "message": "HanimeViewer API is running"
    }


@app.post("/api/shutdown")
def shutdown(exit_process: bool = True):
    """App 退出时收尾。

    必须收掉两样东西：
    1. **隐藏的调试浏览器** —— 它的窗口是隐藏的，用户看不到也就没法自己关，
       留着就是一堆白占内存的 chrome.exe（实测会留 13 个）
    2. 后端自己（由调用方决定是否顺带结束）

    这个接口故意放在 main.py 而不是打包入口 run_backend.py：
    放在入口文件里的话，用 `uvicorn main:app` 直接跑后端时就没有这个路由，
    App 的退出清理会静默失败（踩过这个坑）。
    """
    import browser as browser_module

    def _cleanup():
        try:
            # 会轮询等浏览器真的退干净
            browser_module.stop_browser(cdp.CDP_PORT, timeout=15.0)
        except Exception:
            pass

        if exit_process:
            os._exit(0)

    threading.Thread(target=_cleanup, daemon=True).start()

    return {"ok": True}


@app.get("/api/settings")
def get_settings():
    """应用设置（目前只有下载目录是可改的后端设置）。"""
    current = load_settings()

    return {
        "download_dir": str(downloads_dir()),
        "default_download_dir": str(default_download_dir()),
        "hanime_root": str(hanime_root()),
    }


@app.post("/api/settings")
def update_settings(payload: dict = None):
    """改设置。目前只接受 download_dir。"""
    body = payload or {}

    patch = {}

    if "download_dir" in body:
        target = str(body.get("download_dir") or "").strip()

        if not target:
            raise HTTPException(status_code=400, detail="下载目录不能为空")

        # 目录不存在就建出来，免得用户填了却下不进去
        try:
            import pathlib as _pathlib

            _pathlib.Path(target).mkdir(parents=True, exist_ok=True)
        except Exception as exc:
            raise HTTPException(
                status_code=400,
                detail=f"这个目录建不出来：{exc}",
            )

        patch["download_dir"] = target

    current = save_settings(patch)

    return {
        "ok": True,
        "download_dir": str(downloads_dir()),
        "settings": current,
    }


@app.get("/api/download/dir")
def download_dir():
    """下载目录（客户端「打开文件夹」会用到）。"""
    return {
        "dir": str(downloads_dir()),
        "exists": downloads_dir().is_dir(),
        "default_dir": str(default_download_dir()),
    }


@app.post("/api/download/{video_id}")
def start_download(video_id: str, payload: dict = None):
    """把影片下载到本地。

    用浏览器里那套 cookie 去取视频流 —— 官网的 mp4 地址带签名，
    直接下载会 403，必须复用已登录的会话。

    请求体（可选）：
      {"quality": "1080p"}   不填就选最高画质
    """
    payload = payload or {}

    want_quality = str(payload.get("quality", "")).strip()

    with _DOWNLOAD_LOCK:
        if video_id in _downloads:
            job = _downloads[video_id]

            if job["status"] == "downloading":
                return {"ok": True, "job": job, "message": "这个影片正在下载中"}

    try:
        detail = _build_detail(video_id)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"读取影片信息失败：{exc}")

    sources = detail.get("sources") or []

    if not sources:
        raise HTTPException(
            status_code=400,
            detail="这个影片没有可直接下载的地址（可能是外部嵌入播放器）",
        )

    picked = None

    if want_quality:
        picked = next(
            (s for s in sources if str(s.get("quality")) == want_quality),
            None,
        )

    if picked is None:
        # sources 已按画质从高到低排好
        picked = sources[0]

    url = picked.get("url") or ""

    if not url:
        raise HTTPException(status_code=400, detail="下载地址为空")

    title = detail.get("title") or video_id

    job = {
        "video_id": video_id,
        "title": title,
        "quality": picked.get("quality") or "",
        "url": url,
        "status": "downloading",
        "received": 0,
        "total": 0,
        "percent": 0.0,
        "path": "",
        "error": "",
        "thumbnail": detail.get("thumbnail") or "",
        "started_at": time.time(),
    }

    with _DOWNLOAD_LOCK:
        _downloads[video_id] = job

    _save_records()

    threading.Thread(
        target=_download_worker,
        args=(video_id,),
        daemon=True,
    ).start()

    return {"ok": True, "job": job}


@app.get("/api/download/{video_id}")
def download_status(video_id: str):
    with _DOWNLOAD_LOCK:
        job = _downloads.get(video_id)

    if not job:
        return {"found": False}

    return {"found": True, "job": job}


@app.get("/api/downloads")
def list_downloads():
    """下载记录 = 正在跑的任务 + 以前存下来的历史。

    以前只返回内存里的任务，后端一重启记录就全没了，
    下载管理页也就没东西可看。现在落盘到
    `<Hanime 根目录>/downloads.json`，重启后还在。
    """
    with _DOWNLOAD_LOCK:
        jobs = {vid: dict(job) for vid, job in _downloads.items()}

    for vid, record in _load_records().items():
        if vid in jobs:
            continue

        item = dict(record)

        # 上次没下完、进程就没了 —— 线程早不存在了，标成「已中断」
        if item.get("status") == "downloading":
            item["status"] = "interrupted"

        jobs[vid] = item

    for job in jobs.values():
        path = job.get("path") or ""

        job["file_exists"] = bool(path) and os.path.isfile(path)

        # 本地找不到文件的任务，别让它一直显示"已完成"
        if job.get("status") == "done" and not job["file_exists"]:
            job["status"] = "missing"

    ordered = sorted(
        jobs.values(),
        key=lambda j: j.get("started_at", 0),
        reverse=True,
    )

    return {"dir": str(downloads_dir()), "jobs": ordered}


@app.post("/api/downloads/{video_id}/remove")
def remove_download(video_id: str, payload: dict = None):
    """删掉一条下载记录；delete_file 为真时连硬盘上的文件一起删。"""
    body = payload or {}
    delete_file = bool(body.get("delete_file"))

    with _DOWNLOAD_LOCK:
        job = _downloads.pop(video_id, None)

    records = _load_records()
    record = records.pop(video_id, None)

    _write_records(records)

    target = (job or record or {}).get("path") or ""
    removed_file = False

    if delete_file and target and os.path.isfile(target):
        try:
            os.remove(target)
            removed_file = True
        except Exception as exc:
            raise HTTPException(
                status_code=500, detail=f"删文件失败：{exc}"
            )

    if not job and not record:
        raise HTTPException(status_code=404, detail="没有这条下载记录")

    return {"ok": True, "removed_file": removed_file, "path": target}


@app.post("/api/download/{video_id}/cancel")
def cancel_download(video_id: str):
    with _DOWNLOAD_LOCK:
        job = _downloads.get(video_id)

        if not job:
            raise HTTPException(status_code=404, detail="没有这个下载任务")

        job["status"] = "cancelled"

    _save_records()

    return {"ok": True}


@app.get("/api/status")
def system_status():
    """给客户端的启动自检用。

    客户端启动时会轮询这个接口，确认「后端 + 调试浏览器」都就绪了
    再进入主界面，避免一开始就报一堆网络错误。
    """
    import browser as browser_module

    browser_path = browser_module.find_browser()
    cdp_alive = browser_module.is_cdp_alive(cdp.CDP_PORT)

    page_count = 0
    current_url = ""

    if cdp_alive:
        try:
            pages = cdp.list_page_targets(timeout=2)

            page_count = len(pages)

            for target in pages:
                url = target.get("url", "")

                if url.startswith("http"):
                    current_url = url
                    break
        except Exception:
            pass

    return {
        "backend": True,
        "cdp_port": cdp.CDP_PORT,
        "cdp_alive": cdp_alive,
        "page_count": page_count,
        "current_url": current_url,
        "browser_found": bool(browser_path),
        "browser_path": browser_path or "",
        "ready": bool(cdp_alive and page_count > 0),
    }


@app.post("/api/browser/start")
def start_browser():
    """手动确保调试浏览器已启动（客户端启动自检失败时可以重试）。"""
    import browser as browser_module

    ok, message, path = browser_module.ensure_browser(
        port=cdp.CDP_PORT
    )

    return {
        "ok": ok,
        "message": message,
        "browser_path": path,
    }


@app.get("/api/cache_stats")
def cache_stats():
    """查看缓存命中情况，方便确认缓存是否真的在起作用。"""
    return {
        "home": home_cache.stats(),
        "search": search_cache.stats(),
        "detail": detail_cache.stats(),
        "tags": tags_cache.stats(),
        "playlist": playlist_cache.stats(),
    }


@app.get("/api/cache_clear")
def cache_clear():
    """手动清空全部缓存（调试用）。"""
    home_cache.clear()
    search_cache.clear()
    detail_cache.clear()
    tags_cache.clear()
    playlist_cache.clear()

    return {"message": "缓存已清空"}


@app.get("/api/home")
def home_videos():
    url = "https://hanime1.me/"

    try:
        print("准备打开首页:")
        print(url)

        parser, from_cache = parse_page(
            url,
            ready_selector=LIST_READY_SELECTOR,
            cache=home_cache,
        )

        print("命中缓存:" if from_cache else "已重新加载页面")

        cards = parser.get_video_cards()

        # 只保留 Hanime 自己的视频页面，过滤广告
        real_cards = [
            card
            for card in cards
            if card.url.startswith("https://hanime1.me/watch?")
        ]

        print("解析到的视频卡片数量:")
        print(len(cards))

        print("过滤广告后的视频数量:")
        print(len(real_cards))

        results = []

        for card in real_cards:
            results.append({
                "title": card.title,
                "url": card.url,
                "thumbnail": card.thumbnail,
                "duration": card.duration,
                "rating": card.rating,
                "views": card.views
            })

        return {
            "results": results
        }

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.get("/api/home_sections")
def home_sections():
    url = "https://hanime1.me/"

    try:
        print("准备打开首页（栏目模式）:")
        print(url)

        parser, from_cache = parse_page(
            url,
            ready_selector=LIST_READY_SELECTOR,
            cache=home_cache,
        )

        print("命中缓存:" if from_cache else "已重新加载页面")

        sections = parser.get_home_sections()

        print("栏目数量:")
        print(len(sections))

        for section in sections:
            print(
                f"  {section['name']}: "
                f"{len(section['videos'])} 个视频"
            )

        result = []

        for section in sections:
            result.append({
                "name": section["name"],
                "url": section.get("url", ""),
                "videos": [
                    {
                        "title": v.title,
                        "url": v.url,
                        "thumbnail": v.thumbnail,
                        "duration": v.duration,
                        "rating": v.rating,
                        "views": v.views
                    }
                    for v in section["videos"]
                ]
            })

        return {"sections": result}

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.get("/api/tags")
def get_tags():
    url = "https://hanime1.me/search?genre=%E8%A3%8F%E7%95%AA"

    try:
        print("准备打开标签页面:")
        print(url)

        parser, from_cache = parse_page(
            url,
            ready_selector=LIST_READY_SELECTOR,
            cache=tags_cache,
        )

        print("命中缓存:" if from_cache else "已重新加载页面")

        groups = parser.get_tag_groups()

        print("标签分组数量:")
        print(len(groups))

        for g in groups:
            print(f"  {g['name']}: {len(g['tags'])} 个标签")

        return {"groups": groups}

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.get("/api/filter")
def filter_videos(
    query: str = "",
    genre: str = "",
    sort: str = "",
    date: str = "",
    duration: str = "",
    page: int = 1,
    tags: str = "",
    broad: str = ""
):
    try:
        if page < 1:
            page = 1

        from urllib.parse import urlencode

        tag_list = [
            t for t in tags.split("|")
            if t.strip()
        ]

        params = [
            ("query", query),
            ("type", ""),
            ("genre", genre),
        ]

        if broad == "on" and tag_list:
            params.append(("broad", "on"))

        for tag in tag_list:
            params.append(("tags[]", tag))

        params.extend([
            ("sort", sort),
            ("date", date),
            ("duration", duration),
        ])

        if page > 1:
            params.append(("page", str(page)))

        query_string = urlencode(params)

        url = f"https://hanime1.me/search?{query_string}"

        print("准备打开筛选页面:")
        print(url)

        parser, from_cache = parse_page(
            url,
            ready_selector=LIST_READY_SELECTOR,
            cache=search_cache,
        )

        print("命中缓存:" if from_cache else "已重新加载页面")

        cards = parser.get_search_results()

        total_pages = parser.get_search_total_pages()

        # 标签列表就在同一个页面里（<div id="tags"> 模态框），
        # 顺手解析出来一起返回，客户端就不用再单独请求 /api/tags 了。
        # 这省掉了一整次「导航 -> 等就绪 -> 取 HTML」，是标签弹窗变快的关键。
        tag_groups = parser.get_tag_groups()

        print("解析到的视频数量:")
        print(len(cards))

        print("总页数:")
        print(total_pages)

        print("标签分组数量:")
        print(len(tag_groups))

        results = []

        for card in cards:
            results.append({
                "title": card.title,
                "url": card.url,
                "thumbnail": card.thumbnail,
                "duration": card.duration,
                "rating": card.rating,
                "views": card.views
            })

        # 封面真实比例（有些栏目是竖版，有些是横版）。
        # 客户端据此决定卡片画成竖的还是横的 —— 实测
        # 「新番預告」的封面是 268x394 竖版，按 16:9 画会裁掉一大半。
        try:
            results = _attach_thumbnail_sizes(results, limit=24)
        except Exception:
            pass

        return {
            "query": query,
            "genre": genre,
            "sort": sort,
            "date": date,
            "duration": duration,
            "tags": tag_list,
            "broad": broad,
            "page": page,
            "total_pages": total_pages,
            "results": results,
            "tag_groups": tag_groups
        }

    except HTTPException:
        raise

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.get("/api/search")
def search_videos(query: str):
    url = f"https://hanime1.me/search?query={query}"

    try:
        print("准备打开搜索页面:")
        print(url)

        parser, from_cache = parse_page(
            url,
            ready_selector=LIST_READY_SELECTOR,
            cache=search_cache,
        )

        print("命中缓存:" if from_cache else "已重新加载页面")

        cards = parser.get_video_cards()

        # 只保留 Hanime 自己的视频页面，过滤广告
        real_cards = [
            card
            for card in cards
            if card.url.startswith("https://hanime1.me/watch?")
        ]

        print("解析到的视频卡片数量:")
        print(len(cards))

        print("过滤广告后的视频数量:")
        print(len(real_cards))

        results = []

        for card in real_cards:
            results.append({
                "title": card.title,
                "url": card.url,
                "thumbnail": card.thumbnail,
                "duration": card.duration,
                "rating": card.rating,
                "views": card.views
            })

        return {
            "query": query,
            "results": results
        }

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


# ==========================================================
# 封面尺寸缓存
# ==========================================================
#
# 详情页 / 筛选页要按封面真实比例渲染（竖版 0.68、横版 16:9），
# 而图片带签名、外部拿不到尺寸，只能在浏览器里加载量一遍。
#
# 之前每次冷加载都要**串行**量 59 张，多花约 2 秒，这就是
# 「详情页加载慢」的主因。两个优化：
#   1. 并行量（Promise.all），59 张一起加载，比串行快很多。
#   2. 按 URL 路径缓存尺寸（同一个封面换签名也不影响），
#      下次直接命中，完全不再量。
_thumb_size_cache = {}
_THUMB_CACHE_LOCK = threading.Lock()


def _thumb_cache_key(url):
    # 去掉 ?secure=... 签名：同一张图尺寸不会变，换签名不该失效
    return url.split("?", 1)[0]


def _thumb_orientation(ratio):
    if ratio > 1.15:
        return "landscape"

    if ratio < 0.87:
        return "portrait"

    return "square"


def _attach_thumbnail_sizes(related, limit=60):
    """给影片列表补上封面的真实宽高（带缓存 + 并行）。"""
    if not related:
        return related

    uncached_urls = []
    uncached_indices = []

    for index, item in enumerate(related[:limit]):
        url = item.get("thumbnail") or ""

        if not url:
            continue

        key = _thumb_cache_key(url)

        with _THUMB_CACHE_LOCK:
            cached = _thumb_size_cache.get(key)

        if cached:
            width, height = cached

            item["thumb_width"] = width
            item["thumb_height"] = height
            item["thumb_ratio"] = round(width / height, 4)
            item["thumb_orientation"] = _thumb_orientation(width / height)
            continue

        uncached_urls.append(url)
        uncached_indices.append(index)

    if not uncached_urls:
        return related

    chrome = ChromeCDP()

    # 并行量：Promise.all 让浏览器同时加载所有图
    probe = (
        """(async () => {
            const urls = %s;
            const out = await Promise.all(urls.map(u => new Promise(res => {
                if (!u) { res(null); return; }
                const im = new Image();
                im.onload = () => res([im.naturalWidth, im.naturalHeight]);
                im.onerror = () => res(null);
                im.src = u;
            })));
            return JSON.stringify(out);
        })()"""
    ) % json.dumps(uncached_urls)

    raw = chrome.evaluate(probe, timeout=90, await_promise=True).get("value")

    if not raw:
        return related

    sizes = json.loads(raw)

    for local_index, related_index in enumerate(uncached_indices):
        size = sizes[local_index] if local_index < len(sizes) else None

        if not size or not size[0] or not size[1]:
            continue

        width, height = int(size[0]), int(size[1])
        item = related[related_index]

        item["thumb_width"] = width
        item["thumb_height"] = height
        item["thumb_ratio"] = round(width / height, 4)
        item["thumb_orientation"] = _thumb_orientation(width / height)

        with _THUMB_CACHE_LOCK:
            _thumb_size_cache[_thumb_cache_key(uncached_urls[local_index])] = (
                width,
                height,
            )

            # 防止缓存无限膨胀
            if len(_thumb_size_cache) > 20000:
                _thumb_size_cache.clear()

    return related


@app.get("/api/video/{video_id}")
def get_video(video_id: str):
    return _build_detail(video_id)


def _build_detail(video_id: str):
    """读取影片详情（抽出来给下载等多处复用）。"""
    url = f"https://hanime1.me/watch?v={video_id}"

    try:
        print("准备打开:")
        print(url)

        # 详情页里的视频直链带 secure 签名，TTL 较短，避免拿到过期地址
        parser, from_cache = parse_page(
            url,
            all_selectors=DETAIL_READY_SELECTORS,
            cache=detail_cache,
        )

        print("命中缓存:" if from_cache else "已重新加载页面")

        detail = parser.get_video_detail()

        playlist_videos = parser.get_playlist_videos()

        related = parser.get_related_videos()

        # 互动状态（已点赞/已储存）直接读详情页 HTML，不用额外导航。
        # 之前靠 /api/video/{id}/state 单独取，会多一次浏览器导航。
        interaction = parser.get_interaction_state()

        # 相关影片的封面**是竖版**（实测 268x394，比例 0.68），
        # 而之前客户端按 16:9 横版渲染，等于把竖图裁掉一大半。
        #
        # 图片真实尺寸只有浏览器知道（带签名的 URL 在别处取不到），
        # 所以在页面里加载量一遍。量完写进缓存，后续不再付这个代价。
        try:
            related = _attach_thumbnail_sizes(related)
        except Exception:
            pass

        return {
            "video_id": video_id,
            "title": detail.title,
            "url": detail.url,
            "video_source": detail.video_source,
            "thumbnail": detail.thumbnail,
            "brand": detail.brand,
            "brand_url": detail.brand_url,
            # 播放器下方头像所属的「品牌/制作商」主页
            "artist_id": detail.artist_id,
            "artist_url": detail.artist_url,
            "artist_avatar": detail.artist_avatar,
            # 真正的上传者（可能与品牌不是同一个人）
            "uploader": detail.uploader,
            "uploader_id": detail.uploader_id,
            "uploader_url": detail.uploader_url,
            "uploader_avatar": detail.uploader_avatar,
            "like_ratio": detail.like_ratio,
            "like_count": detail.like_count,
            "unlike_count": detail.unlike_count,
            "views": detail.views,
            "release_date": detail.release_date,
            "file_size": detail.file_size,
            "tags": detail.tags,
            "playlist": playlist_videos,
            "sources": detail.sources,
            "related": related,
            # 当前账号的互动状态（点亮图标用）
            "liked": interaction.get("liked", False),
            "disliked": interaction.get("disliked", False),
            "saved": interaction.get("saved", False),
            "saved_playlist": interaction.get("saved_playlist", ""),
            # 储存弹窗的可选清单（页面 HTML 里就有，客户端不必再等一次导航）
            "save_playlists": interaction.get("save_playlists", []),
            # 官方的下載按钮指向这个页面（客户端也可以直接用 video_source）
            "download_url": (
                f"https://hanime1.me/download?v={video_id}"
            )
        }

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.get("/api/account")
def account_info(force: bool = False):
    """当前登录状态。force=true 时忽略缓存重新检测。"""
    try:
        return auth.get_account(force=force)

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.post("/api/login")
def login(payload: dict):
    """在真实 Chrome 里登录 Hanime。

    请求体：{"email": "...", "password": "..."}

    密码只用于这一次提交，不会写进任何文件。
    """
    email = (payload or {}).get("email", "").strip()
    password = (payload or {}).get("password", "")

    try:
        ok, account, error = auth.login(email, password)

        if not ok:
            raise HTTPException(
                status_code=401,
                detail=error or "登录失败"
            )

        return {
            "ok": True,
            "account": account
        }

    except HTTPException:
        raise

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.post("/api/logout")
def logout():
    try:
        auth.logout()

        return {"ok": True}

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.get("/api/user/{user_id}")
def user_profile(user_id: str, tab: str = "home", page: int = 1):
    """用户/发行商主页。

    tab:
      home      - 个人中心首页（栏目段总览，见 /api/user/{id}/home）
      histories - 觀看紀錄
      saves     - 稍後觀看
      likes     - 讚好的影片
      playlists - 播放清單
      uploaded  - 上傳的影片

    这些页面都是服务端渲染的，直接从同一个浏览器会话里读，
    所以登录之后才能看到的内容也能正常拿到。

    列表类 tab 每页 60 条，用 page 翻页。
    """
    if not user_id:
        raise HTTPException(status_code=400, detail="user_id 不能为空")

    if page < 1:
        page = 1

    base = f"https://hanime1.me/user/{user_id}"

    if tab == "home" or not tab:
        url = base
    else:
        url = f"{base}/{tab}"

        if page > 1:
            url = f"{url}?page={page}"

    try:
        parser, from_cache = parse_page(
            url,
            ready_selector="a.video-link",
            cache=user_cache,
        )

        print("命中缓存:" if from_cache else "已重新加载页面")

        # tab 页上除了真正的内容，还带着个人中心首页那 4 个栏目段的预览卡片，
        # 所以必须限定在 .specific-tab-view 里解析并去重，
        # 直接全页抓会把预览段和分页重复的卡片一起算进来。
        if tab == "playlists":
            playlists = parser.get_tab_playlists()
            videos = []
        else:
            videos = parser.get_tab_videos()
            playlists = []

        print("影片数量:")
        print(len(videos))

        print("播放清单数量:")
        print(len(playlists))

        # 页面标题形如
        # 「ピンクパイナップル的首頁\xa0-\xa0H動漫/裏番/線上看\xa0-\xa0Hanime1.me」
        # 注意分隔符是 \xa0-（不换行空格），不是普通的 " - "
        title = parser.get_title() or ""
        normalized = title.replace("\xa0", " ")
        name = normalized.split(" - ", 1)[0] if " - " in normalized else normalized

        for suffix in ("的首頁", "的影片", "的播放清單", "的首页"):
            if name.endswith(suffix):
                name = name[: -len(suffix)]
                break

        avatar = parser.get_user_avatar()

        return {
            "user_id": user_id,
            "tab": tab,
            "page": page,
            "total_pages": parser.get_total_pages(),
            "url": url,
            "name": name.strip(),
            "avatar": avatar,
            # get_tab_videos / get_tab_playlists 返回的就是 dict，
            # 不用再逐字段转换
            "videos": videos,
            "playlists": playlists
        }

    except HTTPException:
        raise

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.post("/api/playlist/create")
def create_playlist(payload: dict):
    """新建播放清单（储存弹窗顶部的「新增播放清单」）。

    请求体：
      {"title": "标题（必填）",
       "description": "详细说明（选填）",
       "video_id": "408116"}
    """
    body = payload or {}

    title = (body.get("title") or "").strip()
    description = (body.get("description") or "").strip()
    video_id = (body.get("video_id") or "").strip()

    if not title:
        raise HTTPException(status_code=400, detail="标题不能为空")

    if not video_id:
        raise HTTPException(status_code=400, detail="缺少 video_id")

    try:
        ok, message, state = auth.create_playlist(
            video_id, title, description
        )

        if not ok:
            raise HTTPException(status_code=400, detail=message)

        # 清单列表与用户主页缓存都作废
        playlist_cache.clear()
        user_cache.clear()
        detail_cache.clear()

        return {"ok": True, "message": message, "state": state}

    except HTTPException:
        raise

    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/api/video/{video_id}/state")
def video_state(video_id: str):
    """当前账号对这个影片的状态（是否已点赞 / 已储存）。

    客户端用它点亮图标 —— 点赞或储存之后只刷新这个状态，
    不重新加载整个影片详情页。
    """
    try:
        return auth.fetch_video_state(video_id)

    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/api/video/{video_id}/playlists")
def video_save_playlists(video_id: str):
    """「储存」时可选的播放清单（供客户端弹选择框）。"""
    try:
        items = auth.fetch_playlists(video_id)

        return {
            "video_id": video_id,
            "playlists": items,
        }

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.post("/api/video/{video_id}/action")
def video_action(video_id: str, payload: dict):
    """点赞 / 取消点赞 / 储存 / 取消储存。

    请求体：
      {"action": "like" | "unlike" | "save" | "unsave",
       "playlist": "清单名（可选）"}

    储存 / 取消储存走官网的 #video-save-form：
    点「储存」只是弹窗，真正生效靠给清单 checkbox 派发 change
    （服务端按 is_checked 决定加入还是移除）。
    点赞是页内 XHR，原地读 DOM 判断是否真的生效。
    """
    action = (payload or {}).get("action", "").strip()
    playlist = (payload or {}).get("playlist", "").strip()

    if action not in ("like", "unlike", "save", "unsave"):
        raise HTTPException(
            status_code=400,
            detail="action 必须是 like / unlike / save / unsave 之一"
        )

    try:
        ok, message, state = auth.video_action(
            video_id, action, playlist=playlist
        )

        if ok:
            # 页面内容变了，相关缓存作废
            detail_cache.clear()
            user_cache.clear()
            # 储存/取消储存会改变播放清单内容，清单缓存也要清
            playlist_cache.clear()

        elif action in ("save", "unsave"):
            # 保险：即使复核说"没生效"，也把详情缓存清掉。
            #
            # 因为官网那边可能**已经改了**，只是我们的复核没能确认；
            # 这时如果留着旧缓存，用户再进详情页会看到过期的
            # 已储存/未储存状态（这个假失败坑过一次，症状是
            # 明明存进「稍后观看」了，详情页的图标还是空心）。
            # 清掉最多多一次重新抓取，代价很小。
            detail_cache.clear()
            user_cache.clear()

        if not ok:
            raise HTTPException(status_code=400, detail=message)

        return {
            "ok": True,
            "message": message,
            "state": state
        }

    except HTTPException:
        raise

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.get("/api/user/{user_id}/home")
def user_center_home(user_id: str):
    """个人中心「主页」的栏目段。

    官网这个页面上有 4 个栏目（觀看紀錄 / 稍後觀看 / 讚好的影片 / 播放清單），
    每个栏目横向排一排卡片，右边有「查看更多」跳到对应页面。

    返回的每个栏目最多 10 个条目（limit_per_row）。
    """
    if not user_id:
        raise HTTPException(status_code=400, detail="user_id 不能为空")

    url = f"https://hanime1.me/user/{user_id}"

    try:
        parser, from_cache = parse_page(
            url,
            ready_selector="a.horizontal-row-title",
            cache=user_cache,
        )

        print("命中缓存:" if from_cache else "已重新加载页面")

        rows = parser.get_user_home_rows(limit_per_row=10)

        print("栏目数量:")
        print(len(rows))

        for row in rows:
            print(f"  {row['name']}: {len(row['videos'] or row['playlists'])} 个")

        title = parser.get_title() or ""
        normalized = title.replace("\xa0", " ")
        name = (
            normalized.split(" - ", 1)[0]
            if " - " in normalized
            else normalized
        )

        for suffix in ("的首頁", "的影片", "的播放清單", "的首页"):
            if name.endswith(suffix):
                name = name[: -len(suffix)]
                break

        return {
            "user_id": user_id,
            "url": url,
            "name": name.strip(),
            "avatar": parser.get_user_avatar(),
            "sections": rows,
        }

    except HTTPException:
        raise

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.get("/api/playlists")
def get_playlists(
    page: int = 1,
    search: str = ""
):
    try:
        if page < 1:
            raise HTTPException(
                status_code=400,
                detail="page 必须大于等于 1"
            )

        search = search.strip()

        # 播放清单是账号私有数据，必须用**当前登录的那个账号**。
        # 以前这里写死 715321（早期测试账号），换账号后拿到的还是它的数据。
        account = auth.get_account()

        if not account["logged_in"] or not account["user_id"]:
            raise HTTPException(
                status_code=401,
                detail="播放清单属于账号数据，请先登录",
            )

        base_url = (
            f"https://hanime1.me/user/{account['user_id']}/playlists"
        )

        # =========================
        # 搜索模式
        # =========================
        if search:
            print("准备搜索播放清单:")
            print(search)

            all_playlists = []

            # 先打开第一页，获取总页数
            first_url = base_url

            print("准备打开播放清单第一页:")
            print(first_url)

            first_parser, _ = parse_page(
                first_url,
                ready_selector=LIST_READY_SELECTOR,
                cache=playlist_cache,
            )

            total_pages = 1

            for link in first_parser.soup.find_all(
                "a",
                href=True
            ):
                href = first_parser.clean_url(
                    link.get("href")
                )

                if not href:
                    continue

                if not href.startswith(
                    base_url + "?page="
                ):
                    continue

                try:
                    page_number = int(
                        href.split(
                            "?page=",
                            1
                        )[1]
                    )
                except ValueError:
                    continue

                if page_number > total_pages:
                    total_pages = page_number

            print("检测到播放清单总页数:")
            print(total_pages)

            # 遍历全部播放清单页面
            for current_page in range(
                1,
                total_pages + 1
            ):
                if current_page == 1:
                    url = base_url
                else:
                    url = (
                        f"{base_url}"
                        f"?page={current_page}"
                    )

                print(
                    "搜索播放清单，第"
                    f"{current_page}/{total_pages}页:"
                )
                print(url)

                parser, _ = parse_page(
                    url,
                    ready_selector=LIST_READY_SELECTOR,
                    cache=playlist_cache,
                )

                playlists = parser.get_playlists()

                print(
                    "本页播放清单数量:"
                    f"{len(playlists)}"
                )

                all_playlists.extend(
                    playlists
                )

            print(
                "全部播放清单数量:"
                f"{len(all_playlists)}"
            )

            # 本地搜索播放清单名称
            search_results = []

            cc = OpenCC("s2t")

            search_text = cc.convert(
                search.strip()
            ).casefold()

            for playlist in all_playlists:
                name = (
                    playlist.get("name")
                    or ""
                ).strip()

                searchable_name = cc.convert(
                    name
                ).casefold()

                if search_text in searchable_name:
                    search_results.append(
                        playlist
                    )

            print(
                "搜索匹配数量:"
                f"{len(search_results)}"
            )

            return {
                "page": 1,
                "total_pages": 1,
                "search": search,
                "results": search_results
            }

        # =========================
        # 普通分页模式
        # =========================
        if page == 1:
            url = base_url
        else:
            url = (
                f"{base_url}"
                f"?page={page}"
            )

        print("准备打开播放清单页面:")
        print(url)

        parser, from_cache = parse_page(
            url,
            ready_selector=LIST_READY_SELECTOR,
            cache=playlist_cache,
        )

        print("命中缓存:" if from_cache else "已重新加载页面")

        playlists = parser.get_playlists()

        print("本页播放清单数量:")
        print(len(playlists))

        total_pages = 1

        for link in parser.soup.find_all(
            "a",
            href=True
        ):
            href = parser.clean_url(
                link.get("href")
            )

            if not href:
                continue

            if not href.startswith(
                base_url + "?page="
            ):
                continue

            try:
                page_number = int(
                    href.split(
                        "?page=",
                        1
                    )[1]
                )
            except ValueError:
                continue

            if page_number > total_pages:
                total_pages = page_number

        print("检测到播放清单页数:")
        print(total_pages)

        return {
            "page": page,
            "total_pages": total_pages,
            "results": playlists
        }

    except HTTPException:
        raise

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.get("/api/playlist")
def get_playlist(list_id: str):
    try:
        if not list_id:
            raise HTTPException(
                status_code=400,
                detail="list_id 不能为空"
            )

        url = (
            "https://hanime1.me/playlist"
            f"?list={list_id}"
        )

        print("准备打开播放清单:")
        print(url)

        parser, from_cache = parse_page(
            url,
            ready_selector=LIST_READY_SELECTOR,
            cache=playlist_cache,
        )

        print("命中缓存:" if from_cache else "已重新加载页面")

        videos = parser.get_playlist_videos()

        # 右上角书签的收藏状态（实心=已收藏），也在这张页面 HTML 里
        bookmark = parser.get_playlist_bookmark_state()

        print("播放清单影片数量:")
        print(len(videos))

        return {
            "list_id": list_id,
            "url": url,
            "title": parser.get_title(),
            "bookmarked": bookmark.get("bookmarked", False),
            # 自己的清单没有书签表单，客户端据此隐藏/禁用书签
            "can_bookmark": bookmark.get("can_bookmark", False),
            "results": videos
        }

    except HTTPException:
        raise

    except Exception as exc:
        raise HTTPException(
            status_code=500,
            detail=str(exc)
        )


@app.post("/api/playlist/{list_id}/bookmark")
def toggle_playlist_bookmark(list_id: str):
    """收藏 / 取消收藏一个播放清单（对应官网右上角的书签）。

    官网机制（从页面 HTML 读出来的）：
      <form id="playlist-show-add-form" method="POST"
            action="https://hanime1.me/addPlaylist">
        <input type="hidden" name="_token" ...>
        <input type="hidden" name="playlist-reference-id" value="976998">
      </form>
    POST 一次就**切换**收藏状态。

    返回切换后的状态，客户端据此点亮/熄灭书签。
    """
    if not list_id:
        raise HTTPException(status_code=400, detail="list_id 不能为空")

    try:
        ok, message, state = auth.toggle_playlist_bookmark(list_id)

        if not ok:
            raise HTTPException(status_code=400, detail=message)

        # 收藏状态变了，清单相关缓存作废
        playlist_cache.clear()
        user_cache.clear()

        return {"ok": True, "message": message, "state": state}

    except HTTPException:
        raise

    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
