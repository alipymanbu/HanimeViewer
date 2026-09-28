import 'package:flutter/foundation.dart';

/// 让任意页面请求「回到首页」。
///
/// 影片详情页这类页面是被 push 出来的，不在主壳（MainShell）里面，
/// 没法直接切主壳的栏目。所以用一个全局信号通知主壳：
/// 主壳收到后把自己的栏目切到「首页」。
///
/// 调用方一般还要顺手把 push 出来的页面都关掉，见详情页里的用法。
class HomeRequest {
  HomeRequest._();

  /// 每请求一次 +1（用值变化触发监听，不做计数语义）
  static final ValueNotifier<int> requests = ValueNotifier<int>(0);

  static void go() {
    requests.value++;
  }
}
