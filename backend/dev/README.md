# backend/dev — 开发调试脚本（非业务代码）

## 独立运行（打包）

App 现在可以完全独立运行，不再需要手动开调试 Chrome、也不需要在终端起 uvicorn。

### 启动链路

```
frontend.exe（Flutter）
  └─ 自己启动 hanime_backend.exe        （BackendLauncher）
       └─ 自己启动调试 Chrome            （browser.py）
            └─ Chrome 打开 hanime1.me
```

客户端启动时先显示启动页，轮询 `/api/status`，
等「后端 + 调试浏览器」都就绪才进主界面，避免一进去就满屏网络错误。

### 打包命令

```powershell
# 项目根目录
powershell -ExecutionPolicy Bypass -File frontend\scripts\package_windows.ps1
```

做三件事：PyInstaller 打后端 → Flutter 打 release → 把 exe 放到 Flutter 产物旁。
产物在 `frontend/build/windows/x64/runner/Release/`，约 45 MB，可整个拷走运行
（目标机需要有 Chrome）。

只打后端：

```powershell
.venv\Scripts\python.exe backend\build_backend.py
```

### 浏览器是怎么处理的

`browser.py` 用**独立的 user-data-dir** 启动 Chrome：

```
%LOCALAPPDATA%\HanimeViewer\chrome-profile
```

为什么不共用用户日常的 Chrome 配置：共用时如果 Chrome 已经在跑，
新进程会被合并进已有实例，**调试端口根本不会开** —— 这是最常见的失败原因。
独立配置目录同时也让登录 cookie 能持久保存，下次启动不用重新登录。

#### 窗口是隐藏的（重要）

用户要求「从头到尾只看到 frontend.exe」，所以浏览器窗口会被隐藏：

1. `--window-position=-32000,-32000` 把窗口移出屏幕
2. 再用 Win32 `ShowWindow(SW_HIDE)` 把顶层窗口真正藏起来（不进任务栏、不抢焦点）

只做第 1 步是不够的 —— 那样任务栏里还是会多一个图标。

**为什么不用无头模式（`--headless`）**：
实测 headless Chrome 打开 hanime1.me 会被 Cloudflare 拦成
`Attention Required!`，DOM 里一个视频都没有。
本项目的核心原理就是「用真实的、能过 Cloudflare 的浏览器」，
换成无头等于把这个原理也去掉。所以保留真实浏览器内核，只是让它不可见。

配套的收尾：App 退出时先请求后端 `/api/shutdown`，
由后端调用 `stop_browser()` 把这个**隐藏的**浏览器收掉
（用户看不到它，也就没法自己关，留着会白占内存）。
`stop_browser()` 只关命令行里带我们专用 profile 的 Chrome，不动用户日常的浏览器。

用不到的端口可以覆盖：

```powershell
$env:HANIME_CDP_PORT = "9333"
$env:HANIME_BROWSER  = "D:\Chrome\chrome.exe"   # 指定浏览器
```

### 打包时踩过的三个坑

1. **Windows 控制台默认 GBK，print 中文/日文标题会崩。**
   标题里出现「・」(U+30FB) 这类 GBK 编不了的字符时，
   `print` 直接抛 UnicodeEncodeError，接口变成 500。
   实测 16 次请求挂了 14 次。
   → `run_backend.py` 的 `force_utf8_output()` 在启动最前面把
   stdout/stderr reconfigure 成 UTF-8，必须在任何 print 之前调用。

2. **Chrome 111+ 拒绝带 Origin 头的 CDP WebSocket 连接**，
   返回 `403 Rejected an incoming WebSocket connection`。
   websocket-client 默认会带 Origin。
   → `_get_socket()` 里必须传 `suppress_origin=True`。

3. **PyInstaller 看不到字符串导入的模块。**
   uvicorn 的 `main:app`、以及我们自己的 `cdp` / `parser` 包，
   都要用 `--hidden-import` / `--collect-submodules` 明确列出，
   否则打出来的 exe 一跑就 ModuleNotFoundError。

### 端口

| 用途 | 默认 | 覆盖方式 |
| --- | --- | --- |
| 后端 | 8000 | `--port`（exe）或 `HANIME_BACKEND_PORT`（前端） |
| 调试浏览器 CDP | 9222 | `--cdp-port` 或 `HANIME_CDP_PORT` |

前端里不再写死地址，统一走 `lib/controllers/app_config.dart`。

---

这个目录里的东西**不是** API 的一部分，只是开发时手动跑的小工具。
删掉它们不影响 HanimeViewer 后端运行。

## 里面的文件

这些都是**可复用的验证工具**，用来一键复现「CDP → 网页 → Parser」这条链路，
改动后端后跑一下就能确认没破坏东西。

| 文件 | 用途 |
| --- | --- |
| `test_cdp.py` | 最小 CDP 验证：打印当前标签页的标题和网址 |
| `test_login.py` | 查看当前标签页的登录状态相关信息 |
| `test_parser.py` | 对当前页面跑一遍 Parser |
| `test_search.py` | 打开搜索页并解析结果 |
| `test_watch.py` | 打开某个视频详情页并解析 |
| `test_playlists.py` | 解析用户的播放清单 |
| `check_quality.py` | 检查清晰度列表 |
| `check_tags.py` | 检查标签分组和 `broad` 广泛匹配 |

## 已删除的早期文件

下面这些文件原本也在这里，已确认**没有任何代码或文档引用**，属于早期开发的临时产物，
于 2026-09-26 删除：

| 文件 | 原用途 | 删除原因 |
| --- | --- | --- |
| `video_detail_test.html` | 详情页 HTML 快照（217 KB） | 离线调 Parser 用；Parser 已改从实时页面验证，且快照对应的是旧版网站结构 |
| `playlists_test.html` | 播放清单页快照（132 KB） | 同上 |
| `playlist_test.html` | 播放清单页快照（38 KB） | 同上 |
| `check_category.py` | 一次性摸清分类页结构 | 结构已摸清并写进 Parser，探查脚本不再需要 |
| `check_filters.py` | 一次性摸清筛选参数 | 同上 |
| `check_filters2.py` | 同上（第二版） | 同上 |
| `check_genre.py` | 一次性摸清 genre 页面 | 同上 |
| `check_sections.py` | 一次性摸清首页栏目结构 | 同上 |

以及项目根目录的 `cdp_test.py`：最早的 CDP 原型脚本（直接 requests + websocket 调 CDP），
功能已被 `backend/cdp/chrome.py` 和 `backend/dev/test_cdp.py` 完全覆盖。

这些文件都在 git 历史里，需要时可以用 `git show <commit>:<path>` 取回。

## 登录功能（backend/auth.py）

登录不是客户端做的，而是**在用户自己的调试 Chrome 里**完成：
后端打开 `https://hanime1.me/login`，填入邮箱密码并点击「登入」，
session cookie 由浏览器自己保存，之后所有抓取请求自动带上登录态。

这样做的好处：

- CSRF token（`_token`）由页面自己提供，不用猜
- 客户端不保存 cookie，也不在本地保存密码
- 点赞、储存、个人主页这些**依赖登录态**的页面能直接抓到

### 踩过的坑（改这块前务必看）

1. **不能用 `form.submit()`。**
   登录表单里有一个 `<button name="submit" type="submit">登入</button>`，
   这个命名元素会把 `form.submit` 方法**遮蔽**掉，
   调用时会得到 `TypeError: form.submit is not a function`。
   更坑的是 CDP 的 `Runtime.evaluate` 遇到 JS 异常时**不返回 value**，
   所以后端只会看到 `None`，报出来的错是「登录表单结构异常（None）」，
   完全看不出真正原因。
   → 现在改成 `submitBtn.click()`，也更接近用户真实操作。

2. **登录失败页面的错误文字是 `auth.failed`**（Laravel 的提示 key）。
   用它来判断「密码错了」可以立刻返回，
   否则要干等 30 秒超时（实测从 32 秒降到约 1.9 秒）。

3. **不要信 `data-target="#signUpModal"` 这个判断单独成立。**
   未登录时点赞/储存按钮带这个属性、点击只弹注册窗；
   登录后服务端会渲染出不带它的版本。`video_action()` 会先检查这一点，
   发现仍是 `needs-login` 就返回「登录状态已失效」，而不是假装成功。

### 个人中心（用户主页）的结构

个人中心首页（`/user/{id}`）是**服务端渲染**的一张长页面，结构是：

```
<div class="tab-content-container">
  <div class="tab-index-rows-wrapper">        <- 一个 tab 一个
    <a class="horizontal-row-title" href=".../histories"><h3>觀看紀錄<div>查看更多</div></h3></a>
    <div>                                      <- 和标题是**兄弟**节点
      <div class="home-rows-videos-wrapper">
        <a class="video-link" href="...">      <- 每段 10 个左右
```

几个必须注意的点（都踩过）：

1. **标题和卡片是兄弟节点**，要用 `find_next_sibling`；
   用 `find_parent` 会一路上溯到包含全部 4 个栏目的大容器，
   结果每个栏目都报「40 个卡片」。
2. **标题文字里混着「查看更多」**，要先把这个 `div` 删掉再取文字
   （用复制出来的节点处理，别改原 soup）。
3. **「播放清單」栏目里的卡片不是影片**：它的 `href` 是
   `/playlist?list=xxx`，数量写在 `.stats-container` 里，
   要单独归到 `playlists`。

### tab 页和它的分页

`/user/{id}/histories`、`/likes`、`/saves`、`/playlists` 这些页面：

- 真正的内容在一个
  `<div class="specific-tab-view home-rows-videos-wrapper">` 里
- **每页 60 条**，分页链接是 `?page=N`
- 必须用 `get_tab_videos()` / `get_tab_playlists()` 限定在这个容器里解析。
  直接全页抓会出问题：这些页面**同时携带个人中心首页那 4 个栏目段的预览卡片**，
  实测 `histories` 页面上共 60 个 `a.video-link`，全页抓得到的数字看着"对"
  但其实是混在一起的。

实测页数（`get_total_pages()`）：histories 30 页、likes 21 页、
playlists 8 页、saves 1 页。所以客户端必须有翻页，
否则只能看到历史记录的第一页。

### 登录相关的接口

| 接口 | 说明 |
| --- | --- |
| `GET /api/account` | 当前登录状态（带 15 秒缓存，`?force=true` 强制刷新） |
| `POST /api/login` | body `{"email","password"}`，在浏览器里提交登录 |
| `POST /api/logout` | 让浏览器登出 |
| `GET /api/user/{id}` | 用户主页，`?tab=histories/saves/likes/playlists/uploaded&page=N` |
| `GET /api/user/{id}/home` | 个人中心首页的栏目段（每段最多 10 个） |
| `POST /api/video/{id}/action` | body `{"action":"like"/"unlike"/"save"}`，在浏览器里真实点击 |

点赞/储存成功后记得清 `detail_cache` 和 `user_cache`，
否则前端还会读到旧的点赞数。

### 用户主页的两个细节

- 页面标题的分隔符是 `\xa0-`（不换行空格）而不是普通的 `" - "`，
  直接 split 会得到一长串带后缀的名字。
- 页面上有多张头像图（导航 logo、默认头像），
  真正的用户头像要认 `src` 里含 `/image/avatar/` 且不含 `user_default_image` 的那张。

### 账号数据隔离（重要）

观看历史、搜索记录、播放进度、播放清单都必须**跟着账号走**。
早期版本用的是全局 key，导致「登录账号2，看到的还是账号1的数据」。

#### 前端：本地数据按账号加前缀

规则见 `lib/controllers/account_scope.dart`：

| 数据 | key |
| --- | --- |
| 观看历史 | `u_{userId}_watch_history` |
| 搜索记录 | `u_{userId}_search_history` |
| 播放进度 | `u_{userId}_video_position_{videoId}` |
| 未登录 | `guest_...` |

三个配套点，缺一个都会漏：

1. **换账号要丢掉已缓存的页面**。
   `MainShell._pages` 会把页面缓存在 IndexedStack 里，
   不丢的话切回观看历史还是旧账号的内容。
   见 `_resetPagesIfAccountChanged()`（同时会清 `AppCache`）。
2. **整个壳要跟着登录状态重建**。
   `MainShell.build()` 外面套了 `ValueListenableBuilder<AccountInfo>`。
3. **主题（明暗模式）故意不跟账号走** —— 那是这台设备的使用习惯。

#### 后端：播放清单不能写死账号

`/api/playlists` 以前写死 `https://hanime1.me/user/715321/playlists`
（早期测试账号）。现在改成用 `auth.get_account()` 拿当前登录账号，
未登录直接返回 401。

#### 登录检测必须多线索（踩过的坑）

只靠导航栏的 `#user-modal-trigger` 不可靠：实测在
`/user/{id}/playlists` 这类页面上它的 **href 是空的**，
于是明明登录着却被判成未登录，播放清单接口就 401。

现在 `_ACCOUNT_PROBE` 一次采集多个线索：

1. 页面上有「登出」入口（`.user-modal-link` 里含「登出」）—— 最强信号
2. `#user-modal-trigger` 的 href 指向 `/user/{id}`
3. 当前 URL 本身就是 `/user/{id}/...`
4. 页面里同时出现 `/user/{id}/saves` 和 `/user/{id}/edit`

**不要**用头像容器的 `innerText` 当用户名：那里是图标文字，
实测会拿到 `arrow_drop_down`、`cast` 这种垃圾值。
用户名改为顺着 id 去个人主页标题里取（`_lookup_username`，有缓存）。

#### 验证结果

| 账号 | 个人中心栏目 | 播放清单 |
| --- | --- | --- |
| 715321（账号1） | 4 个 | 60 个 |
| 2150661（账号2） | 1 个（觀看紀錄） | 0 个（该账号确实没有） |

两个账号看到的数字不同 —— 这就是隔离生效的直接证据。

### 关于「内置浏览器」的结论（不要再试无头模式）

用户希望不要外挂 Chrome、改成客户端内置浏览器隐藏运行。**做不到**，实测结论：

| 方案 | 结果 |
| --- | --- |
| 直接 HTTP 请求 | 200 但只有约 20KB 空壳，无 `.video-link` |
| `--headless=new` | `Attention Required! \| Cloudflare`，`a.video-link` = 0，页面 4KB |
| `--headless=new` + 真实 UA | 同上（UA 不解决问题） |
| **有头 + 窗口隐藏** | ✅ 正常拿到数据 |

原因：本项目的核心原理就是「用真实的、能过 Cloudflare 的浏览器」，
去掉有头模式等于把这个原理也去掉。

所以现在的方案是**保留真实浏览器内核，但让它完全不可见**：
`--window-position=-32000,-32000` + Win32 `ShowWindow(SW_HIDE)`。

### 侧边栏「观看记录」与个人主页一致

两者现在走**同一个接口**：

```
/api/user/{id}?tab=histories&page=N
```

- 登录时：读官网的觀看紀錄（和「个人主页 → 观看记录」是同一份数据），每页 60 条要翻页
- 未登录时：退回本地记录（`guest_watch_history`），此时才显示「清空历史」按钮
- 官网记录带的是 `duration`/`views`，本地记录带的是 `brand`/`last_watched`，
  卡片里两种字段都要兼容

### 播放清单页码

`playlist_page.dart` 以前写死 `_totalPages = 8`，还有一句
「不足 8 也按 8 算」的下限 —— 结果只有 1 页的账号也显示 8 页，
点第 2 页直接空白。

现在完全用服务端返回的 `total_pages`，并且
**只有 `_totalPages > 1` 且有数据时才显示分页条**。

实测：账号 715321 是 60 个 / 8 页（显示分页），
账号 2150661 是 0 个 / 1 页（不显示）。

### 新番预告

侧边栏新增，对应官网 `search?genre=新番預告`。

⚠️ **genre 必须用繁体「新番預告」**，简体「新番预告」返回 0 条
（实测）。值定义在 `new_release_page.dart` 的 `NewReleasePage.genre`。

### 登出必须是 POST（踩过的坑）

官网的登出是一个 **POST 表单**：

```html
<form action="https://hanime1.me/logout" method="POST">
  <input type="hidden" name="_token" value="...">
</form>
```

早期版本用 `GET /logout`，**根本不会登出**。这个 bug 的后果很隐蔽：

```
GET /logout 没登出
  -> 浏览器仍是登录态
  -> 再点「登录」时打开 /login
  -> 服务端发现已登录，直接重定向走（实测落到 404 的 /home）
  -> 等不到登录表单 -> navigate_and_wait 超时
  -> 界面报「打不开登录页，请确认调试 Chrome 正在运行」
```

报错信息和真正的原因（没登出）看起来毫无关系，很容易往「浏览器挂了」方向排查。
正确做法见 `auth.logout()`：找到登出表单、原样 POST 提交它的字段。

另外两点：

1. **登出后要重新加载页面再判断状态**。官网导航是 SPA，
   登出后旧 DOM 里还留着用户菜单，不刷新会把 `_read_account` 骗过去。
2. **`login()` 会先检查并主动登出**。这样即使登出没生效，
   重新登录也不会卡在「打不开登录页」上，而是自己先清理干净。

实测：修复前 `/login` 导航 30 秒超时（落到 404），
修复后 **0.98 秒**就拿到登录表单。

## ⚠️ 图标"消失"的坑：Flutter 图标树摇不可靠

**现象**：点赞后大拇指、播放清单右上角书签都**看不见**（功能正常，
就是没图标）。第一反应会以为是颜色和背景撞了 —— 其实不是。

**真正原因**：Flutter release 构建默认会 tree-shake 图标字体
（只保留代码里用到的图标，字体从 1.6MB 缩到几十 KB）。
这个机制**不可靠**，实测踩了两次：

1. **增量构建复用过期结果** —— 后来新加的
   `Icons.thumb_up` / `Icons.bookmark` / `Icons.bookmark_border`
   根本不在字体里，渲染成**空白**。
2. **即使全量 `flutter clean` 重建，它也会漏图标** ——
   实测 `Icons.arrow_drop_down`（筛选栏的下拉箭头）就没被收进去。

**怎么确认**：解析发布包里那个字体的 `cmap`，看目标码位在不在。
当时字体只有 **67 个字形**，缺了 `thumb_up`(0xe65b)、`bookmark`(0xe0f1)、
`bookmark_border`(0xe0f4) 等。

**修复**：打包时加 `--no-tree-shake-icons`（见
`frontend/scripts/package_windows.ps1`），字体变成完整的 8667 个码位、
1607KB。发布目录从 44.5MB 变成 46.2MB —— 多 1.7MB 换"图标不会再无故消失"，
很划算。

**排查脚本**（很有用，建议保留）：
把源码里的 `Icons.xxx` 和字体实际含有的码位对一遍，
能立刻发现哪个图标是空的。

## ⚠️ 列表"不跟着变"的坑：常驻页面的旧 state

**现象**：影片 1 存进「稍后观看」→ 进详情页取消储存 → 返回「稍后观看」，
影片 1 **还在**（官网已经没了）。多进一次页面才正常。

**为什么**：这类页面是**常驻**的 ——
侧边栏页面放在 `IndexedStack` 里、个人主页会被压在详情页下面，
它们不会因为"返回"就重新加载。详情页改了数据只发生在后端，
常驻页面还拿着自己的旧 `state`。

**修复分两层**：

1. **`AppCache` 前缀要对得上**。缓存 key 是
   `AppCache.buildKey('/api/user/{id}', {...})` → `'/api/user/...'`。
   退出登录那里原本写的是 `'user_'` / `'video_detail_'`，
   **两个都匹配不到任何真实 key**（`video_detail_` 早就不用了），
   等于没清。

2. **用一个全局版本号 `DataRevision`（`lib/controllers/data_revision.dart`）**：
   - 凡是会改变列表内容的操作，成功后 `DataRevision.bump()`；
   - 关心的页面 `addListener`，收到变化就**静默刷新**。

   「静默刷新」= 保留屏幕上现有内容、**不显示整页转圈**，
   后台取到新数据后原地替换（`_load(..., silent: true)`）。

这样既"及时更新状态"（别处一改，这里就跟着变），
又"快速缓存加载"（有缓存先出内容，不白屏）。

当前接上的是：影片详情页（储存/取消储存/新建清单）、
播放清单详情页（收藏）、个人主页、侧边栏播放清单页。

## ⚠️ 「稍后观看」不能按 list_id 查（假失败 → 图标空心）

**现象**：影片存进「稍后观看」后，进详情页储存图标是**空心**的，
但官网上明明是已储存。反过来取消储存也一样对不上。

**根因是一条链**：

1. 储存表单里「稍后观看」的 checkbox `id` 是 **`save`**（不是数字 id），
   而 `/playlist?list=save` 是个 **404 页面**。
2. 复核代码当时拿 `/api/playlist?list_id={id}` 去查影片在不在清单里 ——
   查「稍后观看」永远返回 0 部影片。
3. 于是**保存到「稍后观看」被判成失败**（`verified: false`）。
4. `/api/video/{id}/action` 只在 `ok` 为真时清 `detail_cache`，
   假失败就**没清缓存**。
5. 再进详情页拿到的是操作前的旧响应 → `saved=false` → **图标空心**。

**修复**：复核改成**重新加载影片页、按清单名字读 checkbox 状态** ——
那才是权威答案，而且「稍后观看」这种特殊清单一样适用。

另外加了个保险：`save` / `unsave` 即使复核说"没生效"，
也**照样清掉详情缓存**（官网可能已经改了，只是我们没确认到）。
代价最多多抓一次页面，但不会再出现"状态对不上"。

**教训**：不要让复核逻辑依赖一个可能不存在的 URL；
能让复核和被复核用同一份权威数据（这里是同一个表单）就别绕路。

## ⚠️ 卡片尺寸：全站只留一套算法

**问题**：同一个视频，在首页、搜索结果、分类页、个人主页里卡片大小不一样。

**原因**：同一张横版卡片被抄了 4 份，网格参数各不相同：

| 位置 | 间距 | 文字区高度 | 列数规则 |
|---|---|---|---|
| 首页 | 16 | 74 | 按宽度 1~6 列 |
| 搜索结果 | 12 | 92 | 按宽度 1~6 列（竖版另有 1~8） |
| 分类页 | 16 | 92 | 按宽度 1~6 列 |
| 个人主页 | 14 | — | `maxCrossAxisExtent: 240` + 长宽比 0.95 |
| 播放清单页 | 14 | — | 自己一套 1~5 列 + 长宽比 0.95 |

**修复**：抽出 `frontend/lib/widgets/video_card.dart`，以**首页那套为准**：

- `videoCardColumns(width)` / `videoCardMetrics(...)` —— 唯一一份尺寸算法；
- `VideoCard` —— 唯一一张横版卡片；
- `VideoCardGrid` —— 唯一一个网格（首页 / 搜索 / 分类直接用它）。

**关键点**：留白算在谁身上不影响结果。
`available = constraints.maxWidth - 自己的 padding - 间距 × (列数-1)`，
而 `constraints.maxWidth` 已经把父容器的留白扣掉了，
所以「父容器留 24 + 自己不留」和「父容器不留 + 自己留 24」结果完全一样。
`test/video_card_test.dart` 里专门锁了这条不变式。

**没动的**：竖版栏目（新番预告）保持自己那套列数；
观看记录 / 播放清单详情是**列表行**不是网格卡片，
而且行里有观看进度条之类的信息，换成 `VideoCard` 会丢东西，所以没改。

## 🚀 取数提速：不导航，直接在常驻页里 fetch（快 2 倍）

**这是目前最大的一次提速，改 `fetch_html` 前务必先读。**

原来的做法：每次请求都 `Page.navigate` 到目标页 → 等 DOM 稳定 → 取 HTML。
整页导航要拆掉旧页面、重建 DOM、再加载图片和脚本。

现在的做法：浏览器**常驻**在一个 hanime1.me 页面上，
请求时只在页面里 `fetch()` 一次目标 URL，把 HTML 取回来解析。

### 实测（同一台机器、同一批页面）

| 页面 | navigate（旧） | 常驻页 fetch（新） |
| --- | --- | --- |
| 搜索结果 | 1304 ms | 675 ms |
| 分类列表 | 1040 ms | 512 ms |
| 影片详情 | 1137 ms | 554 ms |
| 播放清单 | 1123 ms | 417 ms |
| **平均** | **1151 ms** | **540 ms（快 2.13 倍）** |

发布版冷取数实测：搜索 792ms / 详情 849ms / 播放清单 480ms。

### 为什么结果可信

本站页面是**服务端渲染**的（Laravel Blade），HTML 里本来就有全部内容。
逐项对比过三种取法的解析结果，**完全一致**：

- 影片卡片数（61 / 2 / 0）、播放地址、清晰度列表（1080p/720p/480p）、
  互动状态（liked / saved / 清单名字）。

### 为什么不改用普通 HTTP（对标项目的做法）

`misaka10032w/Han1meViewer` 是 **Kotlin + OkHttp + Jsoup**，纯 HTTP 不碰浏览器，
只把 WebView 当 Cloudflare 验证的兜底。我们也验证过：拿到 `cf_clearance`
之后普通 HTTP 确实能返回真实页面，速度也差不多（约 690ms）。

**但没用它，因为有两个坑：**

1. **语言会变**。浏览器发的是简体偏好，普通 HTTP 返回的是**繁体**
   （清单名变成「稍後觀看」，而系统里到处用的是「稍后观看」）——
   按名字储存/取消储存会直接失效。
2. **播放地址不一样**。浏览器拿到 `408116-sc-720p.mp4`，
   普通 HTTP 拿到 `408116-720p.mp4`，是两条不同的 CDN 链接。

`fetch()` 走的是同一个浏览器、同一份 cookie、同一套语言，
**没有任何语义差异**，所以选了它。

### 兜底

`fetch_document` 失败时（浏览器不在本站 / 拿到 Cloudflare 拦截页 / 非 200），
`fetch_html` 会自动退回整页导航，不会因为提速而拿不到数据。

需要整页导航的场景仍然保留：登录、点赞、储存（这些要在真实 DOM 上操作）。

## 📁 应用数据目录与下载目录

**数据全部放在程序根目录下**（不再用 `%USERPROFILE%\Downloads`）：

```
<程序根目录>\
├─ backend\  frontend\  ...      程序本体
└─ HanimeData\                   ← 应用数据目录
    ├─ settings.json             设置
    ├─ downloads.json            下载记录
    └─ Downloads\                ← 默认下载目录（可在设置页改）
```

下载文件夹刻意**不直接放在程序根目录**，免得程序文件和下载文件混在一起。
`HanimeData/` 已经加进 `.gitignore`。

### 「程序根目录」怎么定位（`program_root()`）

- 打包运行：可执行文件所在目录
- 源码运行：`backend/main.py` 的上一级

**关键一步**：打包出来的 exe 常常躺在
`frontend\build\windows\x64\runner\Release\` 里 —— 那个目录会被重新编译清掉，
数据放进去迟早丢。所以会**往上找真正的项目根**：认 `.git`，
或者认 `backend` + `frontend` 同时存在。找不到才退回 exe 所在目录。

### 老数据会自动搬家

启动时 `migrate_legacy_data()` 会把老位置
（`%USERPROFILE%\Downloads\Hanime`）的 `settings.json` 和 `downloads.json`
**复制**过来。

- **不动下载好的影片**：记录里存的是绝对路径，老文件在原地照样能打开、能播放，
  没必要为此挪几个 GB。
- 还会把设置里**指向老位置**的 `download_dir` 删掉，让新默认值生效
  （用户要的就是"默认下载位置改到程序根目录下"）；
  用户自己改过的其它路径保持不动。

## 🔧 下载记录的几个细节

下载记录**落盘**，所以重启后端甚至重启客户端之后，「下载」页里以前下过的还在。
记录里刻意**不存 `url`** —— 官网的视频地址带签名会过期，
留着只会让下次重启后拿失效链接去重试。

上次没下完就退出的话，状态会被标成 `interrupted`；文件被手动删掉的标成 `missing`。

**踩过的坑**：
- `settings.json` 用的是 `RLock`。`save_settings` 会在持锁时调用
  `load_settings`，普通 `Lock` 会自己把自己锁死（写设置直接卡住不返回）。
- 文件名清理要先处理 **`\xa0`（不换行空格）**。官网标题是
  `...[中文字幕]\xa0-\xa0H動漫/裏番/線上看`，按普通空格找 `" - H動漫"` 永远找不到，
  站点后缀就会留在文件名里。

## 🔊 音量：记住还不够，必须**设到播放器上**

**现象**：退出前设成静音，重启后进视频 —— 图标是静音，但**照样有声音**。

**原因**：`_volume` 从存档读出来了（所以图标对），
但 `_initializePlayer` 里初始化完播放器**没有调 `setVolume`**。
播放器停在默认满音量，只有切画质 / 点静音 / 拖滑块时才同步。

**修复**：`await controller.initialize()` 之后立刻 `await controller.setVolume(_volume)`。

> 顺带一提：这个 bug 影响**所有**非满音量的存档，不只是静音。

## 🚪 关闭窗口：4~5 秒才关掉

**现象**：点右上角关闭，窗口杵在那里四五秒才消失。

**排查**（临时往临时目录写带时间戳的日志）：Dart 侧收尾其实只用了 **5ms**，
剩下 4.7 秒全在 `windowManager.destroy()` **之后**。

**原因**：`destroy()` 只是往消息队列丢一个 `WM_QUIT`，
**窗口本身并没有被销毁**，进程退出时还得额外拆一遍。

**修复**：改成「先 `setPreventClose(false)`，再 `windowManager.close()`」——
走正常关窗路径，窗口被真正销毁、引擎收到 `OnDestroy`。

| | 窗口消失 | 进程退出 |
| --- | --- | --- |
| `destroy()` | 0.06 s | **4.74 s** |
| `setPreventClose(false)` + `close()` | 0.06 s | **0.20 s** |

另外进关闭流程时先 `windowManager.hide()`，让窗口立刻从屏幕上消失
（收尾那几十毫秒用户在看不见的情况下过去）。
重复收到 close 事件用 `_closing` 标志挡掉。

**注意**：`BackendLauncher.stop()` 现在**只把请求发出去就返回**，
不再轮询等浏览器收尾。后端是独立进程，收到 `/api/shutdown` 后会自己
起线程收掉隐藏的 chrome 再 `os._exit(0)`；以前那种「等完再 `taskkill /T /F`」
反而会**打断**它的收尾，留下 13 个 chrome.exe。

## 🧯 一个坏设置值不该连累全部

`AppSettings.load()` 以前整个包在一个 `try` 里，而且用
`prefs.getDouble()` 直接取。但存档 JSON 里的 `0` 是 **int**，
`getDouble` 遇到 int 会**抛类型错误** —— 于是整个 `load()` 中断，
**所有**设置一起被带回默认值。

现在：每一项单独读、单独兜底，并且用宽容的读取器
（`_readDouble` / `_readInt` / `_readBool` / `_readString`），
int、double、字符串都能认。

## 🔊 音量提示要画在「播放器」里，不是「页面」里

**现象**：窗口化时音量提示跑到整页中间，跟播放器对不上。

**原因**：详情页的 `PlayerShortcuts` 包的是**整页**
（播放器 + 操作条 + 简介 + 相关影片），所以它的正中根本不是播放器的正中。
全屏页看起来正常，只是因为那一页整个就是播放器。

**现在的分工**：

- `PlayerShortcuts` **只做按键分发**，音量变化通过 `onVolumeChanged` 报出去；
- 页面自己持有 `VolumeToastController`，把 `VolumeToast` 用
  `Positioned.fill` + `Center` 放进**播放器自己的 Stack** 里
  （而且要是最后一个子节点，否则会被画面盖住）。

这样提示天然跟着播放器的位置和大小走 —— 窗口化、全屏、拖边框都不会跑偏；
`VolumeToast` 内部还按播放器宽度做了 0.85~1.7 倍的缩放，
小窗口不显挤、全屏不显小。

## 🅷 程序图标（按图**绘制**，不是贴图片）

原图只有 **33x38 像素**，直接当图片用、放到启动页那么大就糊了。
所以按量出来的数据重画，放到多大都是矢量边缘。

### 界面里的 logo：只有红色的 H

`frontend/lib/widgets/hanime_logo.dart`（`CustomPainter`）

原图量出来的数据：

| 项目 | 值（原图坐标） |
| --- | --- |
| 画布 | 33 x 38 |
| 底色 | `#2C2D32`（铺满整块，四角直角） |
| 字母 | 红色 `#DB202B` 的大写 **H** |
| H 范围 | x 10..23、y 3..34（即 **13 x 31**，很窄很高） |
| 笔画宽 | 4.6（H 宽的 0.354 倍） |
| 横杠 | y 14..19 |

（数据是把原图逐像素扫出来数的；左竖 5px、右竖 4px 是抗锯齿造成的半像素差，
取 4.6 让两边对称。）

**界面里不带那块底**，只要红色的 H（`withBackground: false`，默认）：
控件尺寸就是 H 自己的框（13:31），不带无谓的空白。

### ⚠️ 三个矩形必须**合成一条路径**再填，不能分三次 `drawRect`

**现象**：H 中间那一横的两端比两竖"鼓"出来一点点。

**原因**：竖笔和横杠在两端是**重叠**的。分三次 `drawRect` 时，重叠处的
抗锯齿边缘像素会被**合成两次**：

```
合成 alpha = 1 - (1-a)²  >  a        （a=0.55 时 0.80 > 0.55）
```

于是横杠那一行的边缘像素比竖笔那一行更"实"（实测 R 值 209 vs 175），
看起来就像横杠凸出去了一截。

**修复**：三个矩形 `addRect` 进同一个 `Path`，`drawPath` 只填一次 ——
一条路径只光栅化一次，每个像素只有一个覆盖率。

> 这是那种"widget 树完全正常、只有看像素才发现"的 bug。

`test/hanime_logo_test.dart` 里有一条**逐像素**的回归测试：
把图标渲染到 `RepaintBoundary` 再读像素，比较"竖笔那一行"和"横杠那一行"
在同一列的颜色，必须**完全相等**。把 `drawPath` 改回三次 `drawRect`
这条测试立刻失败（`Expected: <175>  Actual: <209>`）。

**写这条测试的坑**：一开始用 `height: 62`，算出来 H 宽正好 26.0 ——
**边缘落在整数像素上，抗锯齿根本不出现**，测试永远是绿的。
所以要把 `devicePixelRatio` 固定成 1.0、并选一个宽度带小数的尺寸（80 → 33.55）。

| 位置 | 尺寸 |
| --- | --- |
| 侧边栏顶部 | `SidebarLogo` —— 离顶 29、高 30（中心 y=44），在 88 宽的侧边栏里居中 |
| 启动页 | `HanimeLogo(height: 80)` —— 同时去掉了加载转圈和它下面那行字 |

**侧边栏那个图标的位置**调过好几次，最后是量着截图定的
（用户在原图上圈了一块，量出那块的中心在 y=44）。两个坑：

1. **放在 `Column` 里会被裁一半**。它要比 `NavigationRail` 的起点更靠下，
   而导航的背景 `Material` 是后画的，会把图标下半截盖掉 ——
   实测只画出 12x15（少了 15px）。所以它是 `Stack` 里的 `Positioned`，
   **必须排在导航后面**。
2. 想只下移图标、又不想把整条导航一起推下去（顶部会空一片），
   试过 `Transform.translate` —— 位置对了但**照样被盖**（同一个原因）。
   最后还是得用 `Stack`。

抽成了 `SidebarLogo`（`top` / `size` 都是公开常量），
`test/hanime_logo_test.dart` 里锁住：完整高度、横向居中、
比标题栏那一条低、且不压到第一个导航项（y≈105）。

### 程序图标（exe / 任务栏）：圆角黑底 + 红 H

`frontend/windows/runner/resources/app_icon.ico`

用 `Pillow` 生成（脚本思路见下），**近黑 `#121214` 圆角矩形**（圆角半径 22%）
+ 居中的红 H（高度占 64%），一次写入 7 个尺寸：
16 / 24 / 32 / 48 / 64 / 128 / 256。做法是 4 倍超采样再 LANCZOS 缩小，
小尺寸下边缘才不糊。

**两个坑**：

1. **`.ico` 不是 CMake 跟踪的依赖** —— 换了图标直接 build 不会重新编译资源脚本，
   exe 上还是旧图标。改完要 `touch` 一下 `windows/runner/Runner.rc` 再 build。
2. 任务栏图标走的是**窗口类图标**（`win32_window.cpp` 里
   `LoadIcon(hInstance, MAKEINTRESOURCE(IDI_APP_ICON))`，
   而 `Runner.rc` 把 `IDI_APP_ICON` 指向那个 .ico）。
   所以**不用**在 Dart 里再调 `windowManager.setIcon()`。

验证方法：`[System.Drawing.Icon]::ExtractAssociatedIcon(exe路径)` 能把 exe 里
嵌的图标抠出来，确认真的换掉了。

`test/hanime_logo_test.dart` 里挡了一条：**不许用 `Image`**（不许图省事换成位图），
另外锁住两个宽高比（H 的 13:31、带底的 33:38）和侧边栏居中。

### 顶部那 38px：**按页面**决定让不让

一开始的做法是给 `MediaQuery` 注入 38px 顶部留白，让所有页面的 `AppBar`
自动下移 —— 结果每个页面顶上都是一条空白。后来一刀切地全去掉，
又变成顶部通栏的页面和右上角三个窗口按钮叠在一起。**两种一刀切都不对**。

**为什么当初要让位**：标题栏的拖动区是 `HitTestBehavior.opaque` 的，
把窗口最顶上一条变成了"点击黑洞"，页面顶部的按钮（详情页的返回、
个人主页的返回…）在那一带就点不到了，只能整体下移躲开。

**现在**：拖动区改成 `HitTestBehavior.translucent` —— 它**仍然收得到
指针事件**（窗口照样能拖），但 `hitTest` 返回 `false`，所以下层内容**也**
收得到，点击穿得过去。于是"要不要让位"变成一个**纯视觉**问题：
只要顶部**靠右**没有内容，就不用让。

判断写在 `_MainShellState._topInsetFor`，逐页实测过：

| 页面 | 顶部靠右有内容吗 | 顶部留白 |
| --- | --- | --- |
| 首页 | 有（"最新上市 / 查看更多"那一行） | 38 |
| 观看记录 | 有（第一行的卡片一直顶到右边） | 38 |
| 播放清单 | 有（同上） | 38 |
| 新番预告 | 有（网格第一行） | 38 |
| 下载页 | 有 | 38 |
| 搜索页 | 没有（搜索框居中，宽最多 520，离右边很远） | 0 |
| 设置页 | 没有（顶部只有左边一段说明，第一张卡片从 y≈95 才开始） | 0 |

窄窗口不用管：那里有 `AppBar`（40 高），内容本来就从 40 开始。

> ⚠️ **双击最大化不能用 `GestureDetector.onDoubleTap`**：
> `DoubleTapGestureRecognizer` 会占住手势竞技场，把下面按钮的点击一起吞掉。
> 实测：`translucent` + `onDoubleTap` → 下层按钮点不到；
> 去掉 `onDoubleTap` → 点得到。所以双击是**自己用 `Listener` 数的**
> （400ms 内、同一位置按下两次 → `toggleMaximize()`）。
> 回归测试见 `test/custom_title_bar_test.dart` 的「拖动区下面的按钮仍然点得到」。

### 页面自己的 `AppBar` 也在 y=0，所以 `actions` 会和窗口按钮打架

`AppBar` 顶到 y=0 之后，它的 `actions`（垂直居中在 56 高的 toolbar 里，
也就是 y≈28）正好落在窗口按钮那一条（y 0..38）里，而且都靠右 ——
**必然重叠**。三个页面都改成「挪到下面一行的右端」：

| 页面 | 原来的 `actions` | 挪到哪 |
| --- | --- | --- |
| 个人主页 | 刷新 / 退出登录 | **标签页那一行**的右端（那行本来就空着，零成本） |
| 播放清单详情页 | 收藏书签 | AppBar 的 `bottom`：一行 40 高，**左边显示"共 N 部"**、右边是书签 |
| 影片详情页 | 无 | —— |

播放清单那页本来没有可以借用的行，所以给 AppBar 加了一个 `bottom`
（`PreferredSize` + 40 高，`IconButton` 用 `VisualDensity.compact`
压到 40 以内，尽量少占竖向空间）。书签落在 y≈56~96，
**严格低于窗口按钮的 y 0..38**，所以既贴右边又不会被压住。

> 判断标准就一句话：**要放在 y ≥ 38 的地方**。
> 页面顶到 y=0 之后，AppBar 那 56 里的任何位置都在窗口按钮的范围内。

### 侧边栏的位置要跟着走

内容区不再统一让位之后，`Scaffold` 的 body 也不再吃那段 `MediaQuery`
padding，**整个侧边栏跟着上移 38px**。侧边栏里的程序图标是 `Positioned`
绝对定位，导航的位置必须跟它绑在一起 —— 用
`SidebarLogo.reservedHeight`（= top 29 + size 30 + 20），
不然"首页"那一项会跑到图标上面去（图标 y 29..59、首页 y 52..82）。

### 去掉的页内标题栏

- 新番预告的「图标 + 新番预告 + 刷新」整行删掉（刷新改成**下拉刷新**）
- 观看记录的「观看记录（与个人主页一致）」那行删掉（「清空历史」保留）
- 详情页发行商头像上方那个**重复**的「点赞率」`InfoChip` 删掉
  （下面「点赞」按钮右边本来就带着同一个数字）

## 🔀 首页栏目排序

设置页 → **首页 → 栏目排序**：按住把手上下拖，视频跟着栏目一起走。

### 存的是**栏目名**，不是下标

网站的栏目会增删（现在是 12 个：最新上市 / 最新上傳 / 裏番 / 泡麵番 /
Motion Anime / 3DCG / 2.5D動畫 / 2D動畫 / AI生成 / MMD / Cosplay / 他們在看）。
存下标的话网站一改就整体错位，所以存名字。排序规则在
`AppSettings.applyHomeOrder`：

| 情况 | 结果 |
| --- | --- |
| 顺序为空 | 原样返回（用网站给的顺序） |
| 排过的 | 按用户的顺序 |
| 只排了一部分 | 排过的在前，其余保持原相对顺序排在后面 |
| 网站**新加**了栏目 | 排在最后，**不会丢** |
| 顺序里有网站**已删**的栏目 | 直接忽略，不出错 |

> **`List.sort` 在 Dart 里不保证稳定**（元素少走插入排序，多了换快排），
> 所以实现里用「原下标」当次要关键字，不然"没排过的部分保持原顺序"
> 这条在栏目多的时候会随机失效。测试里专门放了 40 个元素逼它走快排。

### 首页要**监听**这个设置

首页是常驻页面（活在 `IndexedStack` 里），不监听的话在设置页拖完回来
还是旧顺序。所以 `_HomePageState` 在 `initState` 里
`addListener`、在 `dispose` 里 `removeListener`。

### 栏目名从哪来

设置页自己没有首页数据，从 `AppCache`（key 是
`AppCache.homeSectionsKey`，公共常量，不要在两处各写一遍字符串）里拿；
缓存过期了（5 分钟）就现拉一次 `/api/home_sections` —— 排顺序只要栏目名。

### 对话框是**即时生效**的

每拖一次就写一次设置，不搞"保存 / 取消"那一套 ——
省得拖完忘了点保存。另有「恢复默认顺序」= 写一个空列表。

> 用的是 `ReorderableListView.onReorderItem`（不是废弃的 `onReorder`）：
> 它给的 `newIndex` **已经**是移除之后的下标，不用自己再 `-1`。

## 📦 MSIX 安装包

一条命令：

```powershell
powershell -ExecutionPolicy Bypass -File frontend\scripts\package_msix.ps1
```

五步：打后端 → 打前端 → **把后端 exe 拷到前端产物旁边** → 打 MSIX → 校验。

产物落在 `E:\Hanime\HanimeViewer\HanimeData\Release\`：
`HanimeViewer.msix` + `HanimeViewer.cer` + `安装说明.md`。

### ⚠️ 装到系统里之后，数据目录必须换地方

MSIX 装到 `C:\Program Files\WindowsApps\` 下面，**那个目录是只读的** ——
设置和下载写不进去。所以 `program_root()` 多了一条：

| 跑法 | 数据目录 |
| --- | --- |
| 源码运行 | 项目根 `\HanimeData` |
| 便携版（解压即用） | `<解压目录>\HanimeData` |
| **MSIX 安装版** | `%LOCALAPPDATA%\HanimeViewer\HanimeData` |

两个坑：

1. **不能只靠"写一个测试文件试试"来判断。** MSIX 有文件系统虚拟化：
   主进程往安装目录写会被重定向到包自己的私有目录，探针会"成功"；
   但后端的 exe 是**子进程、没有包标识**，同样的路径它会真的失败。
   所以 MSIX 直接看可执行文件路径里有没有 `\windowsapps\`，不猜。
2. **这个判断必须放在"往上找项目根"之前。** 万一安装路径上面某一级
   碰巧有 `.git` 或 `backend` + `frontend`，就会被认成项目根，
   数据又写回只读目录了（实测踩到过：以为是 MSIX 路径，结果返回了项目根）。

想强制指定位置：环境变量 `HANIME_DATA_DIR`（**整个换掉**数据目录，
安装版想跟便携版共用同一份数据时很有用）。

### 证书：别用 msix 默认那张

msix 包默认拿一张 subject 写死的 `CN=Msix Testing` 去签，而且
**不导出成文件** —— 用户没法信任它，装的时候只会得到"证书链不受信任"。

所以 `scripts\make_msix_cert.ps1` 自己签一张 `CN=HanimeViewer` 的
（代码签名扩展 + `NotAfter` 10 年），导出 `.pfx` 给打包用、`.cer` 给用户装。
`msix_config` 里指定 `certificate_path` + `certificate_password`。

**清单里的 Publisher 必须和证书 subject 一模一样**（都是 `CN=HanimeViewer`），
否则安装会被拒。`verify_msix.ps1` 会把这两者打出来对比。
`.pfx` 有私钥，已经加进 `.gitignore`。

### PowerShell 脚本的两个坑

1. **`.ps1` 里有中文就必须存成 UTF-8 BOM。**
   `package_msix.ps1` 是用 `powershell.exe`（5.1）调子脚本的，
   5.1 按**系统代码页**读文件 —— 没有 BOM 时中文注释会被读成乱码，
   把后面的 `}` 一起吃掉，报 `Unexpected token '}'`。
   （用 `pwsh` 跑没事，它是按 UTF-8 读的 —— 所以这个坑很容易漏掉。）
2. **脚本最后写一句 `exit 0`。** 不然 build 脚本里的
   `if ($LASTEXITCODE -ne 0) { 报错 }` 会误判成功为失败。

### 校验（`verify_msix.ps1`）

MSIX 就是个 zip，脚本会解开来看：签名者、清单里的 Identity/Publisher/
Version/Architecture、`frontend.exe` / `hanime_backend.exe` /
`flutter_windows.dll` / `data\` 在不在、**发布者和证书对不对得上**。
其中 `hanime_backend.exe` 最容易漏 —— `flutter build windows` 不会拷它，
必须自己拷。

### 图标是**脚本生成**的，别手工替换

`frontend\scripts\make_icons.py`（要 Pillow，`pip install pillow`），一次生成两个：

| 文件 | 用途 | 画法 |
| --- | --- | --- |
| `windows\runner\resources\app_icon.ico` | exe 内嵌 / 任务栏 / 窗口 | 带圆角，7 个尺寸 |
| `assets\msix_logo.png` | MSIX 磁贴（开始菜单等） | 同样带圆角 —— **四角必须有透明** |

**为什么源图一定要有透明像素**：msix 包生成磁贴时会先调 image 包的
`trim()`，那是"去掉四边同色的边框"。如果源图是一整块不透明的黑方块，
黑边会被当成边框裁掉、只剩中间那个 H，再放大铺满整块磁贴 ——
**结果颜色整个反过来（红底黑 H）**。四角留透明（圆角）就不会被裁，
`trim` 的包围盒仍然是整张图。

> （一开始想反了：以为"四周留透明会让底板透出来"，就把源图改成整块不透明 ——
> 结果打出来是红底黑 H。踩过这个坑才写清楚。）
>
> 生成出来的 `Images\*.png` 也还是圆角的 —— 那是磁贴自己的圆角。

**H 的大小**：`GLYPH_RATIO = 0.82`（占图标高度）。
一开始写的 0.64，结果开始菜单那个 16~24px 的图标里 H 又细又小，
看着像"图标没画满、外面一圈留白"。H 本来就是个窄高的字（13:31），
小尺寸下必须给足高度才看得清。

### ⚠️ 打完包必须再打一次补丁（`patch_msix.ps1`）

msix 包生成的 manifest 里写死了这么一句：

```xml
<uap:VisualElements BackgroundColor="transparent" ...>
```

它在 **Windows 10** 上会引起两个问题（实测复现）：

1. **开始菜单里图标外面一圈留白。**
   Win10 把应用图标放在一块"底板"上，底板颜色取的就是这个
   `BackgroundColor`。`transparent` 会落回默认色 ——
   于是深色图标被一圈浅色底板围住。
2. **磁贴上的应用名看不清。**
   Windows 按 `BackgroundColor` 的明暗决定名字用黑字还是白字；
   `transparent` 被当成浅色 → 画成**黑字** → 压在深色图标上就看不见了。

**改成图标本身的颜色 `#121214`，两个问题一起解决**：
底板和图标同色 → 连成一片没有圈；背景是深色 → 名字自动变白字。

> msix 包**没有**提供配置项来改这个值（`configuration.dart` 里翻遍了），
> 所以只能打完之后 `MakeAppx unpack` → 改 → `pack` → `signtool sign`。
> MakeAppx 和 signtool 都用 msix 包**自带**的那份
> （`lib\assets\MSIX-Toolkit\Redist.x64`），不用装 Windows SDK。

### 四种磁贴尺寸要分别排版

`msix:create` 只用一张源图缩放出所有尺寸，于是**小/中/宽/大四种磁贴
长得一模一样**：图标铺满整块，而应用名画在底部 —— 直接压在图标上。

`make_tiles.py` 在解包目录里就地重排（`patch_msix.ps1` 会调它）：

| 磁贴 | 排法 |
| --- | --- |
| 小 71x71 | 图标铺满（小磁贴不显示名字） |
| 中 150x150 | 图标缩到 56%、顶部留 14%，**底下 30% 空出来给名字** |
| 大 310x310 | 同上 |
| 宽 310x150 | 同上（按高度算，水平居中） |
| 启动画面 | 图标居中、占高度 45% |
| 列表图标 / 商店图标 / 徽章 | 铺满 |

因为底板色和图标色是同一个值，缩小的图标和底板看起来连成一片，
不会出现"图标周围一圈别的颜色"。

## 🪟 无边框窗口 + 自绘标题栏

系统标题栏已经去掉，改用自绘的（`frontend/lib/widgets/custom_title_bar.dart`）。

| 文件 | 作用 |
| --- | --- |
| `controllers/app_window.dart` | 窗口状态（最大化/全屏）与操作（最小化/最大化/关闭/拖动/改大小） |
| `widgets/custom_title_bar.dart` | 标题栏本体：图标 + 名称 + 三个窗口按钮 |
| `widgets/window_resize_border.dart` | 无边框之后补回来的「拖边框改大小」热区（4 边 + 4 角） |

### ⚠️ 标题栏里**不能**用 `Tooltip`（会整条变灰）

**现象**：鼠标一悬停到右上角的窗口按钮上，标题栏就蒙上一层灰、按钮也错位。

**原因**：标题栏挂在 `MaterialApp.builder` 里，也就是在 Navigator
**外面** —— 那一层**没有 `Overlay` 祖先**。而 `Tooltip` 要弹提示时得去
`Overlay.of(context)`，于是悬停超过 `waitDuration`（500ms）就抛异常：

```
No Overlay widget found.
RawTooltip widgets require an Overlay widget ancestor ...
```

**release 模式下 build 抛异常会把整棵子树换成一块灰盒子** ——
看起来就是"标题栏蒙了一层灰、按钮不见了/错位"。

**修复**：窗口按钮去掉 `Tooltip`（三个符号本来就自解释）。
`test/custom_title_bar_test.dart` 里有一条回归测试：**故意不给 Overlay**
（复刻真实结构）再悬停 1.2 秒，断言不抛异常、按钮位置不变。
把 `Tooltip` 加回去这条测试立刻失败，会打印上面那段 `No Overlay widget found`。

> 记住这条：**`MaterialApp.builder` 里的东西在 Navigator 外面**，
> 任何依赖 `Overlay` 的组件（`Tooltip`、`showMenu`、`SnackBar`…）都不能直接用。

### 标题栏是一条**透明浮层**，不是一条独立横杠

不画背景、不画分隔线、不显示程序名和图标 —— 底下的应用（含左侧侧边栏）
直接透上来。整条只剩两样东西：中间一大片拖动区 + 右边的窗口按钮。

布局上是 `Stack`：应用铺满整个窗口，标题栏透明地浮在最上面那 38px。

```
Stack(
  Positioned.fill(TitleBarInset(height: 38, child: 应用)),
  Positioned(top:0, height:38, child: CustomTitleBar()),
)
```

**要让出这 38px 的是应用自己**，分两种情况：

| 谁 | 怎么让 |
| --- | --- |
| 有 `AppBar` 的页面 | 靠 `TitleBarInset` 注入 `MediaQuery.padding.top += 38`。AppBar 本来就会吃掉 padding.top（那是给手机状态栏留白的机制），所以自动下移，不用逐页改 |
| `MainShell` | 它是 `Scaffold(body:)`，不吃 padding，自己给内容区加 `EdgeInsets.only(top: ...)` |

**侧边栏刻意不让** —— 它一直顶到窗口最上面，所以标题栏那一条左边露出来的
就是侧边栏本身。程序图标也不再放 `NavigationRail.leading`（那边会自己再加
一段留白，图标会掉到标题栏下面），而是单独放在侧边栏 Column 的最上面、
高度正好 38：

```dart
SizedBox(height: AppWindow.titleBarHeight, child: Center(child: Icon(...))),
```

`test/custom_title_bar_test.dart` 里锁了这条前提：**AppBar 确实会吃掉
MediaQuery.padding.top** —— 万一 Flutter 以后改了这个行为，测试会先失败，
而不是等用户发现返回按钮点不到。

### 为什么用 `setAsFrameless()` 而不是 `TitleBarStyle.hidden`

`hidden` 走的是 `WM_NCCALCSIZE`，会在左/右/下各留 **8px 非客户区边框**
（`sz->rgrc[0].right -= 8` 那几行）。那圈边框是窗口类背景色画的，
深色主题下就是一道明显的亮边。`setAsFrameless()` 才是真正的无边框。

无边框之后系统不再画阴影，所以补一句 `setHasShadow(true)`
（内部用 `DwmExtendFrameIntoClientArea`），否则窗口和桌面糊在一起看不出边界。

### 关键：拖动和缩放走的是**原生消息**，不是自己模拟

- `startDragging()` → `WM_SYSCOMMAND / SC_MOVE|HTCAPTION`
- `startResizing(edge)` → `WM_NCLBUTTONDOWN / HT*`

所以 Aero 贴边（拖到屏幕边缘自动分屏）、最小尺寸限制、边界吸附全都还在。

### 标题栏放在 Navigator **外面**

用的是 `MaterialApp.builder`（它包的就是 Navigator），而不是塞进 `home`：

```dart
builder: (context, child) => WindowResizeBorder(
  child: Column(children: [
    if (!fullscreen) const CustomTitleBar(),
    Expanded(child: child!),
  ]),
),
```

放 `home` 里的话，push 出来的页面（影片详情、全屏播放器）会**整个盖住标题栏**。
全屏看片时用 `AppWindow.fullscreen` 把标题栏和缩放热区一起收起来。

### 实测

| 项目 | 结果 |
| --- | --- |
| 无边框 | 客户区 1280x720 == 窗口 1280x720（差 0，没有标题栏/边框） |
| 最大化 | 2576x1416（占满屏幕） |
| 还原 | 回到 1280x720 且位置不变 |
| 最小化 / 还原 | 正常 |
| 关闭 | 进程 0.31s 退出，收尾 frontend/backend/chrome 全 0 |

## 🚪 启动时先闪一个「透明窗口」

**现象**：双击 exe 之后先出现一个透明的窗口（只有 DWM 阴影勾出个轮廓、
能看出边界），过好几秒才变成界面。

**原因有两层，叠在一起才这么明显**：

1. **窗口在 Flutter 画出任何东西之前就被 `show()` 了。**
   原来 `show()` 写在 `windowManager.waitUntilReadyToShow` 的回调里，
   那会儿连 `runApp` 都还没调用。而窗口类的背景刷是空的
   （`win32_window.cpp` 里 `hbrBackground = 0`），
   所以露出来的是一块**全透明**的窗口 —— 内容全靠 DWM 阴影露出的轮廓。
   （顺手排除了一个猜测：用 `GetWindowRect` vs `GetClientRect` 量过，
   窗口在第一次可见时**已经是无边框**的，不是"边框没去掉"。）

2. **`BackendLauncher.start()` 挡在 `runApp` 前面，要 2127ms。**
   实测各阶段：

   | 阶段 | 耗时 |
   | --- | --- |
   | main() 到 waitUntilReadyToShow 结束 | 32ms |
   | AuthController.load | 1ms |
   | **BackendLauncher.start** | **2094ms** |
   | setPreventClose | 1ms |
   | 首帧 | 9ms |

   大头是 `isBackendAlive()` 探测端口的 2 秒超时。
   两件事叠起来 → **透明窗口要挂 5 秒多**，才显得那么刺眼。

**修复**：

1. `show()` 挪到 **首帧之后**（`addPostFrameCallback`）——
   用户第一眼看到的就是已经画好的启动页。
2. `BackendLauncher.startWithStatus()` **只拿 Future 不等它**，
   `main()` 直接 `runApp`；等它的活儿交给启动页
   （`StartupGate` 现在收的是 `Future<BackendStart>` 而不是算好的值，
   它本来就是加载页，多等这一会儿正好）。

**效果**（同一台机器实测）：

| | 窗口出现 | 第一眼看到的内容 |
| --- | --- | --- |
| 改之前 | 1.83s | **透明**，持续到 7.5s 界面出来 |
| 只改 show 时机 | 3.94s | 启动页（但白等 2 秒） |
| **现在** | **1.92s** | **启动页**（中心红色像素 1776 个，确认画出来了） |

> 排查手段：`GetWindowRect` / `GetClientRect` 对比判断有没有非客户区边框，
> 这个不看画面也能测；再配合"窗口第一次变为可见的时刻"打点。

## 🪟 窗口：记住大小 / 每次居中 / 退出清理

**需求**：记住上次的窗口大小，每次启动都居中。

**实现**（`frontend/lib/main.dart`）：

- 启动：`AppSettings.load()` 读出上次尺寸 →
  `windowManager.waitUntilReadyToShow(WindowOptions(size: ..., center: true, ...))`
- 保存：`_LifecycleCleaner` 监听 `onWindowResize` / `onWindowResized`，
  防抖 400ms 后写盘；最大化 / 全屏时不记（那记的是屏幕大小）。
- 原生 `windows/runner/main.cpp` 里也把初始窗口摆到屏幕正中，
  免得用户看到窗口"先出现在左上角、再跳到中间"。

### 踩过的坑

1. **`onWindowResize` 对程序化改尺寸不触发。**
   window_manager 的 `resize` 事件挂在 **WM_SIZING** 上（只在你拖边框时发），
   `setSize` / `MoveWindow` 只发 WM_SIZE，不会触发。
   拖拽结束时那一次是 **`onWindowResized`**（WM_EXITSIZEMOVE），
   所以两个都接上才稳。

2. **`onWindowClose` 里的异步收尾会被掐断。**
   窗口一关、进程就退，Dart 隔离区跟着没。
   曾经把 `BackendLauncher.stop()` 挂在 `_rememberSize().then(...)` 后面，
   结果还没轮到它进程就退了 —— 后端和 **12 个隐藏 chrome** 全留在后台。
   现在：**关后端的请求第一件事就发出去**，写设置并行做；
   另外 `setPreventClose(true)` + **3 秒兜底**（防止窗口被锁死关不掉）。

3. **共享偏好里 key 带 `flutter.` 前缀。**
   文件是 `%APPDATA%\com.example\frontend\shared_preferences.json`，
   实际的键叫 `flutter.window_width`，不是 `window_width`。
   我用 PowerShell 查的时候漏了前缀，一度以为没存进去，白折腾一轮。

## 缓存与加载速度（重要）

后端现在有两层提速，改这两块之前请先读一下。

### 1. 等待页面就绪：不再用固定 `time.sleep(5)`

旧写法每个接口都是「导航 → 睡 5 秒 → 取 HTML」。实测发现：

| 页面 | 内容真正就绪 | `readyState` 变成 complete |
| --- | --- | --- |
| 首页 | 约 1.2 秒 | 约 5.2 秒 |
| 搜索页 | 约 1.4 秒 | 约 3.2 秒 |
| 详情页 | 约 1.2 秒 | 约 3.9 秒 |

也就是说固定 5 秒**既慢又不可靠**：首页要 5.2 秒才 complete，
固定睡 5 秒有时候会取到半成品。

现在改成轮询「目标元素是否出现且稳定」，目标元素是：

- 列表页（首页/搜索/筛选/播放清单）：`a.video-link`
- 详情页：`#video-artist-name`

已实测确认：提前读取的 DOM 解析结果和等 complete 之后**完全一致**
（首页 12 个栏目 × 12 个视频；详情页 playlist/sources/brand/tags 全部相同），
差异只在广告和统计请求。

如果哪天网站改版导致解析不出来，优先检查上面两个选择器是否还有效。

### 2. 内存 TTL 缓存（`backend/cache.py`）

按 URL 缓存**解析前的 HTML**，避免同一个页面反复重新加载。

| 缓存 | TTL | 用途 |
| --- | --- | --- |
| `home_cache` | 600 秒 | 首页栏目 |
| `search_cache` | 300 秒 | 搜索/筛选 |
| `detail_cache` | 180 秒 | 视频详情 |
| `tags_cache` | 1800 秒 | 标签分组 |
| `playlist_cache` | 300 秒 | 播放清单 |

详情页 TTL 故意较短：里面的视频直链带 `secure` 签名和过期时间，
缓存太久用户点播放会拿到失效地址。

调试接口：

- `GET /api/cache_stats` —— 看命中次数
- `GET /api/cache_clear` —— 手动清空

### 3. 并发安全

所有请求共用同一个 Chrome 标签页，所以 `main.py` 的
`fetch_html()` 全程持有 `_NAVIGATE_LOCK`。
如果去掉这把锁，两个并发请求会互相把页面导航走，
导致 A 请求解析到 B 请求的页面内容。

### 实测效果（2026-09-26）

| 接口 | 优化前 | 冷启动 | 命中缓存 |
| --- | --- | --- | --- |
| `/api/home_sections` | 5.2s | 1.4~2.0s | 0.15s |
| `/api/filter` | 5.2s | 1.4~1.5s | 0.12s |
| `/api/tags` | 5.1s | 1.2s | 0.06s |
| `/api/video/{id}` | 5.2s | 1.3s | 0.05s |

前端另有一层 `lib/controllers/app_cache.dart`（搜索结果 + 首页），
并且 `MainShell` 用 `IndexedStack` 保留已打开页面的 State，
所以来回切换栏目不会重新请求。

## 怎么运行

脚本里已经加好了路径引导，**从任何目录运行都可以**：

```powershell
E:\Hanime\HanimeViewer\.venv\Scripts\python.exe E:\Hanime\HanimeViewer\backend\dev\test_cdp.py
```

如果在 `backend` 目录下，也可以直接：

```powershell
cd E:\Hanime\HanimeViewer\backend
..\.venv\Scripts\python.exe dev\test_cdp.py
```

## 运行前提

1. 调试用 Chrome 已经带远程调试端口启动，`http://127.0.0.1:9222/json` 能打开。
2. 那个 Chrome 里已经打开了目标页面（脚本读的是**当前标签页**）。
   注意：像 `test_watch.py` / `test_search.py` 这类脚本会自己导航到目标网址，
   会把你的调试 Chrome 当前标签页**跳走**，跑完记得切回来。
3. 如果脚本输出中文变成乱码，是 Windows 控制台编码问题，不是脚本问题：
   在命令前加 `$env:PYTHONIOENCODING="utf-8"`。
