"""给 MSIX 里的磁贴图重新排版（在解包出来的目录里就地改）。

为什么要单独做这一步
====================

``msix:create`` 只用一张源图（``assets/msix_logo.png``）缩放出所有尺寸，
于是 **大小中宽四种磁贴长得一模一样**：

* 磁贴会显示应用名（manifest 里的 ``ShowNameOnTiles``），
  名字画在磁贴**底部**，而我们的图标是**铺满**整块的 ——
  名字直接压在图标上，糊成一团；
* 小磁贴不该有名字，中/大/宽磁贴的名字应该画在图标下面。

所以这里按尺寸重新排：

===================  ==========================================
磁贴                 排法
===================  ==========================================
小 71x71             图标铺满（不显示名字）
中 150x150           图标缩到 56% 放上半部分，底下留给名字
大 310x310           同上
宽 310x150           同上（按高度算，水平居中）
启动画面 / 徽章 / 列表图标   图标居中，尺寸按各自惯例
===================  ==========================================

图标背景是 ``#121214``，磁贴背景色（manifest 里的 ``BackgroundColor``）
也是同一个值，所以留白的地方看起来是连成一片的，
不会出现"图标外面一圈别的颜色"。
"""

import glob
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from make_icons import BG, draw_icon  # noqa: E402

# 磁贴里图标占的比例，以及图标顶部留白占的比例。
#
# 中/大/宽磁贴底下要留给应用名（Windows 自己画），
# 所以图标缩小、往上放，name 区域留空。
TILE_ICON_RATIO = 0.56
TILE_ICON_TOP = 0.14

# 小磁贴不显示名字，图标铺满
SMALL_TILE_RATIO = 1.0

# 启动画面（620x300）：图标居中，占高度约 45%
SPLASH_RATIO = 0.45

# 列表图标 / 商店图标 / 徽章：铺满
FLAT_RATIO = 1.0


def layout_for(name):
    """按文件名决定排版：返回 (宽占比, 高占比, 顶部占比, 是否水平居中)。"""
    if name.startswith("Square71x71Logo"):
        return (SMALL_TILE_RATIO, SMALL_TILE_RATIO, 0.0)

    if name.startswith(("Square150x150Logo", "Square310x310Logo",
                        "LargeTile", "Wide310x150Logo")):
        return (TILE_ICON_RATIO, TILE_ICON_RATIO, TILE_ICON_TOP)

    if name.startswith("SplashScreen"):
        return (SPLASH_RATIO, SPLASH_RATIO, 0.5)   # 0.5 = 垂直居中

    return (FLAT_RATIO, FLAT_RATIO, 0.0)


def render(name, size):
    """按目标尺寸重新画一张。"""
    w, h = size

    ratio_w, ratio_h, top = layout_for(name)

    # 正方形图标，取宽高比例里更小的那个，保证放得下
    icon = int(min(w * ratio_w, h * ratio_h))

    if icon <= 0:
        icon = min(w, h)

    art = draw_icon(icon, rounded=True).convert("RGBA")

    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))

    left = (w - icon) // 2

    if top == 0.5:
        upper = (h - icon) // 2
    else:
        upper = int(h * top)

    canvas.alpha_composite(art, (left, upper))

    return canvas


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: make_tiles.py <unpacked-msix-dir>")

    images_dir = os.path.join(sys.argv[1], "Images")

    if not os.path.isdir(images_dir):
        raise SystemExit(f"no Images folder in {sys.argv[1]}")

    changed = 0

    for path in sorted(glob.glob(os.path.join(images_dir, "*.png"))):
        name = os.path.basename(path)

        try:
            with Image.open(path) as im:
                size = im.size

                # 已经是按比例画好的（小图/列表图）就不动，
                # 免得反复跑把图越缩越小
                if layout_for(name) == (FLAT_RATIO, FLAT_RATIO, 0.0):
                    continue
        except Exception as exc:                     # pragma: no cover
            print(f"  skip {name}: {exc}")
            continue

        render(name, size).save(path)

        changed += 1

    print(f"  re-laid out {changed} tile image(s)")


if __name__ == "__main__":
    main()
