package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.net.Uri;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.source.MediaSource;
import java.util.Collections;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicLong;

@UnstableApi
final class PreparedMediaRequest {
  private static final AtomicLong generations = new AtomicLong();
  final String identity;
  final String url;
  final String mimeType;
  final Map<String, String> headers;

  PreparedMediaRequest(String identity, String url, Map<String, String> headers, String mediaType) {
    if (url == null || url.isEmpty()) throw new IllegalArgumentException("播放地址为空");
    this.identity = identity == null ? url : identity;
    this.url = url;
    this.headers = Collections.unmodifiableMap(new HashMap<>(
        headers == null ? Collections.emptyMap() : headers));
    mimeType = resolveMimeType(url, mediaType);
  }

  static long nextGeneration() {
    return generations.incrementAndGet();
  }

  MediaSource createSource(Context context, long generation) {
    VideoAsset.StreamingFormat format = VideoAsset.StreamingFormat.UNKNOWN;
    if (MimeTypes.APPLICATION_M3U8.equals(mimeType)) format = VideoAsset.StreamingFormat.HTTP_LIVE;
    if (MimeTypes.APPLICATION_MPD.equals(mimeType)) format = VideoAsset.StreamingFormat.DYNAMIC_ADAPTIVE;
    if (MimeTypes.APPLICATION_SS.equals(mimeType)) format = VideoAsset.StreamingFormat.SMOOTH;
    VideoAsset asset = VideoAsset.fromRemoteUrl(url, format, headers, null);
    MediaItem item = asset.getMediaItem().buildUpon()
        .setMediaId("hongguo:" + generation).setMimeType(mimeType).build();
    return asset.getMediaSourceFactory(context).createMediaSource(item);
  }

  private static String resolveMimeType(String url, String type) {
    String normalized = type == null ? "" : type.trim().toLowerCase(Locale.ROOT);
    switch (normalized) {
      case "hls":
      case "m3u8":
      case "application/x-mpegurl":
      case "application/vnd.apple.mpegurl": return MimeTypes.APPLICATION_M3U8;
      case "mp4":
      case "video/mp4": return MimeTypes.VIDEO_MP4;
      case "dash":
      case "application/dash+xml": return MimeTypes.APPLICATION_MPD;
      case "ss":
      case "application/vnd.ms-sstr+xml": return MimeTypes.APPLICATION_SS;
      default:
        String path = Uri.parse(url).getPath();
        if (path == null) return null;
        path = path.toLowerCase(Locale.ROOT);
        if (path.endsWith(".m3u8")) return MimeTypes.APPLICATION_M3U8;
        if (path.endsWith(".mpd")) return MimeTypes.APPLICATION_MPD;
        if (path.endsWith(".mp4")) return MimeTypes.VIDEO_MP4;
        return null;
    }
  }

  @Override
  public boolean equals(Object other) {
    if (!(other instanceof PreparedMediaRequest)) return false;
    PreparedMediaRequest request = (PreparedMediaRequest) other;
    return identity.equals(request.identity) && url.equals(request.url)
        && headers.equals(request.headers) && Objects.equals(mimeType, request.mimeType);
  }

  @Override
  public int hashCode() {
    return Objects.hash(identity, url, headers, mimeType);
  }
}
