package io.flutter.plugins.videoplayer;

import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import androidx.media3.common.MediaItem;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.source.MediaSource;
import androidx.media3.exoplayer.source.preload.DefaultPreloadManager;
import androidx.media3.exoplayer.source.preload.PreloadException;
import androidx.media3.exoplayer.source.preload.PreloadManagerListener;
import io.flutter.plugin.common.MethodChannel;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@UnstableApi
final class PreparedNext implements PreloadManagerListener {
  static final int BUFFER_DURATION_MS = 1500;
  static final int MAX_PRELOAD_BYTES = 8 * 1024 * 1024;
  final DefaultPreloadManager manager;
  private final Handler handler = new Handler(Looper.getMainLooper());
  private Entry next;
  Selection promoted;
  boolean disposed;

  private static final class Entry {
    final PreparedMediaRequest request;
    final MediaItem item;
    final long generation;
    final long startedAt = SystemClock.elapsedRealtime();
    final List<MethodChannel.Result> replies = new ArrayList<>();
    boolean ready;
    long elapsedMs;
    Runnable timeout;

    Entry(PreparedMediaRequest request, MediaItem item, long generation, MethodChannel.Result reply) {
      this.request = request;
      this.item = item;
      this.generation = generation;
      replies.add(reply);
    }

    Map<String, Object> result() {
      Map<String, Object> values = new HashMap<>();
      values.put("identity", request.identity);
      values.put("generation", generation);
      values.put("prepared", ready);
      values.put("elapsedMs", elapsedMs);
      return values;
    }
  }

  final class Selection {
    final MediaSource source;
    final boolean ready;
    final long elapsedMs;
    final long generation;
    private final MediaItem item;
    private boolean released;

    Selection(MediaSource source, Entry entry) {
      this.source = source;
      ready = entry.ready;
      elapsedMs = entry.ready ? entry.elapsedMs : SystemClock.elapsedRealtime() - entry.startedAt;
      generation = entry.generation;
      item = entry.item;
    }

    void release() {
      if (released) return;
      released = true;
      if (!disposed) manager.remove(item);
      if (promoted == this) promoted = null;
    }
  }

  PreparedNext(DefaultPreloadManager manager) {
    this.manager = manager;
    manager.addListener(this);
  }

  void prepare(PreparedMediaRequest request, MediaSource source, long generation,
      MethodChannel.Result reply) {
    if (disposed) {
      reply.error("player_unavailable", "播放器已释放", null);
      return;
    }
    if (next != null && next.request.equals(request)) {
      if (next.ready) reply.success(next.result());
      else next.replies.add(reply);
      return;
    }
    clear(null);
    Entry entry = new Entry(request, source.getMediaItem(), generation, reply);
    next = entry;
    entry.timeout = () -> fail(entry, "prepare_timeout", "下一集预准备超时");
    handler.postDelayed(entry.timeout, 10000);
    try {
      manager.add(source, 1);
      manager.invalidate();
    } catch (RuntimeException error) {
      fail(entry, "prepare_failed", error.toString());
    }
  }

  boolean clear(String identity) {
    Entry entry = next;
    if (entry == null || (identity != null && !identity.equals(entry.request.identity))) return false;
    fail(entry, "prepare_cancelled", "下一集预准备已取消");
    return true;
  }

  Selection take(PreparedMediaRequest request) {
    if (promoted != null) promoted.release();
    Entry entry = next;
    if (entry == null) return null;
    if (!entry.request.equals(request)) {
      clear(null);
      return null;
    }
    next = null;
    handler.removeCallbacks(entry.timeout);
    MediaSource source = manager.getMediaSource(entry.item);
    if (source == null) {
      manager.remove(entry.item);
      replyError(entry, "prepare_failed", "预准备媒体不可用");
      return null;
    }
    replyError(entry, "prepare_cancelled", "下一集已开始切换");
    promoted = new Selection(source, entry);
    return promoted;
  }

  @Override
  public void onCompleted(MediaItem item) {
    Entry entry = next;
    if (entry == null || !entry.item.equals(item)) return;
    entry.ready = true;
    entry.elapsedMs = SystemClock.elapsedRealtime() - entry.startedAt;
    handler.removeCallbacks(entry.timeout);
    List<MethodChannel.Result> replies = new ArrayList<>(entry.replies);
    entry.replies.clear();
    for (MethodChannel.Result reply : replies) reply.success(entry.result());
  }

  @Override
  public void onError(PreloadException error) {
    Entry entry = next;
    if (entry != null && entry.item.equals(error.mediaItem)) {
      fail(entry, "prepare_failed", error.getMessage());
    }
  }

  Map<String, Object> snapshot() {
    Map<String, Object> values = new HashMap<>();
    values.put("nextPrepared", next != null && next.ready);
    values.put("nextPreparing", next != null && !next.ready);
    values.put("nextGeneration", next == null ? 0L : next.generation);
    values.put("preloadSourceCount", disposed ? 0 : manager.getSourceCount());
    return values;
  }

  void dispose() {
    if (disposed) return;
    clear(null);
    if (promoted != null) promoted.release();
    disposed = true;
    handler.removeCallbacksAndMessages(null);
    manager.removeListener(this);
    manager.release();
  }

  private void fail(Entry entry, String code, String message) {
    if (next != entry) return;
    next = null;
    handler.removeCallbacks(entry.timeout);
    manager.remove(entry.item);
    replyError(entry, code, message);
  }

  private static void replyError(Entry entry, String code, String message) {
    List<MethodChannel.Result> replies = new ArrayList<>(entry.replies);
    entry.replies.clear();
    for (MethodChannel.Result reply : replies) reply.error(code, message, null);
  }
}
