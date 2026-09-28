import 'package:flutter/material.dart';

/// HanimeViewer 的图标。
///
/// 按用户给的原图（一张 33x38 的小图）**绘制**，不是贴图片 ——
/// 位图放大会糊，画出来放到多大都是矢量边缘。
///
/// 原图量出来的数据：
///
/// | 项目 | 值 |
/// | --- | --- |
/// | 画布 | 33 x 38 |
/// | 底色 | `#2C2D32`（铺满整块，四角直角） |
/// | 字母 | 红色 `#DB202B` 的大写 H |
/// | H 范围 | x 10..23、y 3..34（即 13 x 31） |
/// | 笔画宽 | 4.6（H 宽的 0.354 倍） |
/// | 横杠 | y 14..19 |
///
/// [withBackground] 决定画哪一种：
/// - `true`：带深色底（33:38），像一块 App 图标；
/// - `false`（默认）：**只有红色的 H**（13:31），界面里用这个。
class HanimeLogo extends StatelessWidget {
  /// [withBackground] 为 true 时是整块的高度，否则是 H 本身的高度。
  final double height;

  /// 要不要那块深色底。
  ///
  /// 界面里默认不要 —— 只要红色的 H。
  /// 程序图标（exe / 任务栏）用的是另一套：圆角黑底，见
  /// `windows/runner/resources/app_icon.ico`。
  final bool withBackground;

  const HanimeLogo({
    super.key,
    required this.height,
    this.withBackground = false,
  });

  /// H 本身的宽高比（13 : 31）—— 这个 H 是窄高的
  static const double glyphAspectRatio = 13 / 31;

  /// 带底时的宽高比（33 : 38，沿用原图）
  static const double plateAspectRatio = 33 / 38;

  double get aspectRatio =>
      withBackground ? plateAspectRatio : glyphAspectRatio;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: height * aspectRatio,
      child: CustomPaint(
        painter: _HanimeLogoPainter(withBackground: withBackground),
        isComplex: false,
      ),
    );
  }
}

/// 侧边栏顶部的程序图标。
///
/// 单独抽出来是为了能测：这个位置前后调过好几次，而且踩过一个坑 ——
/// 直接放进侧边栏的 `Column` 里时，图标的下半截会被 `NavigationRail`
/// 的背景 `Material` 盖掉（实测只画出 12x15，少了一半）。
/// 所以它是 `Stack` 里的一个 `Positioned`，**必须排在导航后面**
/// （后画的在上层）。
///
/// 用法：放进侧边栏那个 `Stack` 的最后。
class SidebarLogo extends StatelessWidget {
  /// 离侧边栏顶部多少像素
  static const double top = 29;

  /// 图标高度
  static const double size = 30;

  /// 导航从哪里开始：图标下边缘再留一点间距。
  ///
  /// 侧边栏是**从窗口 y=0 开始**的（内容区不再给标题栏让位了），
  /// 所以这里的坐标就是窗口坐标 —— 导航必须排在图标下面，
  /// 否则第一项会被图标压住（踩过：图标在 y 29..59，
  /// 而"首页"那一项跑到了 y 52..82，正好糊在一起）。
  static const double reservedHeight = top + size + 20;

  const SidebarLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return const Positioned(
      left: 0,
      right: 0,
      top: top,
      height: size,
      // 那一带没有可点的导航项（导航从 reservedHeight 才开始），让点击穿过去
      child: IgnorePointer(
        child: Center(
          child: HanimeLogo(height: size),
        ),
      ),
    );
  }
}

class _HanimeLogoPainter extends CustomPainter {
  final bool withBackground;

  const _HanimeLogoPainter({required this.withBackground});

  // ---- 原图坐标系（33 x 38）----
  static const double _plateWidth = 33;
  static const double _plateHeight = 38;

  static const Color _plate = Color(0xFF2C2D32);
  static const Color _red = Color(0xFFDB202B);

  // H 在原图里的位置
  static const double _hLeft = 10;
  static const double _hRight = 23;
  static const double _hTop = 3;
  static const double _hBottom = 34;

  /// 笔画宽度。
  ///
  /// 原图左竖量到 5px、右竖 4px —— 那是抗锯齿造成的半像素差，
  /// 取中间值、两边用同一个数才对称。
  static const double _stroke = 4.6;

  /// 横杠上下边
  static const double _barTop = 14;
  static const double _barBottom = 19;

  static const double _hWidth = _hRight - _hLeft; // 13
  static const double _hHeight = _hBottom - _hTop; // 31

  @override
  void paint(Canvas canvas, Size size) {
    // 不带底时，把坐标系缩到 H 自己的框（13 x 31），
    // 这样控件要多大就画多大，不留无谓的空白。
    final double baseWidth;
    final double baseHeight;
    final double offsetX;
    final double offsetY;

    if (withBackground) {
      baseWidth = _plateWidth;
      baseHeight = _plateHeight;
      offsetX = 0;
      offsetY = 0;
    } else {
      baseWidth = _hWidth;
      baseHeight = _hHeight;
      offsetX = -_hLeft;
      offsetY = -_hTop;
    }

    final sx = size.width / baseWidth;
    final sy = size.height / baseHeight;

    double x(double value) => (value + offsetX) * sx;
    double y(double value) => (value + offsetY) * sy;

    if (withBackground) {
      canvas.drawRect(Offset.zero & size, Paint()..color = _plate);
    }

    final paint = Paint()
      ..color = _red
      ..isAntiAlias = true;

    // 三个矩形合成**一条路径**、只填充一次。
    //
    // 以前是三次 drawRect，结果横杠两端会比竖笔"胖"一点点 ——
    // 因为竖笔和横杠在两端是重叠的，重叠处的边缘像素被抗锯齿
    // **叠加了两次**（合成 alpha = 1-(1-a)² > a），比竖笔单独画时更实，
    // 看起来就像横杠凸出去了一截（用户就是这么报的）。
    //
    // 一条路径只光栅化一次，每个像素只有一个覆盖率，边缘就齐平了。
    final path = Path()
      // 左竖
      ..addRect(
        Rect.fromLTRB(
          x(_hLeft),
          y(_hTop),
          x(_hLeft + _stroke),
          y(_hBottom),
        ),
      )
      // 右竖
      ..addRect(
        Rect.fromLTRB(
          x(_hRight - _stroke),
          y(_hTop),
          x(_hRight),
          y(_hBottom),
        ),
      )
      // 横杠
      ..addRect(
        Rect.fromLTRB(
          x(_hLeft),
          y(_barTop),
          x(_hRight),
          y(_barBottom),
        ),
      );

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_HanimeLogoPainter oldDelegate) =>
      oldDelegate.withBackground != withBackground;
}
