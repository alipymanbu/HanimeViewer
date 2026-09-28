"""账号 / 登录相关。

设计说明
--------
Hanime1 是服务端渲染的站点：登录状态保存在浏览器 cookie 里，
点赞、储存、个人主页这些内容都依赖这个 cookie。

本项目的数据本来就是通过「用户自己的真实 Chrome」抓的，
所以登录也走同一条路：在**那个 Chrome 里**提交登录表单。
好处是：

- CSRF token（_token）由页面自己提供，不用我们去猜
- session cookie 由浏览器自己保存，后续所有请求自动带上
- 不需要在客户端保存密码或 cookie

密码只在提交表单的那一瞬间存在于内存里，不会写进任何文件。
"""

import json
import re
import threading
import time

from cdp.chrome import ChromeCDP


LOGIN_URL = "https://hanime1.me/login"

# 登录状态缓存（避免每次请求都去问浏览器）
_state_lock = threading.Lock()
_state = {
    "checked_at": 0.0,
    "logged_in": False,
    "user_id": "",
    "username": "",
    "avatar": "",
}

# 登录状态缓存多久（秒）。短一点，保证用户在浏览器里手动登录/登出后能及时反映
STATE_TTL = 15


# 用一个 JS 片段一次性采集所有登录线索，避免多次往返。
#
# 为什么要多线索：只靠导航栏的 #user-modal-trigger 不可靠 ——
# 实测在 /user/{id}/playlists 这类页面上它的 href 是**空的**，
# 于是明明登录着却被判定成未登录，播放清单接口就 401 了。
#
# 可靠的线索（都实测过）：
#   1. 页面上有「登出」入口（h5.user-modal-link）—— 只有登录后才渲染，
#      这是最强信号
#   2. #user-modal-trigger 的 href 指向 /user/{id}
#   3. 当前 URL 本身就是 /user/{id}/...
#   4. 页面里同时出现 /user/{id}/saves 和 /user/{id}/edit
#
# 注意不要用「头像容器的 innerText」当用户名：
# 那个位置是图标文字（实测会拿到 arrow_drop_down / cast 这种垃圾值）。
_ACCOUNT_PROBE = """
(() => {
    const out = {
        trigger: '',
        url: location.href,
        candidates: [],
        hasLogout: false,
        avatar: '',
    };

    const t = document.querySelector('#user-modal-trigger');
    if (t) {
        out.trigger = t.getAttribute('href') || '';
        const img = t.querySelector('img');
        if (img) out.avatar = img.getAttribute('src') || '';
    }

    // 「登出」入口：只有登录后才存在
    document.querySelectorAll('.user-modal-link').forEach(e => {
        const txt = (e.innerText || '').trim();
        if (txt.indexOf('登出') !== -1 || txt.indexOf('退出') !== -1) {
            out.hasLogout = true;
        }
    });

    const ids = {};
    document.querySelectorAll('a[href*="/user/"]').forEach(a => {
        const m = (a.getAttribute('href') || '')
            .match(/\\/user\\/(\\d+)(\\/[a-z]+)?/);
        if (!m) return;
        const id = m[1];
        const sub = m[2] || '';
        ids[id] = ids[id] || new Set();
        if (sub) ids[id].add(sub.replace('/', ''));
    });

    for (const id of Object.keys(ids)) {
        out.candidates.push({id: id, subs: [...ids[id]]});
    }

    return JSON.stringify(out);
})()
"""


def _read_account(chrome):
    """从当前页面读出登录状态。

    返回 dict，字段与 _state 一致。
    """
    result = {
        "logged_in": False,
        "user_id": "",
        "username": "",
        "avatar": "",
        "url": "",
    }

    try:
        raw = chrome.evaluate(_ACCOUNT_PROBE).get("value") or "{}"
        probe = json.loads(raw)
    except Exception:
        return result

    trigger = (probe.get("trigger") or "").strip()
    current_url = (probe.get("url") or "").strip()
    has_logout = probe.get("hasLogout") is True

    user_id = ""

    # 线索 1：导航栏头像链接
    if trigger and "/login" not in trigger and "/user/" in trigger:
        user_id = trigger.rstrip("/").rsplit("/", 1)[-1]

    # 线索 2：当前就在某个用户页面上
    if not user_id and "/user/" in current_url:
        tail = current_url.split("/user/", 1)[1]
        first = tail.split("/", 1)[0].split("?", 1)[0]

        if first.isdigit():
            user_id = first

    # 线索 3：页面里有没有只有登录后才渲染的入口
    if not user_id or not has_logout:
        for candidate in probe.get("candidates") or []:
            subs = set(candidate.get("subs") or [])

            # 「稍后观看」+「账户资料」同时出现 => 已登录
            if "saves" in subs and "edit" in subs:
                if not user_id:
                    user_id = str(candidate.get("id") or "")

                has_logout = True
                break

    # 没有任何登录迹象
    if not user_id or not has_logout:
        return result

    result["logged_in"] = True
    result["user_id"] = user_id
    result["url"] = f"https://hanime1.me/user/{user_id}"
    result["avatar"] = (probe.get("avatar") or "").strip()

    # 用户名页面上不一定有（导航栏只有图标），拿不到就留空，
    # 打开个人主页时会被真实名字覆盖。
    return result


def get_account(force=False):
    """取得当前登录状态（带短缓存）。"""
    with _state_lock:
        fresh = (
            time.monotonic() - _state["checked_at"] < STATE_TTL
        )

        if fresh and not force:
            return dict(_state)

    chrome = ChromeCDP()

    account = _read_account(chrome)

    # 用户名在导航栏里拿不到（那里只有图标），
    # 而侧边栏要显示名字，所以顺着 id 去个人主页取一次标题。
    # 有缓存，不会每次请求都抓页面。
    if account["logged_in"] and not account["username"]:
        account["username"] = _lookup_username(
            account["user_id"]
        )

    if not account["logged_in"]:
        _username_cache.clear()

    with _state_lock:
        _state.update(account)
        _state["checked_at"] = time.monotonic()

        return dict(_state)


# 用户名缓存：user_id -> 名字（页面标题里带，基本不变）
_username_cache = {}


def _lookup_username(user_id):
    """从个人主页标题里取用户名（失败返回空字符串，不影响主流程）。"""
    if not user_id:
        return ""

    cached = _username_cache.get(user_id)

    if cached is not None:
        return cached

    name = ""

    try:
        chrome = ChromeCDP()

        ready, html = chrome.navigate_and_wait(
            f"https://hanime1.me/user/{user_id}",
            ready_selector="a.video-link",
            timeout=20.0,
            min_stable=0.5,
        )

        if ready and html:
            from parser.hanime_parser import HanimeParser

            title = HanimeParser(html).get_title() or ""
            normalized = title.replace("\xa0", " ")
            candidate = (
                normalized.split(" - ", 1)[0]
                if " - " in normalized
                else normalized
            )

            for suffix in ("的首頁", "的影片", "的播放清單", "的首页"):
                if candidate.endswith(suffix):
                    candidate = candidate[: -len(suffix)]
                    break

            name = candidate.strip()
    except Exception:
        name = ""

    _username_cache[user_id] = name

    return name


def login(email, password, timeout=30.0):
    """在真实 Chrome 里提交登录表单。

    返回 (成功与否, 账号信息, 错误信息)。
    """
    if not email or not password:
        return False, {}, "邮箱和密码不能为空"

    chrome = ChromeCDP()

    # 0. 如果浏览器当前是登录状态，先登出。
    #
    #    否则打开 /login 时服务端会发现「已经登录」而直接重定向走，
    #    我们等不到登录表单，就会误报「打不开登录页」。
    #    （这正是「退出登录后再登录」失败的根因，实测复现过。）
    try:
        current = _read_account(chrome)

        if current["logged_in"]:
            logout()
            time.sleep(1.0)
    except Exception:
        pass

    # 1. 打开登录页，拿到带 CSRF token 的表单
    ready, html = chrome.navigate_and_wait(
        LOGIN_URL,
        ready_selector="input[name='_token']",
        timeout=timeout,
        min_stable=0.3,
    )

    if not ready:
        # 超时了：说清楚当前落在哪个页面，便于排查
        try:
            landed_url = chrome.get_url() or "(未知)"
            landed_title = chrome.get_title() or ""
        except Exception:
            landed_url = "(读取失败)"
            landed_title = ""

        # 再看一眼是不是其实已经登录了（说明登出没生效）
        try:
            after = _read_account(chrome)

            if after["logged_in"]:
                return (
                    False,
                    {},
                    "浏览器当前仍是登录状态，登录页被重定向了。"
                    "请先退出登录再试。",
                )
        except Exception:
            pass

        return (
            False,
            {},
            f"打不开登录页（停留页面：{landed_url} {landed_title}）",
        )

    token = chrome.evaluate(
        "(()=>{const e=document.querySelector(\"input[name='_token']\");"
        "return e?e.value:'';})()"
    ).get("value") or ""

    if not token:
        return False, {}, "没有拿到登录页的 CSRF token"

    # 2. 填表并提交。
    #
    #    注意：不能用 form.submit()。
    #    登录表单里有一个 <button name="submit" type="submit">，
    #    这个命名元素会把 form.submit 方法遮蔽掉，
    #    导致 "form.submit is not a function"。
    #    所以这里改成点击真正的提交按钮 —— 这也更接近用户的真实操作。
    #
    #    密码通过 JSON 转义注入，避免引号/反斜杠破坏脚本。
    expression = """
    (() => {
        const form = document.querySelector("input[name='_token']").form
            || document.querySelector('form');
        if (!form) return 'no-form';

        const emailInput = form.querySelector("input[type='email'], input[name='email']");
        const passInput = form.querySelector("input[type='password'], input[name='password']");
        if (!emailInput || !passInput) return 'no-input';

        const tokenInput = form.querySelector("input[name='_token']");
        if (tokenInput) tokenInput.value = %s;

        emailInput.value = %s;
        passInput.value = %s;

        // 有些前端框架只认 input 事件，手动派发一下
        for (const el of [emailInput, passInput]) {
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
        }

        // 优先点提交按钮；实在找不到再用 requestSubmit 兜底
        const submitBtn = form.querySelector(
            "button[type='submit'], button[name='submit'], input[type='submit']"
        );

        if (submitBtn) {
            submitBtn.click();
            return 'submitted';
        }

        if (typeof form.requestSubmit === 'function') {
            form.requestSubmit();
            return 'submitted';
        }

        return 'no-submit';
    })()
    """ % (
        json.dumps(token),
        json.dumps(email),
        json.dumps(password),
    )

    try:
        submitted = chrome.evaluate(expression).get("value")
    except Exception as exc:
        return False, {}, f"提交登录表单失败：{exc}"

    if submitted != "submitted":
        return False, {}, f"登录表单结构异常（{submitted}）"

    # 3. 等页面响应。
    #
    #    登录失败时站点会重新渲染登录页，并在页面上显示错误文字
    #    （实测是 Laravel 的 "auth.failed"）。
    #    所以一旦确认「还在 /login」且错误提示已经出现，就立刻返回失败，
    #    不用把 30 秒等满。
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        time.sleep(0.5)

        try:
            current = chrome.get_url() or ""
        except Exception:
            continue

        if current.rstrip("/").endswith("/login"):
            # 还在登录页：检查是否已经渲染出失败提示
            try:
                has_error = chrome.evaluate(
                    "(document.body ? document.body.innerText : '')"
                    ".indexOf('auth.failed') !== -1"
                ).get("value")
            except Exception:
                has_error = False

            if has_error:
                return False, {}, "登录失败：邮箱或密码不正确"

            continue

        account = _read_account(chrome)

        if account["logged_in"]:
            with _state_lock:
                _state.update(account)
                _state["checked_at"] = time.monotonic()

            return True, account, ""

    # 超时：再确认一次，区分「失败」和「太慢」
    time.sleep(1.0)

    account = _read_account(chrome)

    if account["logged_in"]:
        with _state_lock:
            _state.update(account)
            _state["checked_at"] = time.monotonic()

        return True, account, ""

    return False, {}, "登录失败：邮箱或密码不正确"


def logout():
    """让浏览器真正登出，并清掉本地状态缓存。

    为什么不能用 GET /logout：
    官网的登出是一个 **POST 表单**（`<form action=.../logout method=POST>`
    带 CSRF `_token`）。直接 GET 那个地址不会登出，浏览器仍然保持登录态。

    后果很隐蔽：登出没生效 -> 再点「登录」-> 打开 /login 时服务端发现
    你已经登录，会重定向走（实测落到一个 404 的 /home），
    于是 navigate_and_wait 等不到登录表单而超时，
    界面报「打不开登录页」—— 实测复现过这个现象。

    正确做法：在首页上找到那个登出表单，补上 token 之后 POST 提交。
    """
    chrome = ChromeCDP()

    try:
        # 先回到首页，保证页面上有登出表单
        try:
            chrome.navigate_and_wait(
                "https://hanime1.me/",
                ready_selector="a.video-link",
                timeout=25.0,
                min_stable=0.5,
            )
        except Exception:
            pass

        submitted = chrome.evaluate(
            """(() => {
                const forms = [...document.querySelectorAll('form')];
                const form = forms.find(f =>
                    (f.getAttribute('action') || '').indexOf('/logout') !== -1);

                if (!form) return 'no-logout-form';

                const method = (form.getAttribute('method') || 'get').toLowerCase();
                if (method !== 'post') return 'not-post';

                // 按表单原始字段原样提交（token 用的是表单里那个值）
                const body = new URLSearchParams();
                form.querySelectorAll('input[name]').forEach(i => {
                    body.append(i.name, i.value);
                });

                fetch(form.getAttribute('action'), {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/x-www-form-urlencoded',
                    },
                    body: body.toString(),
                    credentials: 'same-origin',
                    redirect: 'follow',
                }).catch(() => {});

                return 'posted';
            })()"""
        ).get("value")

        # 等登录态真正失效。
        # 注意要重新加载一次页面：官网导航是 SPA，
        # 登出后旧 DOM 里的导航栏还留着登录态的痕迹，
        # 不刷新的话 _read_account 会误判成还登录着。
        for _ in range(20):
            time.sleep(0.5)

            try:
                chrome.navigate_and_wait(
                    "https://hanime1.me/",
                    ready_selector="a.video-link",
                    timeout=20.0,
                    min_stable=0.4,
                )
            except Exception:
                pass

            info = _read_account(chrome)

            if not info["logged_in"]:
                break
    except Exception:
        pass

    with _state_lock:
        _state.update({
            "checked_at": time.monotonic(),
            "logged_in": False,
            "user_id": "",
            "username": "",
            "avatar": "",
        })

    _username_cache.clear()

    return True


# ==========================================================
# 影片操作（点赞 / 储存）
# ==========================================================
#
# 这两个按钮不是普通表单：点击后由站点自己的 JS 发请求，
# 请求里带着登录 cookie 和 CSRF token。
# 与其去逆向它的私有接口，不如就让页面自己去做 ——
# 我们在真实 Chrome 里触发一次真实点击，然后重新加载页面确认结果。
#
# 这样既不猜接口，也不会伪造请求头。

VIDEO_URL = "https://hanime1.me/watch?v={video_id}"

# 操作时页面上的按钮 id
LIKE_BUTTON_ID = "video-like-btn"
UNLIKE_BUTTON_ID = "video-unlike-btn"
SAVE_BUTTON_ID = "video-save-btn"


def _click_button(chrome, button_id):
    """在页面里触发一次真实点击。"""
    expression = (
        "(()=>{"
        f"const el=document.getElementById({json.dumps(button_id)});"
        "if(!el) return 'missing';"
        "el.click();"
        "return 'clicked';"
        "})()"
    )

    return chrome.evaluate(expression).get("value")


# 读取点赞区的当前状态（比例 + 数量），用来判断点赞到底有没有生效
_LIKE_STATE = (
    "(()=>{"
    "const btn=document.getElementById('video-like-btn');"
    "if(!btn) return '';"
    "const span=btn.querySelector('span');"
    "const count=span?span.textContent.replace(/[()\\s]/g,''):'';"
    "const m=(btn.innerText||'').match(/(\\d+(?:\\.\\d+)?%)/);"
    "return JSON.stringify({ratio:m?m[1]:'',count:count});"
    "})()"
)


def toggle_playlist_bookmark(list_id):
    """收藏 / 取消收藏一个播放清单（官网右上角那个书签）。

    官网机制（从播放清单页 HTML 里读出来的）：

        <form id="playlist-show-add-form" method="POST"
              action="https://hanime1.me/addPlaylist">
          <input type="hidden" name="_token" value="...">
          <input type="hidden" name="playlist-reference-id" value="976998">
          <button type="submit">
            <span id="playlist-bookmark-icon" class="material-symbols-outlined"
                  style="font-variation-settings: 'FILL' 1;">bookmark</span>
          </button>
        </form>

    要点：
      - POST /addPlaylist 一次就**切换**状态（已收藏 -> 取消，未收藏 -> 收藏）。
      - 收藏状态看 #playlist-bookmark-icon 的 style：
        带 'FILL' 1 = 实心 = 已收藏。
      - 所以流程是：先读当前状态 -> 提交表单 -> 再读一次确认真的变了。

    返回 (成功, 消息, {"bookmarked": bool})。
    """
    account = get_account()

    if not account["logged_in"]:
        return False, "需要先登录才能收藏播放清单", {}

    chrome = ChromeCDP()

    url = f"https://hanime1.me/playlist?list={list_id}"

    ready, _ = chrome.navigate_and_wait(
        url,
        timeout=25.0,
        min_stable=0.6,
    )

    if not ready:
        return False, "打不开播放清单页面", {}

    def read_state():
        raw = chrome.evaluate(
            "(()=>{const e=document.getElementById('playlist-bookmark-icon');"
            "if(!e) return 'missing';"
            "return String(e.getAttribute('style')||'');})()"
        ).get("value") or ""

        if raw == "missing":
            return None

        normalized = raw.replace('"', "'").replace(" ", "")

        return "'FILL'1" in normalized

    before = read_state()

    if before is None:
        return False, "这个页面没有收藏书签（可能是自己的播放清单）", {}

    # 提交表单（POST /addPlaylist 会切换状态）
    try:
        result = chrome.evaluate(
            """(()=>{
                const form = document.getElementById('playlist-show-add-form');
                if (!form) return 'no-form';

                const token = form.querySelector("input[name='_token']");
                const ref = form.querySelector(
                    "input[name='playlist-reference-id']");

                if (!token || !ref) return 'no-fields';

                const body = new URLSearchParams();
                body.append('_token', token.value);
                body.append('playlist-reference-id', ref.value);

                fetch(form.getAttribute('action'), {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/x-www-form-urlencoded',
                    },
                    body: body.toString(),
                    credentials: 'same-origin',
                    redirect: 'follow',
                }).catch(() => {});

                return 'posted';
            })()"""
        ).get("value")
    except Exception as exc:
        return False, f"提交收藏失败：{exc}", {}

    if result == "no-form":
        return False, "找不到收藏表单", {}

    if result == "no-fields":
        return False, "收藏表单缺少必要字段", {}

    time.sleep(2.0)

    # 重新加载确认状态真的翻转了（不能只信接口 200）
    after = None

    try:
        chrome.navigate_and_wait(
            url,
            timeout=25.0,
            min_stable=0.6,
        )

        after = read_state()
    except Exception:
        pass

    if after is None:
        return False, "提交后读不到书签状态", {}

    if after == before:
        return (
            False,
            "提交了收藏请求，但状态没有变化，可能没有真正生效。",
            {"bookmarked": before},
        )

    if after:
        return True, "已收藏到我的播放清单", {"bookmarked": True}

    return True, "已取消收藏", {"bookmarked": False}


def fetch_playlists(video_id):
    """读取「储存」弹窗里可选的播放清单。

    弹窗结构（实测）：

        <form id="video-save-form" action="https://hanime1.me/save" method="POST">
          <input type="hidden" name="_token" value="...">
          <input type="hidden" name="playlist-video-id" value="408116">
          <label class="playlist-checkbox-container">
            稍后观看 <input type="checkbox" ...>
          </label>
          ...
          <button>完成储存影片</button>
        </form>

    返回 [(清单名, 是否已勾选), ...]，失败返回 []。
    """
    account = get_account()

    if not account["logged_in"]:
        return []

    chrome = ChromeCDP()

    ready, _ = chrome.navigate_and_wait(
        VIDEO_URL.format(video_id=video_id),
        all_selectors=[
            "#video-artist-name",
            "video",
            ".video-description-panel",
        ],
        timeout=25.0,
        min_stable=0.6,
    )

    if not ready:
        return []

    # 打开弹窗（只是让它渲染出选项，不提交）
    try:
        chrome.evaluate(
            "(()=>{const e=document.getElementById('video-save-btn');"
            "if(e) e.click(); return 1;})()"
        )
        time.sleep(1.5)
    except Exception:
        pass

    try:
        raw = chrome.evaluate(
            "(()=>{"
            "const m=document.getElementById('playlistModal');"
            "if(!m) return '[]';"
            "const out=[];"
            "m.querySelectorAll('label.playlist-checkbox-container').forEach(l=>{"
            "const cb=l.querySelector('input[type=checkbox]');"
            "const name=(l.innerText||'').trim();"
            "if(name) out.push({name:name,checked:!!(cb&&cb.checked)});"
            "});"
            "return JSON.stringify(out);"
            "})()"
        ).get("value") or "[]"

        items = json.loads(raw)
    except Exception:
        items = []

    # 关掉弹窗，避免影响后续操作
    try:
        chrome.evaluate(
            "(()=>{const b=document.querySelector('#playlistModal .close');"
            "if(b) b.click(); return 1;})()"
        )
    except Exception:
        pass

    return items


def save_to_playlist(video_id, playlist_name="", save=True):
    """把影片储存到播放清单，或从播放清单里移除。

    `save=True`  -> 加入清单（checkbox 设为勾选）
    `save=False` -> 从清单移除（checkbox 设为未勾选）

    两种操作走**同一套流程**，区别只是目标勾选状态：

    官网的真实逻辑（从站点 app.js 里读出来的，别再猜了）：

        $(document).on("change", "#playlistModal input.playlist-checkbox",
        function(){
          $.ajax({ type:"POST", url: $("#video-save-form").attr("action"),
            data: jQuery.param({
              input_id:   $(this).attr("id"),        // 清单 id
              user_id:    $("#playlist-user-id").val(),
              video_id:   $("#playlist-video-id").val(),
              is_checked: $(this).prop("checked"),   // true=加入 false=移除
            }), dataType:"json" })
        })

    三个关键点（都踩过）：
      1. 触发条件是 checkbox 的 **change 事件**，不是点「完成储存影片」按钮
         （那个按钮只带 data-dismiss="modal"，什么都不提交）。
         用 JS 直接设 .checked 是**不会**触发 change 的，
         必须自己 dispatchEvent 一个 change。
      2. 字段名是 input_id / user_id / video_id / is_checked，
         不是把清单 id 当字段名。
      3. 服务端按 is_checked 决定「加入」还是「移除」——
         所以取消储存就是把 checkbox 设成未勾选再派发 change。

    playlist_name 为空时用第一个清单。
    """
    account = get_account()

    if not account["logged_in"]:
        return False, "需要先登录才能储存", {}

    chrome = ChromeCDP()

    ready, _ = chrome.navigate_and_wait(
        VIDEO_URL.format(video_id=video_id),
        all_selectors=[
            "#video-artist-name",
            "video",
            ".video-description-panel",
        ],
        timeout=25.0,
        min_stable=0.6,
    )

    if not ready:
        return False, "打不开影片页面", {}

    # 打开储存弹窗
    try:
        clicked = chrome.evaluate(
            "(()=>{const e=document.getElementById('video-save-btn');"
            "if(!e) return 'missing';"
            "const t=e.getAttribute('data-target')||'';"
            "if(t.indexOf('signUpModal')!==-1) return 'needs-login';"
            "e.click(); return 'clicked';})()"
        ).get("value")
    except Exception as exc:
        return False, f"打开储存弹窗失败：{exc}", {}

    if clicked == "needs-login":
        with _state_lock:
            _state["checked_at"] = 0.0

        return False, "登录状态已失效，请重新登录", {}

    if clicked != "clicked":
        return False, "找不到储存按钮", {}

    time.sleep(1.8)

    # 把目标清单的勾选状态设成想要的值，再派发 change 让站点自己去提交
    expression = """
    (() => {
        const form = document.getElementById('video-save-form');
        if (!form) return 'no-form';

        const boxes = [...form.querySelectorAll('input.playlist-checkbox')];
        if (!boxes.length) return 'no-playlist';

        const want = %s;
        const wantChecked = %s;

        let target = null;

        if (want) {
            target = boxes.find(b => {
                const label = b.closest('label');
                return label && (label.innerText || '').trim() === want;
            }) || null;
            if (!target) return 'playlist-not-found';
        } else {
            target = boxes[0];
        }

        const label = target.closest('label');
        const name = label ? (label.innerText || '').trim() : target.id;

        // 已经是想要的状态就不用再动
        if (target.checked === wantChecked) {
            return 'nochange:' + name + ':' + target.id;
        }

        target.checked = wantChecked;
        target.dispatchEvent(new Event('change', {bubbles: true}));

        return 'submitted:' + name + ':' + target.id;
    })()
    """ % (
        json.dumps(playlist_name or ""),
        "true" if save else "false",
    )

    try:
        result = chrome.evaluate(expression).get("value") or ""
    except Exception as exc:
        return False, f"提交储存失败：{exc}", {}

    action_word = "储存" if save else "取消储存"

    if result.startswith("nochange:"):
        _tag, name, list_id = (result.split(":") + ["", ""])[:3]

        return (
            True,
            f"「{name}」本来就没有这部影片"
            if not save
            else f"这个影片已经在「{name}」里了",
            {
                "playlist": name,
                "list_id": list_id,
                "saved": save,
                "verified": True,
            },
        )

    if result.startswith("submitted:"):
        _tag, name, list_id = (result.split(":") + ["", ""])[:3]

        # 官网的 XHR 完成后会返回新的按钮 HTML，等它落地
        time.sleep(2.5)

        in_playlist = None

        # 复核：**重新加载影片页**，看目标清单的 checkbox 现在是什么状态。
        #
        # 为什么不能用 `/api/playlist?list_id=xxx` 复核：
        # 「稍后观看」的清单 id 是 `save`，而 `/playlist?list=save`
        # 是个 **404 页面**（实测），拿它去查永远是 0 部影片 ——
        # 于是保存到「稍后观看」会被判成失败。
        # 后果很隐蔽：接口报错 -> 详情缓存不被清 -> 再进详情页
        # 拿到的还是旧的 saved=false，图标显示成空心（用户报的就是这个）。
        #
        # 储存表单里的 checkbox 状态才是权威答案，而且它按**名字**匹配，
        # 「稍后观看」这种特殊清单一样适用。
        try:
            chrome.navigate_and_wait(
                VIDEO_URL.format(video_id=video_id),
                all_selectors=[
                    "#video-artist-name",
                    "video",
                    ".video-description-panel",
                ],
                timeout=25.0,
                min_stable=0.6,
            )

            probe = """
            (() => {
                const form = document.getElementById('video-save-form');
                if (!form) return 'no-form';

                const want = %s;
                const boxes = [...form.querySelectorAll(
                    'input.playlist-checkbox')];

                const target = want
                    ? boxes.find(b => {
                        const l = b.closest('label');
                        return l && (l.innerText || '').trim() === want;
                      })
                    : boxes[0];

                if (!target) return 'not-found';

                return target.checked ? 'checked' : 'unchecked';
            })()
            """ % json.dumps(name)

            probe_result = (
                chrome.evaluate(probe).get("value") or ""
            )

            if probe_result == "checked":
                in_playlist = True

            elif probe_result == "unchecked":
                in_playlist = False
        except Exception:
            in_playlist = None

        if in_playlist is None:
            return (
                False,
                f"提交了{action_word}请求，但没能复核结果，请稍后刷新看看。",
                {"playlist": name, "list_id": list_id, "verified": False},
            )

        if in_playlist == save:
            message = (
                f"已储存到「{name}」"
                if save
                else f"已从「{name}」取消储存"
            )

            return (
                True,
                message,
                {
                    "playlist": name,
                    "list_id": list_id,
                    "saved": save,
                    "verified": True,
                },
            )

        return (
            False,
            (
                f"提交了{action_word}请求，但复核发现「{name}」的状态没变"
                f"（现在{'在' if in_playlist else '不在'}这个清单里）。"
            ),
            {
                "playlist": name,
                "list_id": list_id,
                "saved": in_playlist,
                "verified": False,
            },
        )

    mapping = {
        "no-form": "找不到储存表单",
        "no-playlist": "账号里没有可用的播放清单，请先到官网建一个",
        "playlist-not-found": f"找不到播放清单「{playlist_name}」",
    }

    return False, mapping.get(result, f"{action_word}失败（{result}）"), {}


def create_playlist(video_id, title, description=""):
    """新建一个播放清单（对应储存弹窗顶部的「新增播放清单」）。

    官网表单（实测）：

        <form id="video-create-playlist-form"
              action="https://hanime1.me/createPlaylist">
          <input type="hidden" name="_token" ...>
          <input type="hidden" name="create-playlist-video-id" value="408116">
          <input name="playlist-title" required>          <- 标题（必填）
          <textarea name="playlist-description"></textarea> <- 详细说明（选填）
        </form>

    成功后接口返回 JSON，里面的 `checkbox` 字段是**新清单的复选框 HTML**，
    从中能取到新清单的 id。

    返回 (成功, 消息, {"name":..., "list_id":...})。
    """
    account = get_account()

    if not account["logged_in"]:
        return False, "需要先登录才能新建播放清单", {}

    title = (title or "").strip()

    if not title:
        return False, "标题不能为空", {}

    chrome = ChromeCDP()

    ready, _ = chrome.navigate_and_wait(
        VIDEO_URL.format(video_id=video_id),
        all_selectors=[
            "#video-artist-name",
            "video",
            ".video-description-panel",
        ],
        timeout=25.0,
        min_stable=0.6,
    )

    if not ready:
        return False, "打不开影片页面", {}

    expression = """
    (async () => {
        const form = document.getElementById('video-create-playlist-form');
        if (!form) return 'no-form';

        const titleInput = document.getElementById('playlist-title');
        if (!titleInput) return 'no-title-input';

        titleInput.value = %s;

        const descInput = document.getElementById('playlist-description');
        if (descInput) descInput.value = %s;

        const body = new URLSearchParams();
        form.querySelectorAll('input[name], textarea[name]').forEach(e => {
            body.append(e.name, e.value);
        });

        const r = await fetch(form.getAttribute('action'), {
            method: 'POST',
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: body.toString(),
            credentials: 'same-origin',
            redirect: 'follow',
        });

        const text = await r.text();

        return JSON.stringify({status: r.status, body: text.slice(0, 4000)});
    })()
    """ % (json.dumps(title), json.dumps(description or ""))

    try:
        raw = chrome.evaluate(
            expression, timeout=90, await_promise=True
        ).get("value")
    except Exception as exc:
        return False, f"新建播放清单失败：{exc}", {}

    if raw == "no-form":
        return False, "找不到新建清单的表单", {}

    if raw == "no-title-input":
        return False, "找不到标题输入框", {}

    if not raw:
        return False, "新建播放清单没有返回结果", {}

    try:
        payload = json.loads(raw)
    except Exception:
        return False, "新建播放清单返回了无法解析的内容", {}

    if int(payload.get("status") or 0) != 200:
        return False, f"新建播放清单失败（HTTP {payload.get('status')}）", {}

    body = payload.get("body") or ""

    # 从返回的 checkbox HTML 里抠出新清单的 id
    list_id = ""
    match = re.search(
        r"playlist-checkbox[^>]*id=[\"'](\d+)[\"']", body
    )

    if not match:
        match = re.search(r"id=[\"'](\d+)[\"'][^>]*playlist-checkbox", body)

    if match:
        list_id = match.group(1)

    # 真正的确认：重新加载页面，看新清单有没有出现在储存表单里
    verified = False

    try:
        time.sleep(1.5)

        chrome.navigate_and_wait(
            VIDEO_URL.format(video_id=video_id),
            all_selectors=[
                "#video-artist-name",
                "video",
                ".video-description-panel",
            ],
            timeout=25.0,
            min_stable=0.6,
        )

        found = chrome.evaluate(
            "(()=>{const f=document.getElementById('video-save-form');"
            "if(!f) return 'no-form';"
            "const names=[...f.querySelectorAll('label.playlist-checkbox-container')]"
            ".map(l=>(l.innerText||'').trim());"
            "return JSON.stringify(names);})()"
        ).get("value") or "[]"

        names = json.loads(found) if found.startswith("[") else []

        verified = title in names
    except Exception:
        verified = False

    if verified:
        return (
            True,
            f"已新建播放清单「{title}」",
            {"name": title, "list_id": list_id, "verified": True},
        )

    return (
        False,
        f"提交了新建请求，但「{title}」没有出现在清单里，可能没建成功。",
        {"name": title, "list_id": list_id, "verified": False},
    )


def fetch_video_state(video_id):
    """读取「当前账号对这个影片做过什么」——用来点亮图标。

    返回：
      {
        "logged_in": bool,
        "liked": bool,        # 已点赞
        "disliked": bool,     # 已点踩（判不出来时为 False）
        "saved": bool,        # 已储存到某个清单
        "playlist": str,      # 存在哪个清单
        "like_ratio": str,
        "like_count": str,
      }

    判据（实测）：
      1. 未登录时点赞按钮带 `data-target="#signUpModal"`；
         登录后这个属性为空 —— 这是「能不能点」的可靠信号。
      2. 已储存：打开储存弹窗，看哪个清单的 checkbox 是选中态。
         （所以要打开弹窗，比只读 DOM 稍慢，但这是唯一可靠的判据。）
    """
    chrome = ChromeCDP()

    ready, _ = chrome.navigate_and_wait(
        VIDEO_URL.format(video_id=video_id),
        all_selectors=[
            "#video-artist-name",
            "video",
            ".video-description-panel",
        ],
        timeout=25.0,
        min_stable=0.6,
    )

    state = {
        "logged_in": False,
        "liked": False,
        "disliked": False,
        "saved": False,
        "playlist": "",
        "like_ratio": "",
        "like_count": "",
    }

    if not ready:
        return state

    try:
        raw = chrome.evaluate(
            "(()=>{"
            "const like=document.getElementById('video-like-btn');"
            "const unlike=document.getElementById('video-unlike-btn');"
            "const save=document.getElementById('video-save-btn');"
            "const t=e=>e?(e.getAttribute('data-target')||''):'#missing';"
            "const span=like?like.querySelector('span'):null;"
            "const count=span?span.textContent.replace(/[()\\s]/g,''):'';"
            "const m=like?(like.innerText||'').match(/(\\d+(?:\\.\\d+)?%)/):null;"
            "return JSON.stringify({"
            "likeTarget:t(like),"
            "unlikeTarget:t(unlike),"
            "saveTarget:t(save),"
            "ratio:m?m[1]:'',"
            "count:count,"
            "likeDisabled: like?!!like.disabled:false,"
            "unlikeDisabled: unlike?!!unlike.disabled:false"
            "});})()"
        ).get("value") or "{}"

        info = json.loads(raw)
    except Exception:
        return state

    def needs_login(target):
        return "signUpModal" in (target or "")

    state["like_ratio"] = info.get("ratio", "")
    state["like_count"] = info.get("count", "")

    can_like = not needs_login(info.get("likeTarget"))
    can_save = not needs_login(info.get("saveTarget"))

    state["logged_in"] = can_like or can_save

    if not state["logged_in"]:
        return state

    # 已点过赞的话，官网会把对应按钮置灰
    state["liked"] = bool(info.get("likeDisabled"))
    state["disliked"] = bool(info.get("unlikeDisabled"))

    # 已储存：打开弹窗看选中态
    if can_save:
        try:
            chrome.evaluate(
                "(()=>{const e=document.getElementById('video-save-btn');"
                "if(e) e.click(); return 1;})()"
            )
            time.sleep(1.5)

            picked = chrome.evaluate(
                "(()=>{"
                "const m=document.getElementById('playlistModal');"
                "if(!m) return '';"
                "const b=[...m.querySelectorAll('input.playlist-checkbox')]"
                ".find(x=>x.checked);"
                "if(!b) return '';"
                "const l=b.closest('label');"
                "return (l?(l.innerText||'').trim():b.id);"
                "})()"
            ).get("value") or ""

            if picked:
                state["saved"] = True
                state["playlist"] = picked

            # 关掉弹窗
            chrome.evaluate(
                "(()=>{const b=document.querySelector("
                "'#playlistModal .modal-close-btn');"
                "if(b) b.click(); return 1;})()"
            )
        except Exception:
            pass

    return state


def video_action(video_id, action, playlist="", timeout=25.0):
    """对影片执行点赞 / 取消点赞 / 储存 / 取消储存。

    action: "like" | "unlike" | "save" | "unsave"

    返回 (成功, 消息, 最新状态)
    """
    account = get_account()

    if not account["logged_in"]:
        return False, "需要先登录才能使用这个功能", {}

    # 储存 / 取消储存走单独的流程（要点弹窗 + 派发 change）
    if action == "save":
        return save_to_playlist(video_id, playlist, save=True)

    if action == "unsave":
        return save_to_playlist(video_id, playlist, save=False)

    button_map = {
        "like": LIKE_BUTTON_ID,
        "unlike": UNLIKE_BUTTON_ID,
    }

    button_id = button_map.get(action)

    if not button_id:
        return False, f"不支持的操作：{action}", {}

    url = VIDEO_URL.format(video_id=video_id)

    chrome = ChromeCDP()

    # 1. 打开影片页（登录状态下服务端会渲染出真实可用的按钮）
    ready, _ = chrome.navigate_and_wait(
        url,
        all_selectors=[
            "#video-artist-name",
            "video",
            ".video-description-panel",
        ],
        timeout=timeout,
        min_stable=0.6,
    )

    if not ready:
        return False, "打不开影片页面", {}

    # 2. 确认按钮确实可用（未登录时按钮只会弹注册窗）
    still_modal = chrome.evaluate(
        "(()=>{"
        f"const el=document.getElementById({json.dumps(button_id)});"
        "if(!el) return 'missing';"
        "const t=el.getAttribute('data-target')||'';"
        "return t.includes('signUpModal') ? 'needs-login' : 'ok';"
        "})()"
    ).get("value")

    if still_modal == "missing":
        return False, "页面上找不到这个按钮", {}

    if still_modal == "needs-login":
        # 有 cookie 但服务端仍认为是未登录：清掉缓存让前端重新检测
        with _state_lock:
            _state["checked_at"] = 0.0

        return False, "登录状态已失效，请重新登录", {}

    # 记录点击前的点赞数，用来验证是否真的生效
    try:
        before = json.loads(chrome.evaluate(_LIKE_STATE).get("value") or "{}")
    except Exception:
        before = {}

    # 3. 点击
    clicked = _click_button(chrome, button_id)

    if clicked != "clicked":
        return False, "点击失败", {}

    # 4. 等站点自己的请求完成，然后在**同一个页面**上重新读状态。
    #
    #    注意不要立刻导航刷新来判断：官网点赞是页内 XHR，
    #    原地读 DOM 就能看到数字变化，而且不会把页面上其它
    #    未提交的状态（比如刚打开的弹窗）弄丢。
    after = {}
    changed = False

    for _ in range(12):
        time.sleep(0.5)

        try:
            after = json.loads(
                chrome.evaluate(_LIKE_STATE).get("value") or "{}"
            )
        except Exception:
            after = {}

        if after.get("count") and after.get("count") != before.get("count"):
            changed = True
            break

        if (
            after.get("ratio")
            and after.get("ratio") != before.get("ratio")
        ):
            changed = True
            break

    if not changed:
        # 数字没变：可能本来就是这样（比如重复点赞），
        # 也可能是没生效。为了给出可靠结论，刷新一次再确认。
        time.sleep(1.0)

        try:
            chrome.navigate_and_wait(
                url,
                all_selectors=[
                    "#video-artist-name",
                    "video",
                    ".video-description-panel",
                ],
                timeout=timeout,
                min_stable=0.6,
            )

            after = json.loads(
                chrome.evaluate(_LIKE_STATE).get("value") or "{}"
            )
        except Exception:
            pass

        changed = after.get("count") != before.get("count") or (
            after.get("ratio") != before.get("ratio")
        )

    state = {
        "like_ratio": after.get("ratio", ""),
        "like_count": after.get("count", ""),
        "before_count": before.get("count", ""),
        "changed": changed,
    }

    messages = {
        "like": "点赞成功",
        "unlike": "已取消点赞",
    }

    if not changed:
        return (
            False,
            f"{messages.get(action, '操作')}，但点赞数没有变化，"
            "可能站点没有接受这次操作。",
            state,
        )

    return True, messages.get(action, "完成"), state
