package io.flutter.plugins.videoplayer;

import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.Timeline;
import androidx.media3.common.VideoSize;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import androidx.media3.exoplayer.source.MediaSource;
import io.flutter.plugin.common.MethodChannel;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

@UnstableApi
final class PlaybackTransition {
  final ExoPlayer player;
  final Handler handler = new Handler(Looper.getMainLooper());
  Attempt active;
  long generation;
  private boolean disposed;
  boolean renderedFirstFrame;
  String frameErrorCode = "transition_cancelled";
  String frameErrorMessage = "切集已失效";
  final Map<String, Object> lastMetrics = new HashMap<>();

  PlaybackTransition(ExoPlayer player) {
    this.player = player;
  }

  boolean pending() {
    return active != null && active.result != null;
  }

  void replace(MediaSource source, MethodChannel.Result reply) {
    replace(source, null, 0, reply);
  }

  void replace(MediaSource source, PreparedNext.Selection prepared, long requestElapsedMs,
      MethodChannel.Result reply) {
    if (disposed) {
      if (prepared != null) prepared.release();
      reply.error("transition_cancelled", "播放器已释放", null);
      return;
    }
    if (active != null) active.fail("transition_cancelled", "切集已被替换");
    generation++;
    renderedFirstFrame = false;
    frameErrorCode = "transition_cancelled";
    frameErrorMessage = "切集已失效";
    Attempt attempt = new Attempt(source.getMediaItem(), prepared, requestElapsedMs, reply);
    active = attempt;
    lastMetrics.clear();
    lastMetrics.put("transitionUsedPrepared", prepared != null);
    lastMetrics.put("transitionPreloadReady", prepared != null && prepared.ready);
    lastMetrics.put("transitionFirstFrame", false);
    lastMetrics.put("transitionGeneration", generation);
    player.addAnalyticsListener(attempt);
    handler.postDelayed(attempt.timeout, 8000);
    try {
      player.setPlayWhenReady(false);
      player.setMediaSource(source);
      player.prepare();
    } catch (RuntimeException error) {
      attempt.fail("transition_failed", error.toString());
    }
  }

  Map<String, Object> snapshot() {
    return new HashMap<>(lastMetrics);
  }

  void waitForFirstFrame(long requestedGeneration, MethodChannel.Result reply) {
    if (disposed || requestedGeneration <= 0 || requestedGeneration != generation) {
      reply.error("transition_cancelled", "切集已失效", null);
    } else if (renderedFirstFrame) {
      reply.success(frameResult(generation));
    } else if (active != null) {
      active.frameReplies.add(reply);
    } else {
      reply.error(frameErrorCode, frameErrorMessage, null);
    }
  }

  static Map<String, Object> frameResult(long generation) {
    Map<String, Object> values = new HashMap<>();
    values.put("firstFrame", true);
    values.put("generation", generation);
    return values;
  }

  void dispose() {
    disposed = true;
    renderedFirstFrame = false;
    if (active != null) active.fail("transition_cancelled", "播放器已释放");
  }

  private final class Attempt implements AnalyticsListener {
    final MediaItem item;
    final long transitionGeneration = generation;
    final List<MethodChannel.Result> frameReplies = new ArrayList<>();
    final PreparedNext.Selection prepared;
    final long requestElapsedMs;
    final long startedAt = SystemClock.elapsedRealtime();
    final Runnable timeout = () -> fail("transition_timeout", "下一集首帧等待超时");
    final Runnable readyFallback = () -> {
      readyGraceElapsed = true;
      finishIfReady();
    };
    MethodChannel.Result result;
    boolean firstFrame;
    boolean ready;
    boolean readyGraceElapsed;
    long firstFrameElapsedMs = -1;

    Attempt(MediaItem item, PreparedNext.Selection prepared, long requestElapsedMs,
        MethodChannel.Result result) {
      this.item = item;
      this.prepared = prepared;
      this.requestElapsedMs = Math.max(0, requestElapsedMs);
      this.result = result;
    }

    private boolean matches(EventTime eventTime) {
      return active == this && !eventTime.timeline.isEmpty()
          && eventTime.windowIndex >= 0
          && eventTime.windowIndex < eventTime.timeline.getWindowCount()
          && item.mediaId.equals(eventTime.timeline.getWindow(
              eventTime.windowIndex, new Timeline.Window()).mediaItem.mediaId);
    }

    @Override
    public void onPlaybackStateChanged(EventTime eventTime, int state) {
      if (!matches(eventTime)) return;
      ready = state == Player.STATE_READY;
      handler.removeCallbacks(readyFallback);
      readyGraceElapsed = false;
      if (ready) handler.postDelayed(readyFallback, 250);
      finishIfReady();
    }

    @Override
    public void onRenderedFirstFrame(EventTime eventTime, Object output, long renderTimeMs) {
      if (!matches(eventTime) || firstFrame) return;
      firstFrame = true;
      renderedFirstFrame = true;
      firstFrameElapsedMs = SystemClock.elapsedRealtime() - startedAt;
      lastMetrics.put("transitionFirstFrame", true);
      lastMetrics.put("transitionFirstFrameMs", firstFrameElapsedMs);
      lastMetrics.put("transitionRequestFirstFrameMs", requestElapsedMs + firstFrameElapsedMs);
      List<MethodChannel.Result> replies = new ArrayList<>(frameReplies);
      frameReplies.clear();
      for (MethodChannel.Result reply : replies) {
        reply.success(frameResult(transitionGeneration));
      }
      if (result == null) clear();
      else finishIfReady();
    }

    @Override
    public void onPlayerError(EventTime eventTime, PlaybackException error) {
      if (matches(eventTime) || (active == this && eventTime.timeline.isEmpty()
          && item.equals(player.getCurrentMediaItem()))) {
        fail("transition_failed", error.getErrorCodeName() + ": " + error.getMessage());
      }
    }

    private void finishIfReady() {
      if (active != this || result == null || !ready) return;
      if (player.getCurrentTracks().isTypeSupported(C.TRACK_TYPE_VIDEO)
          && !firstFrame && !readyGraceElapsed) return;
      final long duration = player.getDuration();
      if (duration == C.TIME_UNSET && !readyGraceElapsed) return;
      VideoSize size = player.getVideoSize();
      long elapsedMs = SystemClock.elapsedRealtime() - startedAt;
      Map<String, Object> values = new HashMap<>();
      values.put("durationMs", duration == C.TIME_UNSET ? 0L : duration);
      values.put("ready", true);
      values.put("firstFrame", firstFrame);
      values.put("width", size.width * size.pixelWidthHeightRatio);
      values.put("height", size.height);
      values.put("rotation", 0);
      values.put("elapsedMs", elapsedMs);
      values.put("requestElapsedMs", requestElapsedMs + elapsedMs);
      values.put("firstFrameElapsedMs", firstFrameElapsedMs);
      values.put("usedPrepared", prepared != null);
      values.put("preloadReady", prepared != null && prepared.ready);
      values.put("preloadElapsedMs", prepared == null ? 0L : prepared.elapsedMs);
      values.put("generation", prepared == null ? 0L : prepared.generation);
      values.put("transitionGeneration", transitionGeneration);
      lastMetrics.put("transitionReadyMs", elapsedMs);
      lastMetrics.put("transitionRequestReadyMs", requestElapsedMs + elapsedMs);
      MethodChannel.Result reply = result;
      result = null;
      if (prepared != null) prepared.release();
      handler.removeCallbacks(readyFallback);
      if (firstFrame) clear();
      reply.success(values);
    }

    void fail(String code, String message) {
      if (active != this) return;
      MethodChannel.Result reply = result;
      result = null;
      renderedFirstFrame = false;
      frameErrorCode = code;
      frameErrorMessage = message;
      List<MethodChannel.Result> replies = new ArrayList<>(frameReplies);
      frameReplies.clear();
      clear();
      if (reply != null) reply.error(code, message, null);
      for (MethodChannel.Result frameReply : replies) frameReply.error(code, message, null);
    }

    private void clear() {
      handler.removeCallbacks(timeout);
      handler.removeCallbacks(readyFallback);
      player.removeAnalyticsListener(this);
      if (prepared != null) prepared.release();
      if (active == this) active = null;
    }
  }
}
