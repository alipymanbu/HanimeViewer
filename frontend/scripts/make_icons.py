"""生成程序图标。

一次生成两个文件，它们的用途不同，所以画法也不同：

1. ``frontend/windows/runner/resources/app_icon.ico``
   exe 内嵌图标 / 任务栏 / 窗口。**带圆角**（这里没有 Windows 的磁贴，
   圆角看起来更像一个应用图标）。写进 exe 是 7 个尺寸。

2. ``frontend/assets/msix_logo.png``
   MSIX 安装包用它生成开始菜单磁贴和各处图标。
   **不带圆角、整块铺满、四周不留任何透明**：
   Windows 会把这套图放进自己的磁贴底板里，图片本身只要有透明边，
   底板的边就会从那一圈透出来 —— 看起来就是"图标很小、外面一圈留白"。
   另外 Windows 自己会给磁贴切圆角，这里不需要自己切。

   形状沿用用户给的原图：H 的范围是 x 10..23、y 3..34（13 x 31），
   笔画 4.6，横杠 y 14..19。**H 占的高度比例调大了**
   （原图 31/38 ≈ 82%，早先这里用的是 64%）—— H 本来就是个窄高的字，
   在小尺寸下（开始菜单会取到 16/24/32）太细就看不清了。

需要 Pillow：``pip install pillow``
"""

import os

from PIL import Image, ImageDraw

RED = (219, 32, 43, 255)        # #DB202B
BG = (18, 18, 20, 255)          # #121214 近黑

# 原图里 H 的几何（33x38 的画布）
H_W, H_H = 13.0, 31.0
H_STROKE = 4.6
BAR_TOP, BAR_BOTTOM = 14.0, 19.0
H_TOP = 3.0

# H 占图标高度的比例。
#
# 原图是 31/38 ≈ 0.82；.ico 也用同一个值（不再额外缩一圈）。
GLYPH_RATIO = 0.82

# 圆角半径占边长的比例（只有 .ico 用）
ICON_CORNER = 0.22

HERE = os.path.dirname(os.path.abspath(__file__))
FRONTEND = os.path.dirname(HERE)

ICO_PATH = os.path.join(
    FRONTEND, "windows", "runner", "resources", "app_icon.ico"
)
MSIX_LOGO_PATH = os.path.join(FRONTEND, "assets", "msix_logo.png")

ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]


def draw_icon(size, rounded=True, bg=BG):
    """画一张 size x size 的图标。

    4 倍超采样再缩小：小尺寸下（16px）直接画的话边缘会很难看。
    """
    s = size * 4

    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    if bg is not None:
        if rounded:
            d.rounded_rectangle(
                [0, 0, s - 1, s - 1], radius=s * ICON_CORNER, fill=bg
            )
        else:
            # 整块铺满，一个透明像素都不留
            d.rectangle([0, 0, s - 1, s - 1], fill=bg)

    # 按原图的 H 比例从高度推宽度（H 是窄高的：13 : 31）
    hh = s * GLYPH_RATIO
    hw = hh * (H_W / H_H)
    stroke = hw * (H_STROKE / H_W)

    left = (s - hw) / 2
    top = (s - hh) / 2
    right = left + hw
    bottom = top + hh

    # 横杠在原图里的相对位置，换算到这里的 H 上
    bar_top = top + hh * ((BAR_TOP - H_TOP) / H_H)
    bar_bottom = top + hh * ((BAR_BOTTOM - H_TOP) / H_H)

    d.rectangle([left, top, left + stroke, bottom], fill=RED)        # 左竖
    d.rectangle([right - stroke, top, right, bottom], fill=RED)      # 右竖
    d.rectangle([left, bar_top, right, bar_bottom], fill=RED)        # 横杠

    return img.resize((size, size), Image.LANCZOS)


def main():
    # ---- 1. .ico（exe / 任务栏 / 窗口），带圆角 ----
    os.makedirs(os.path.dirname(ICO_PATH), exist_ok=True)

    frames = [draw_icon(s) for s in ICO_SIZES]

    frames[-1].save(
        ICO_PATH,
        format="ICO",
        sizes=[(s, s) for s in ICO_SIZES],
        append_images=frames[:-1],
    )

    print(f"wrote {ICO_PATH}  ({os.path.getsize(ICO_PATH)} bytes)")

    # ---- 2. MSIX 用的大图：带圆角（**必须有透明**，见下）----
    os.makedirs(os.path.dirname(MSIX_LOGO_PATH), exist_ok=True)

    logo = draw_icon(512, rounded=True)

    # 一定要有透明像素，**不能**画成一整块不透明的方块。
    #
    # msix 包生成磁贴时会先调 image 包的 trim()，那是"去掉四边同色的边框"：
    # 如果源图是一整块不透明的黑方块，黑边会被当成边框裁掉，
    # 只剩中间那个 H，再放大铺满整块磁贴 —— 结果颜色整个反过来
    # （红底黑 H，实测踩到过）。
    #
    # 四角留透明（圆角）就不会被裁：trim 的包围盒仍然是整张图。
    if logo.getbbox() != (0, 0, 512, 512):
        raise SystemExit("msix_logo.png lost its full-frame bounding box")

    logo.save(MSIX_LOGO_PATH)

    print(
        f"wrote {MSIX_LOGO_PATH}  ({os.path.getsize(MSIX_LOGO_PATH)} bytes)"
    )

    # ---- 预览图，方便肉眼确认 ----
    preview = Image.new("RGB", (620, 320), (245, 245, 248))
    preview.paste(draw_icon(256, rounded=True).convert("RGBA"), (30, 22))

    small = Image.new("RGB", (360, 100), (245, 245, 248))

    x = 10
    for size in [16, 24, 32, 48, 64]:
        icon = draw_icon(size, rounded=True).convert("RGBA")
        small.paste(icon, (x, 50 - size // 2), icon)
        x += size + 14

    preview.paste(small, (310, 22))

    out = os.path.join(os.environ.get("TEMP", "."), "hv_icon_preview.png")
    preview.save(out)

    print(f"wrote {out}")


if __name__ == "__main__":
    main()
