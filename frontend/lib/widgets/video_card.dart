import 'package:flutter/material.dart';

/// 横版视频卡片的统一尺寸 / 外观。
///
/// 以前首页、搜索结果、分类页各写了一份几乎一样的卡片，
/// 但网格参数不一样（间距 16 vs 12、文字区高度 74 vs 92），
/// 个人主页和播放清单页又用了另一套（maxCrossAxisExtent + 长宽比）。
/// 结果同一个视频在不同页面里卡片大小对不上。
///
/// 现在统一到**首页那一套**：
///   列数随窗口宽度变化，卡片宽度按列均分，高度 = 宽度 / 比例 + 文字区。
/// 所有横版视频卡片都用这里的 [videoCardMetrics] 和 [VideoCard]。

/// 首页那套列数规则。
///
/// [portrait] 为 true 时用竖版栏目（新番预告之类）的列数 ——
/// 那些卡片本来就是竖的，不在"统一成首页横版尺寸"的范围内，
/// 保持原来的列数不变。
int videoCardColumns(double width, {bool portrait = false}) {
  if (portrait) {
    if (width >= 1600) return 8;
    if (width >= 1300) return 7;
    if (width >= 1000) return 5;
    if (width >= 750) return 4;
    if (width >= 500) return 2;
    return 1;
  }

  if (width >= 1600) return 6;
  if (width >= 1300) return 5;
  if (width >= 1000) return 4;
  if (width >= 750) return 3;
  if (width >= 500) return 2;
  return 1;
}

/// 一次算好列数和卡片宽高。
///
/// [extraHeight] 是缩略图下面文字区的高度（标题两行 + 一行信息）。
({int columns, double itemWidth, double itemHeight}) videoCardMetrics({
  required double maxWidth,
  double horizontalPadding = 48,
  double spacing = 16,
  double aspectRatio = 16 / 9,
  double extraHeight = 74,
  bool portrait = false,
}) {
  final columns = videoCardColumns(maxWidth, portrait: portrait);

  final available =
      maxWidth - horizontalPadding - spacing * (columns - 1);

  final itemWidth = available / columns;
  final itemHeight = itemWidth / aspectRatio + extraHeight;

  return (columns: columns, itemWidth: itemWidth, itemHeight: itemHeight);
}

/// 一张横版视频卡片（就是首页那张）。
class VideoCard extends StatelessWidget {
  final String title;
  final String thumbnail;
  final String duration;
  final String rating;
  final String views;

  /// 缩略图比例。默认 16:9；有些栏目（比如新番预告）是竖版。
  final double aspectRatio;

  final VoidCallback onTap;

  const VideoCard({
    super.key,
    required this.title,
    required this.thumbnail,
    this.duration = '',
    this.rating = '',
    this.views = '',
    this.aspectRatio = 16 / 9,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final meta = [duration, rating, views]
        .where((v) => v.isNotEmpty)
        .join(' · ');

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: aspectRatio,
              child: thumbnail.isNotEmpty
                  ? Image.network(
                      thumbnail,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: Colors.black12,
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image),
                      ),
                    )
                  : Container(
                      color: Colors.black12,
                      alignment: Alignment.center,
                      child: const Icon(Icons.image_not_supported),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (meta.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// 用首页那套尺寸铺一个横版视频卡片网格。
///
/// [videos] 里每项只要有 title / thumbnail / duration / rating / views
/// 就够了（缺的字段留空即可）。
class VideoCardGrid extends StatelessWidget {
  final List<Map<String, dynamic>> videos;
  final void Function(Map<String, dynamic> video) onTap;

  final EdgeInsets padding;

  /// 缩略图比例，默认 16:9
  final double aspectRatio;

  /// 竖版栏目（新番预告）传 true：列数和文字区高度按竖版老规矩来
  final bool portrait;

  /// 嵌在别的滚动视图里时传 true
  final bool shrinkWrap;

  const VideoCardGrid({
    super.key,
    required this.videos,
    required this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 24),
    this.aspectRatio = 16 / 9,
    this.portrait = false,
    this.shrinkWrap = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 横向留白按 padding 算，保证和首页一致
        final horizontalPadding =
            padding.left + padding.right;

        final metrics = videoCardMetrics(
          maxWidth: constraints.maxWidth,
          horizontalPadding: horizontalPadding,
          aspectRatio: aspectRatio,
          portrait: portrait,
          extraHeight: portrait ? 92 : 74,
        );

        return GridView.builder(
          shrinkWrap: shrinkWrap,
          physics: shrinkWrap
              ? const NeverScrollableScrollPhysics()
              : null,
          padding: padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: metrics.columns,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            mainAxisExtent: metrics.itemHeight,
          ),
          itemCount: videos.length,
          itemBuilder: (context, index) {
            final video = videos[index];

            return VideoCard(
              title: video['title']?.toString() ?? '',
              thumbnail: video['thumbnail']?.toString() ?? '',
              duration: video['duration']?.toString() ?? '',
              rating: video['rating']?.toString() ?? '',
              views: video['views']?.toString() ?? '',
              aspectRatio: aspectRatio,
              onTap: () => onTap(video),
            );
          },
        );
      },
    );
  }
}
