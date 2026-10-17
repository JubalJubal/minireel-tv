import 'dart:async';

import 'cenc_playback_proxy.dart';

/// 进程级共享的 CENC 解密代理。
///
/// media_kit 与 ExoPlayer 两套引擎都会把 CENC 媒体先经本机代理转成
/// 明文 MP4；代理全局仅启动一份，失败后允许下次重试。
final class CencProxyPool {
  CencProxyPool._();

  static Future<CencPlaybackProxy>? _future;

  static Future<CencPlaybackProxy> acquire() async {
    final existing = _future;
    if (existing != null) return existing;
    final created = CencPlaybackProxy.start();
    _future = created;
    try {
      return await created;
    } on Object {
      _future = null;
      rethrow;
    }
  }

  static void release(Uri? url) {
    if (url == null) return;
    final future = _future;
    if (future == null) return;
    unawaited(
      future.then<void>(
        (proxy) => proxy.release(url),
        onError: (Object _) {},
      ),
    );
  }
}
