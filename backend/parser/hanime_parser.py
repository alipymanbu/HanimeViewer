import re

from bs4 import BeautifulSoup

from parser.models import VideoCard, VideoDetail


class HanimeParser:
    def __init__(self, html):
        self.html = html
        self.soup = BeautifulSoup(html, "html.parser")

    @staticmethod
    def clean_url(value):
        if not value:
            return value

        value = value.strip()

        # 处理 [显示文字](真实地址) 这种 Markdown 格式
        if value.startswith("[") and value.endswith(")"):
            marker = "]("
            marker_pos = value.find(marker)

            if marker_pos != -1:
                return value[marker_pos + 2:-1]

        return value

    def get_title(self):
        if self.soup.title:
            return self.soup.title.text.strip()

        return None

    def count_links(self):
        return len(self.soup.find_all("a"))

    def get_some_links(self, limit=10):
        result = []

        for link in self.soup.find_all("a")[:limit]:
            result.append({
                "text": link.text.strip(),
                "href": self.clean_url(link.get("href"))
            })

        return result

    def get_images(self, limit=10):
        result = []

        for img in self.soup.find_all("img")[:limit]:
            result.append({
                "src": self.clean_url(img.get("src")),
                "alt": img.get("alt")
            })

        return result

    def _parse_video_link(self, card):
        url = self.clean_url(card.get("href"))

        img = card.find("img", class_="main-thumb")

        if not img:
            return None

        thumbnail = self.clean_url(img.get("src"))

        title_box = card.find("div", class_="title")
        title = title_box.get_text(strip=True) if title_box else ""

        duration_box = card.find("div", class_="duration")
        duration = duration_box.get_text(strip=True) if duration_box else ""

        stat_items = card.find_all("div", class_="stat-item")

        rating = ""
        views = ""

        if len(stat_items) >= 1:
            rating_box = stat_items[0]

            icon = rating_box.find("i", class_="material-icons")

            if icon:
                icon.extract()

            rating = rating_box.get_text(strip=True)

        if len(stat_items) >= 2:
            views = stat_items[1].get_text(strip=True)

        return VideoCard(
            title=title,
            url=url,
            thumbnail=thumbnail,
            duration=duration,
            rating=rating,
            views=views
        )

    def get_video_cards(self, limit=None):
        result = []

        cards = self.soup.find_all("a", class_="video-link")

        for card in cards:
            video_card = self._parse_video_link(card)

            if not video_card:
                continue

            result.append(video_card)

            if limit is not None and len(result) >= limit:
                break

        return result
        
    def get_playlists(self, limit=None):
        result = []

        playlist_cards = self.soup.find_all(
            "div",
            class_="video-item-container"
        )

        for card in playlist_cards:
            link = card.find(
                "a",
                class_="video-link",
                href=True
            )

            if not link:
                continue

            href = self.clean_url(
                link.get("href")
            )

            if not href:
                continue

            if not href.startswith(
                "https://hanime1.me/playlist?list="
            ):
                continue

            thumbnail = ""

            img = card.find(
                "img",
                class_="main-thumb"
            )

            if img:
                thumbnail = self.clean_url(
                    img.get("src")
                ) or ""

            name = ""

            title_box = card.find(
                "div",
                class_="title"
            )

            if title_box:
                name = title_box.get_text(
                    " ",
                    strip=True
                )

            if not name:
                continue

            video_count = ""

            stats_container = card.find(
                "div",
                class_="stats-container"
            )

            if stats_container:
                stat_item = stats_container.find(
                    "div",
                    class_="stat-item"
                )

                if stat_item:
                    video_count = stat_item.get_text(
                        " ",
                        strip=True
                    )

            if not video_count:
                continue

            result.append({
                "name": name,
                "video_count": video_count,
                "thumbnail": thumbnail,
                "url": href
            })

            if limit is not None and len(result) >= limit:
                break

        return result

    def get_playlist_videos(self, limit=None):
        result = []
        seen_video_ids = set()

        cards = self.soup.find_all(
            "div",
            class_="playlist-video-card"
        )

        for card in cards:
            link = card.find(
                "a",
                href=True
            )

            if not link:
                continue

            href = self.clean_url(
                link.get("href")
            )

            if not href:
                continue

            if not href.startswith(
                "https://hanime1.me/watch?"
            ):
                continue

            video_id = ""

            query = href.split("?", 1)[1]

            for part in query.split("&"):
                if part.startswith("v="):
                    video_id = part[2:]
                    break

            if not video_id:
                continue

            if video_id in seen_video_ids:
                continue

            thumbnail = ""

            img = card.find(
                "img",
                class_="main-thumb"
            )

            if img:
                thumbnail = self.clean_url(
                    img.get("src")
                ) or ""

            duration = ""

            duration_box = card.find(
                "div",
                class_="duration"
            )

            if duration_box:
                duration = duration_box.get_text(
                    " ",
                    strip=True
                )

            rating = ""
            views = ""

            stat_items = card.find_all(
                "div",
                class_="stat-item"
            )

            if len(stat_items) >= 1:
                rating_box = stat_items[0]

                icon = rating_box.find(
                    "i",
                    class_="material-icons"
                )

                if icon:
                    icon.extract()

                rating = rating_box.get_text(
                    " ",
                    strip=True
                )

            if len(stat_items) >= 2:
                views = stat_items[1].get_text(
                    " ",
                    strip=True
                )

            title = ""

            title_box = card.find(
                "h4",
                class_="video-title"
            )

            if title_box:
                title = title_box.get_text(
                    " ",
                    strip=True
                )

            if not title:
                continue

            seen_video_ids.add(video_id)

            result.append({
                "video_id": video_id,
                "title": title,
                "url": href,
                "thumbnail": thumbnail,
                "duration": duration,
                "rating": rating,
                "views": views
            })

            if limit is not None and len(result) >= limit:
                break

        return result

    def get_video_source(self):
        # 优先寻找：
        # <link rel="preload" as="video" href="...">
        video_preload = self.soup.find(
            "link",
            attrs={
                "rel": "preload",
                "as": "video"
            }
        )

        if video_preload:
            source = video_preload.get("href")

            if source:
                return self.clean_url(source)

        # 如果 preload 没找到，再寻找 <video> / <source>
        video = self.soup.find("video")

        if video:
            source = video.get("src")

            if source:
                return self.clean_url(source)

            source_tag = video.find("source")

            if source_tag:
                source = source_tag.get("src")

                if source:
                    return self.clean_url(source)

        return None

    def get_video_sources(self):
        # 返回页面中所有 <source> 标签对应的画质列表
        # 格式：[{"url": "...", "quality": "1080p"}, ...]
        # 按清晰度从高到低排序
        sources = []

        video = self.soup.find("video")

        if not video:
            return sources

        source_tags = video.find_all("source")

        for source_tag in source_tags:
            src = source_tag.get("src")
            size = source_tag.get("size")

            if not src:
                continue

            if size:
                quality = f"{size}p"
            else:
                import re
                match = re.search(r"-(\d+p)\.mp4", src)
                if match:
                    quality = match.group(1)
                else:
                    quality = "unknown"

            sources.append({
                "url": self.clean_url(src),
                "quality": quality
            })

        def quality_number(item):
            text = item["quality"].rstrip("p")
            if text.isdigit():
                return int(text)
            return 0

        sources.sort(key=quality_number, reverse=True)

        return sources

    def get_thumbnail(self):
        # 优先寻找 Open Graph 图片
        og_image = self.soup.find(
            "meta",
            attrs={
                "property": "og:image"
            }
        )

        if og_image:
            image_url = og_image.get("content")

            if image_url:
                return self.clean_url(image_url)

        # 如果没有 og:image，则尝试页面中的 video poster
        video = self.soup.find("video")

        if video:
            poster = video.get("poster")

            if poster:
                return self.clean_url(poster)

        return None

    def get_description(self):
        meta_description = self.soup.find(
            "meta",
            attrs={
                "name": "description"
            }
        )

        if meta_description:
            return meta_description.get("content")

        return None

    def get_brand(self):
        # 品牌（制作商）取自详情页左上角的作品名称节点：
        # <a id="video-artist-name" href=".../search?query=ピンクパイナップル&amp;genre=裏番">
        brand_node = self.soup.find(
            "a",
            attrs={
                "id": "video-artist-name"
            }
        )

        if not brand_node:
            return ""

        return brand_node.get_text(strip=True)

    def get_brand_url(self):
        # 品牌的搜索链接，供客户端点击跳转
        brand_node = self.soup.find(
            "a",
            attrs={
                "id": "video-artist-name"
            }
        )

        if not brand_node:
            return ""

        return self.clean_url(brand_node.get("href")) or ""

    def get_uploader(self):
        # 上传者（投稿用户），名称在详情面板中：
        # <div class="video-description-panel">
        #   <a href=".../user/68664"><span style="color: white; font-weight: bold;">孤独的波斯猫</span></a>
        panel = self.soup.find(
            "div",
            class_="video-description-panel"
        )

        if not panel:
            return ""

        # 名称位于指向用户主页的链接中：
        # <a href="https://hanime1.me/user/68664"><span ...>孤独的波斯猫</span></a>
        # 注意：面板里还有其他 span（例如“上傳者”标签），
        # 所以必须按 href 定位，不能直接取第一个 span。
        for link in panel.find_all("a", href=True):
            href = self.clean_url(link.get("href")) or ""

            if "/user/" not in href:
                continue

            name = link.get_text(strip=True)

            if name:
                return name

        return ""

    def get_release_date(self):
        # 页面上的日期形如：
        # 觀看次數：692.7萬次&nbsp;&nbsp;2024-11-29
        # 这里直接匹配 YYYY-MM-DD，避免依赖标签文字
        import re

        text = self.soup.get_text(" ", strip=True)

        match = re.search(
            r"(\d{4}-\d{2}-\d{2})",
            text
        )

        if match:
            return match.group(1)

        return ""

    def get_views(self):
        # 观看次数，形如：觀看次數：692.7萬次
        import re

        text = self.soup.get_text(" ", strip=True)

        match = re.search(
            r"觀看次數[：:]\s*([0-9.,]+\s*[萬万亿]?次?)",
            text
        )

        if match:
            return match.group(1).strip()

        return ""

    def get_file_size(self):
        # 影片详情页目前不提供文件大小字段。
        # 保留该方法是为了兼容 VideoDetail 模型，
        # 不要再去 meta description 里找 "File size / ファイル容量:"，
        # 该标签在网站上并不存在（会导致永远返回空字符串）。
        return ""

    def get_tags(self):
        meta_keywords = self.soup.find(
            "meta",
            attrs={
                "name": "keywords"
            }
        )

        if not meta_keywords:
            return []

        content = meta_keywords.get("content")

        if not content:
            return []

        return [
            tag.strip()
            for tag in content.split(",")
            if tag.strip()
        ]

    def get_artist_id(self):
        # 播放器下方那个头像属于「品牌/制作商」区块，不是上传者：
        # <a href="https://hanime1.me/user/367299">
        #   <img id="video-user-avatar" ...>
        #
        # 注意区分：真正的上传者在 .video-description-panel 里，
        # 是另一个用户（见 get_uploader_id）。
        avatar = self.soup.find("img", attrs={"id": "video-user-avatar"})

        if not avatar:
            return ""

        link = avatar.find_parent("a", href=True)

        if not link:
            return ""

        href = self.clean_url(link.get("href")) or ""

        if "/user/" not in href:
            return ""

        return href.rstrip("/").rsplit("/", 1)[-1]

    def get_artist_url(self):
        avatar = self.soup.find("img", attrs={"id": "video-user-avatar"})

        if not avatar:
            return ""

        link = avatar.find_parent("a", href=True)

        if not link:
            return ""

        return self.clean_url(link.get("href")) or ""

    def get_artist_avatar(self):
        # 头像是两个叠加的 img：默认头像 + 真实头像。
        # 取最后一个，那才是显示在上层的。
        avatar = self.soup.find("img", attrs={"id": "video-user-avatar"})

        if not avatar:
            return ""

        container = avatar.find_parent("div")

        if container:
            images = container.find_all("img")

            if len(images) >= 2:
                return self.clean_url(images[-1].get("src")) or ""

        return self.clean_url(avatar.get("src")) or ""

    def _uploader_link(self):
        """描述面板里指向上传者主页的链接。"""
        panel = self.soup.find("div", class_="video-description-panel")

        if not panel:
            return None

        for link in panel.find_all("a", href=True):
            href = self.clean_url(link.get("href")) or ""

            if "/user/" in href:
                return link

        return None

    def get_uploader_id(self):
        link = self._uploader_link()

        if not link:
            return ""

        href = self.clean_url(link.get("href")) or ""

        return href.rstrip("/").rsplit("/", 1)[-1]

    def get_uploader_url(self):
        link = self._uploader_link()

        if not link:
            return ""

        return self.clean_url(link.get("href")) or ""

    def get_uploader_avatar(self):
        link = self._uploader_link()

        if not link:
            return ""

        img = link.find("img")

        if not img:
            return ""

        return self.clean_url(img.get("src")) or ""

    def get_like_info(self):
        # 点赞/点踩区域：
        # <button id="video-like-btn">
        #   <div class="single-icon"><i ...>thumb_up</i>99%&nbsp;&nbsp;<span>(3602)</span></div>
        # </button>
        # <button id="video-unlike-btn"> ... <span>(59)</span>
        result = {
            "like_ratio": "",
            "like_count": "",
            "unlike_count": ""
        }

        def read_button(button_id):
            button = self.soup.find("button", attrs={"id": button_id})

            if not button:
                return "", ""

            span = button.find("span")
            count = ""

            if span:
                count = span.get_text(strip=True).strip("()（）")
                span.extract()

            text = button.get_text(" ", strip=True)

            # 取出形如 99% 的比例
            import re

            match = re.search(r"(\d+(?:\.\d+)?%)", text)

            ratio = match.group(1) if match else ""

            return ratio, count

        like_ratio, like_count = read_button("video-like-btn")
        _, unlike_count = read_button("video-unlike-btn")

        result["like_ratio"] = like_ratio
        result["like_count"] = like_count
        result["unlike_count"] = unlike_count

        return result

    def get_interaction_state(self):
        """当前账号对这部影片的互动状态 —— 直接读 HTML，不用再导航。

        判据（实测，都在详情页 HTML 里）：

        1. 点赞：
           <input name="like-status" type="hidden" value="1">   -> 已点赞
           <input name="unlike-status" type="hidden" value="1"> -> 已点踩
           （未登录 / 未点赞时这些值为空）

        2. 储存：
           <form id="video-save-form">
             <input id="save" class="playlist-checkbox" type="checkbox" checked>
             带 checked 属性的 checkbox 就是已储存的清单。

        3. 可选的播放清单：同一个 form 里的所有 checkbox 就是账号的清单列表。

        之前为了拿这些状态，专门调了一次 /api/video/{id}/state，
        它要重新导航页面 + 打开储存弹窗（约 2.8 秒）。其实页面 HTML
        里就带着，白跑了一趟。这里直接解析，免费。

        储存弹窗需要的「可选清单」也一并解析出来，
        这样客户端点「储存」能立刻弹窗，不用再等一次浏览器导航。
        """
        state = {
            "liked": False,
            "disliked": False,
            "saved": False,
            "saved_playlist": "",
            "save_playlists": [],
        }

        like_status = self.soup.find(
            "input", attrs={"name": "like-status"}
        )

        if like_status and (like_status.get("value") or "") == "1":
            state["liked"] = True

        unlike_status = self.soup.find(
            "input", attrs={"name": "unlike-status"}
        )

        if unlike_status and (unlike_status.get("value") or "") == "1":
            state["disliked"] = True

        # 储存 + 可选清单：都在 #video-save-form 里
        form = self.soup.find("form", attrs={"id": "video-save-form"})

        if form:
            playlists = []

            for checkbox in form.find_all(
                "input", class_="playlist-checkbox"
            ):
                label = checkbox.find_parent("label")
                name = (
                    label.get_text(strip=True)
                    if label
                    else (checkbox.get("id") or "")
                )

                if not name:
                    continue

                checked = checkbox.has_attr("checked")

                playlists.append({
                    "list_id": checkbox.get("id") or "",
                    "name": name,
                    "checked": checked,
                })

                if checked and not state["saved"]:
                    state["saved"] = True
                    state["saved_playlist"] = name

            state["save_playlists"] = playlists

        return state

    def get_playlist_bookmark_state(self):
        """播放清单详情页右上角书签的**收藏状态**。

        官网结构（实测）：

            <form id="playlist-show-add-form" method="POST"
                  action="https://hanime1.me/addPlaylist">
              <input type="hidden" name="_token" ...>
              <input type="hidden" name="playlist-reference-id" value="976998">
              <button type="submit" class="btn-icon-action no-select">
                <span id="playlist-bookmark-icon"
                      class="material-symbols-outlined"
                      style="font-variation-settings: 'FILL' 1;">bookmark</span>
              </button>
            </form>

        判据：`#playlist-bookmark-icon` 的 style 里带 `'FILL' 1`
        -> 实心书签 -> 已收藏；否则空心 -> 未收藏。

        注意：**自己的播放清单页面上没有这个书签表单**
        （自己的清单没什么可收藏的），这时 can_bookmark=False，
        客户端就不该显示可点的书签。
        """
        form = self.soup.find(
            "form", attrs={"id": "playlist-show-add-form"}
        )

        if not form:
            return {"can_bookmark": False, "bookmarked": False}

        icon = self.soup.find(
            "span", attrs={"id": "playlist-bookmark-icon"}
        )

        if not icon:
            return {"can_bookmark": False, "bookmarked": False}

        style = icon.get("style") or ""

        # 'FILL' 1 / 'FILL'1 / "FILL" 1 ... 都算实心
        normalized = style.replace('"', "'").replace(" ", "")

        return {
            "can_bookmark": True,
            "bookmarked": "'FILL'1" in normalized,
        }

    def get_related_videos(self, limit=None):
        # 相關影片区：
        # <div id="related-tabcontent">
        #   <a href="https://hanime1.me/watch?v=408113">
        #     <div class="home-rows-videos-div ...">
        #       <div class="video-card-inner">
        #         <img src=".../cover/408113.jpg">
        #         <div class="home-rows-videos-title">标题</div>
        #
        # 注意：这个区域里混有广告卡片，它们的 href 是
        # "javascript:void(0);" 或者站外链接，必须过滤掉，
        # 只保留指向 watch?v= 的卡片。
        #
        # 站点在相关影片区用了**两套版式**（实测都遇到过，取决于视频）：
        #
        #   A. 相关影片（横向小卡，每行 6 个）
        #      <div class="col-xs-2 related-video-width">
        #        <a href="...watch?v=...">          <- 这个 a **没有 class**
        #          <div class="home-rows-videos-div">
        #            <div class="video-card-inner">
        #              <img src=".../cover/xxx.jpg">  <- img 也**没有 class**
        #              <div class="home-rows-videos-title">标题</div>
        #
        #   B. 相似推荐（栅格大卡）
        #      <div class="desktop-grid-item">
        #        <div class="video-item-container" title="标题">
        #          <a class="video-link" href="...watch?v=...">
        #            <img class="main-thumb">
        #            <div class="title">标题</div>
        #
        # 之前只认 B 的 `a.video-link`，A 版式里根本没有这个 class，
        # 于是返回 0 条 —— 这就是「有些视频进详情页后底下没有相关影片」
        # 的真正原因（不是加载时序问题）。
        result = []
        seen = set()

        box = self.soup.find("div", attrs={"id": "related-tabcontent"})

        if not box:
            return result

        for link in box.find_all("a", href=True):
            href = self.clean_url(link.get("href")) or ""

            if not href.startswith("https://hanime1.me/watch?"):
                continue

            video_id = ""

            if "v=" in href:
                video_id = href.split("v=", 1)[1].split("&", 1)[0]

            if not video_id or video_id in seen:
                continue

            # 只处理「卡片」形态的链接，跳过卡片里指向作者/标签的其它链接
            is_variant_a = link.find(
                "div", class_="home-rows-videos-div"
            ) is not None

            is_variant_b = "video-link" in (link.get("class") or [])

            if not (is_variant_a or is_variant_b):
                continue

            seen.add(video_id)

            if is_variant_b:
                # 版式 B
                img = link.find("img", class_="main-thumb")
                thumbnail = self.clean_url(img.get("src")) if img else ""

                title_box = link.find("div", class_="title")

                if title_box:
                    title = title_box.get_text(strip=True)
                else:
                    title = ""

                if not title:
                    container = link.find_parent(
                        "div", class_="video-item-container"
                    )

                    title = (
                        (container.get("title") or "").strip()
                        if container
                        else ""
                    )
            else:
                # 版式 A
                img = link.find("img")
                thumbnail = self.clean_url(img.get("src")) if img else ""

                title_box = link.find(
                    "div", class_="home-rows-videos-title"
                )

                title = (
                    title_box.get_text(strip=True) if title_box else ""
                )

            result.append({
                "video_id": video_id,
                "title": title,
                "url": href,
                "thumbnail": thumbnail or ""
            })
            if limit is not None and len(result) >= limit:
                break

        return result

    def get_user_home_rows(self, limit_per_row=10):
        """个人中心「主页」上的栏目段。

        页面结构（实测）：

            <div class="tab-index-rows-wrapper">      <- 一个 tab 一个
              <a class="horizontal-row-title" href=".../histories">
                <h3>觀看紀錄<div>查看更多...</div></h3>   <- 标题里混着「查看更多」
              </a>
              <div>
                <div class="home-rows-videos-wrapper home-row">
                  <div class="video-item-container">
                    <div class="horizontal-card">
                      <a class="video-link" href="...">   <- 影片 或 播放清单
                    </div>
                  </div>
                  ... 共 10 个左右
              </div>
              ... 后面还有 3 组同样结构
            </div>

        注意两点：
        1. 标题和卡片是**兄弟节点**，所以要用 find_next_sibling，
           不能用 find_parent（那会拿到包含全部 4 个栏目的大容器）。
        2. 「播放清單」这个栏目里的卡片 href 是 /playlist?list=xxx，
           不是 /watch?v=xxx，数量写在 .stats-container 里。
        """
        result = []

        for title in self.soup.find_all(
            "a", class_="horizontal-row-title"
        ):
            name = self._row_title_text(title)

            if not name:
                continue

            href = self.clean_url(title.get("href")) or ""

            sibling = title.find_next_sibling("div")

            cards = []

            if sibling:
                cards = sibling.find_all("a", class_="video-link")

            videos = []
            playlists = []

            for card in cards:
                card_href = self.clean_url(card.get("href")) or ""

                img = card.find("img", class_="main-thumb")
                thumbnail = self.clean_url(img.get("src")) if img else ""

                title_box = card.find("div", class_="title")
                card_title = (
                    title_box.get_text(strip=True) if title_box else ""
                )

                if "/playlist?list=" in card_href:
                    # 播放清单卡片
                    count = ""

                    stats = card.find("div", class_="stats-container")

                    if stats:
                        count = stats.get_text(strip=True)

                    list_id = card_href.split("list=", 1)[1].split("&", 1)[0]

                    playlists.append({
                        "list_id": list_id,
                        "name": card_title,
                        "thumbnail": thumbnail or "",
                        "video_count": count,
                        "url": card_href,
                    })
                    continue

                if not card_href.startswith(
                    "https://hanime1.me/watch?"
                ):
                    continue

                duration_box = card.find("div", class_="duration")
                duration = (
                    duration_box.get_text(strip=True)
                    if duration_box
                    else ""
                )

                stat_items = card.find_all("div", class_="stat-item")

                rating = ""
                views = ""

                if len(stat_items) >= 1:
                    icon = stat_items[0].find("i")

                    if icon:
                        icon.extract()

                    rating = stat_items[0].get_text(strip=True)

                if len(stat_items) >= 2:
                    views = stat_items[1].get_text(strip=True)

                videos.append({
                    "title": card_title,
                    "url": card_href,
                    "thumbnail": thumbnail or "",
                    "duration": duration,
                    "rating": rating,
                    "views": views,
                })

            items = videos if videos else playlists

            if not items:
                continue

            result.append({
                "name": name,
                "url": href,
                "kind": "videos" if videos else "playlists",
                "videos": videos[:limit_per_row],
                "playlists": playlists[:limit_per_row],
                "total": len(items),
            })

        return result

    def _row_title_text(self, title_node):
        """栏目标题的纯文字。

        <h3>觀看紀錄<div>查看更多 <span>→</span></div></h3>
        里面混着「查看更多」，要先把这个 div 去掉再取文字。
        用复制出来的节点处理，不破坏原 soup。
        """
        h3 = title_node.find("h3")

        if not h3:
            return ""

        clone = BeautifulSoup(str(h3), "html.parser").find("h3")

        if not clone:
            return ""

        extra = clone.find("div")

        if extra:
            extra.extract()

        return clone.get_text(strip=True)

    def get_total_pages(self):
        """页面上的总页数（从分页链接里推）。

        个人中心的 tab 页每页 60 条，分页链接形如
        `/user/715321/histories?page=12`。
        没有分页就返回 1。
        """
        import re

        biggest = 1

        for link in self.soup.find_all("a", href=True):
            href = self.clean_url(link.get("href")) or ""

            if "page=" not in href:
                continue

            match = re.search(r"[?&]page=(\d+)", href)

            if not match:
                continue

            try:
                number = int(match.group(1))
            except ValueError:
                continue

            if number > biggest:
                biggest = number

        return biggest

    def get_tab_videos(self, limit=None):
        """个人中心某个 tab（觀看紀錄 / 稍後觀看 / 讚好的影片）里的影片列表。

        这些 tab 页的内容都放在一个
        `<div class="specific-tab-view home-rows-videos-wrapper">` 里。

        为什么要单独写一个方法，而不是用 get_video_cards()：
        tab 页上除了真正的内容，还会带上个人中心首页那 4 个栏目段的预览卡片
        （实测 histories / likes 页面上共 60 个 a.video-link，
        但真正的列表只有 60 个里的那一部分）。
        直接全页抓会把预览段和分页重复的卡片一起算进来。
        """
        box = self.soup.find("div", class_="specific-tab-view")

        if not box:
            box = self.soup

        result = []

        for card in box.find_all("a", class_="video-link"):
            href = self.clean_url(card.get("href")) or ""

            # 播放清单卡片（/playlist?list=xxx）不算影片
            if not href.startswith("https://hanime1.me/watch?"):
                continue

            parsed = self._parse_video_link(card)

            if not parsed:
                continue

            # _parse_video_link 是给首页卡片写的，这里补上 video_id
            video_id = ""

            if "v=" in href:
                video_id = href.split("v=", 1)[1].split("&", 1)[0]

            result.append({
                "video_id": video_id,
                "title": parsed.title,
                "url": parsed.url,
                "thumbnail": parsed.thumbnail,
                "duration": parsed.duration,
                "rating": parsed.rating,
                "views": parsed.views,
            })

            if limit is not None and len(result) >= limit:
                break

        return result

    def get_tab_playlists(self, limit=None):
        """个人中心「播放清單」tab 里的播放清单。"""
        box = self.soup.find("div", class_="specific-tab-view")

        if not box:
            box = self.soup

        result = []
        seen = set()

        for card in box.find_all("a", class_="video-link"):
            href = self.clean_url(card.get("href")) or ""

            if "/playlist?list=" not in href:
                continue

            list_id = href.split("list=", 1)[1].split("&", 1)[0]

            if list_id in seen:
                continue

            seen.add(list_id)

            img = card.find("img", class_="main-thumb")
            thumbnail = self.clean_url(img.get("src")) if img else ""

            title_box = card.find("div", class_="title")
            name = title_box.get_text(strip=True) if title_box else ""

            count = ""
            stats = card.find("div", class_="stats-container")

            if stats:
                count = stats.get_text(strip=True)

            result.append({
                "list_id": list_id,
                "name": name,
                "thumbnail": thumbnail or "",
                "video_count": count,
                "url": href,
            })

            if limit is not None and len(result) >= limit:
                break

        return result

    def _page_user_id(self):
        """从当前页面判断「这个主页是谁的」。"""
        # canonical 最可靠：<link rel="canonical" href=".../user/367299">
        link = self.soup.find("link", attrs={"rel": "canonical"})

        if link:
            href = self.clean_url(link.get("href")) or ""

            match = re.search(r"/user/(\d+)", href)

            if match:
                return match.group(1)

        # 再看 og:url
        og = self.soup.find("meta", attrs={"property": "og:url"})

        if og:
            href = og.get("content") or ""

            match = re.search(r"/user/(\d+)", href)

            if match:
                return match.group(1)

        return ""

    def get_user_avatar(self):
        """用户/发行商主页上的头像。

        坑：页面上不止一张 `/image/avatar/` 图 —— 登录状态下
        **导航栏里还有当前登录用户的头像**，而它排在前面。
        之前直接取第一张，结果访问任何人的主页都显示成自己的头像。

        现在改成跟「这个主页是谁的」对齐：头像文件名是
        `{userId}-xxxx.jpeg`，用页面自己的 user id 去匹配。
        """
        page_user_id = self._page_user_id()

        candidates = []

        for img in self.soup.find_all("img"):
            src = self.clean_url(img.get("src")) or ""

            if "/image/avatar/" not in src:
                continue

            if "user_default_image" in src:
                continue

            candidates.append(src)

        if not candidates:
            return ""

        # 1. 优先挑文件名里带这个主页 id 的那张
        if page_user_id:
            for src in candidates:
                if f"/{page_user_id}-" in src or f"/{page_user_id}." in src:
                    return src

            # 知道主页是谁，但页面里没有这个人的头像。
            #
            # 这种账号（没设过头像）页面上剩下的 avatar 图全是
            # **当前登录用户**的（导航栏那几张），实测 uid=367298 就是
            # 4 张全是 715321 的头像。
            # 这时必须返回空，让客户端显示默认头像 ——
            # 绝不能退回「第一张」，否则又是拿自己的头像冒充别人。
            return ""

        # 2. 判断不出主页 id 时才退回第一张（老行为）
        return candidates[0]

    def get_video_detail(self):
        title = self.get_title()

        video_url = self.soup.find(
            "link",
            attrs={
                "rel": "canonical"
            }
        )

        if video_url:
            video_url = self.clean_url(video_url.get("href"))
        else:
            video_url = ""

        like_info = self.get_like_info()

        return VideoDetail(
            title=title or "",
            url=video_url,
            video_source=self.get_video_source() or "",
            thumbnail=self.get_thumbnail() or "",
            brand=self.get_brand(),
            brand_url=self.get_brand_url(),
            artist_id=self.get_artist_id(),
            artist_url=self.get_artist_url(),
            artist_avatar=self.get_artist_avatar(),
            uploader=self.get_uploader(),
            uploader_id=self.get_uploader_id(),
            uploader_url=self.get_uploader_url(),
            uploader_avatar=self.get_uploader_avatar(),
            like_ratio=like_info["like_ratio"],
            like_count=like_info["like_count"],
            unlike_count=like_info["unlike_count"],
            views=self.get_views(),
            release_date=self.get_release_date(),
            file_size=self.get_file_size(),
            tags=self.get_tags(),
            sources=self.get_video_sources(),
            related=self.get_related_videos()
        )

    def get_tag_groups(self):
        # 从 genre 页面提取所有标签分组
        # 返回格式：[{"name": "人物關係", "tags": ["近親", "姐", ...]}, ...]

        result = []

        modal = self.soup.find("div", id="tags")

        if not modal:
            return result

        modal_body = modal.find("div", class_="modal-body")

        if not modal_body:
            return result

        elements = modal_body.find_all(["h5", "label"])

        current_group = None
        current_tags = []

        def flush():
            if current_group and current_tags:
                result.append({
                    "name": current_group,
                    "tags": list(current_tags)
                })

        for el in elements:
            classes = el.get("class", [])

            if el.name == "h5":
                flush()

                text = el.get_text(strip=True)

                if text == "廣泛配對":
                    current_group = None
                    current_tags = []
                else:
                    current_group = text
                    current_tags = []

            elif el.name == "label":
                if "hentai-tags-wrapper" not in classes:
                    continue

                input_el = el.find(
                    "input",
                    attrs={"name": "tags[]"}
                )

                if not input_el:
                    continue

                value = input_el.get("value", "")

                if value:
                    current_tags.append(value)

        flush()

        return result

    def get_search_total_pages(self):
        from urllib.parse import urlparse, parse_qs

        paginations = self.soup.find_all(
            "div",
            class_="search-pagination"
        )

        print(f"[分页] 找到 {len(paginations)} 个分页区域")

        max_page = 1

        for pagination in paginations:
            for a in pagination.find_all(
                "a",
                class_="page-link",
                href=True
            ):
                href = a.get("href", "")

                if "page=" not in href:
                    continue

                try:
                    parsed = urlparse(href)
                    params = parse_qs(parsed.query)
                    page_num = int(
                        params.get("page", ["0"])[0]
                    )

                    if page_num > max_page:
                        max_page = page_num

                except (ValueError, IndexError):
                    continue

        print(f"[分页] 最大页码 = {max_page}")

        return max_page
    
    def get_search_results(self):
        # 搜索结果页有两种结构：
        # 1. sort 页面（?sort=xxx）和首页栏目结构相同，用 video-link
        # 2. genre 页面（?genre=xxx）用 a > div.video-card-inner 结构
        # 先试 sort 结构，如果找不到视频再试 genre 结构

        result = []

        # 模式 1：video-link（sort 页面、首页栏目）
        cards = self.soup.find_all("a", class_="video-link")

        for card in cards:
            video_card = self._parse_video_link(card)

            if not video_card:
                continue

            if not video_card.url.startswith(
                "https://hanime1.me/watch?"
            ):
                continue

            result.append(video_card)

        if result:
            return result

        # 模式 2：video-card-inner（genre 页面）
        for a in self.soup.find_all("a", href=True):
            href = self.clean_url(a.get("href"))

            if not href:
                continue

            if not href.startswith(
                "https://hanime1.me/watch?"
            ):
                continue

            card = a.find("div", class_="video-card-inner")

            if not card:
                continue

            img = card.find("img")

            if not img:
                continue

            thumbnail = self.clean_url(img.get("src"))

            title_box = card.find(
                "div",
                class_="home-rows-videos-title"
            )

            title = (
                title_box.get_text(strip=True)
                if title_box
                else ""
            )

            if not title:
                continue

            result.append(VideoCard(
                title=title,
                url=href,
                thumbnail=thumbnail,
                duration="",
                rating="",
                views=""
            ))

        return result
    
    def get_home_sections(self):
        # 首页栏目结构：
        # <a class="horizontal-row-title">
        #   <h3>最新上市...查看更多</h3>
        # </a>
        # <div class="home-rows-videos-wrapper ...">
        #   <div class="video-item-container">...</div>
        # </div>
        # ...

        from bs4 import NavigableString

        sections = []

        container = self.soup.find(
            "div",
            class_="home-rows-section-margin-top"
        )

        if not container:
            return sections

        current_name = None
        current_url = None
        current_videos = []

        elements = container.find_all(
            ["a", "div"],
            class_=["horizontal-row-title", "home-rows-videos-wrapper"]
        )

        for el in elements:
            classes = el.get("class", [])

            if "horizontal-row-title" in classes:
                if current_name is not None:
                    sections.append({
                        "name": current_name,
                        "url": current_url,
                        "videos": current_videos
                    })

                current_url = self.clean_url(el.get("href"))

                h3 = el.find("h3")

                current_name = ""

                if h3:
                    for child in h3.children:
                        if isinstance(child, NavigableString):
                            t = child.strip()

                            if t:
                                current_name = t
                                break

                current_videos = []

            elif "home-rows-videos-wrapper" in classes:
                for video_container in el.find_all(
                    "div",
                    class_="video-item-container"
                ):
                    link = video_container.find(
                        "a",
                        class_="video-link"
                    )

                    if not link:
                        continue

                    video_card = self._parse_video_link(link)

                    if video_card:
                        current_videos.append(video_card)

        if current_name is not None:
            sections.append({
                "name": current_name,
                "url": current_url,
                "videos": current_videos
            })

        return sections