package io.flutter.plugins.videoplayer;

import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.os.Build;
import androidx.media3.common.Format;
import androidx.media3.common.MediaItem;
import androidx.media3.common.Timeline;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.DecoderCounters;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import java.util.LinkedHashMap;
import java.util.Map;

@UnstableApi
final class PlaybackDiagnostics implements AnalyticsListener {
  private final ExoPlayer player;
  private final String output;
  private final DecoderCounters finishedCounters = new DecoderCounters();
  private DecoderCounters activeCounters;
  private String decoder = "pending";
  private String hardware = "unknown";
  private String codecError = "none";
  private long decoderInitMs;
  private MediaItem renderedMediaItem;

  PlaybackDiagnostics(ExoPlayer player, String output) {
    this.player = player;
    this.output = output;
    player.addAnalyticsListener(this);
  }

  @Override
  public void onRenderedFirstFrame(EventTime eventTime, Object output, long renderTimeMs) {
    if (!eventTime.timeline.isEmpty() && eventTime.windowIndex >= 0
        && eventTime.windowIndex < eventTime.timeline.getWindowCount()) {
      renderedMediaItem = eventTime.timeline.getWindow(
          eventTime.windowIndex, new Timeline.Window()).mediaItem;
    }
  }

  boolean hasFrameFor(MediaItem item) {
    return item != null && item.equals(renderedMediaItem);
  }

  @Override
  public void onVideoEnabled(EventTime eventTime, DecoderCounters counters) {
    activeCounters = counters;
  }

  @Override
  public void onVideoDisabled(EventTime eventTime, DecoderCounters counters) {
    counters.ensureUpdated();
    finishedCounters.merge(counters);
    activeCounters = null;
  }

  @Override
  public void onVideoDecoderInitialized(
      EventTime eventTime, String decoderName, long initializedTimestampMs,
      long initializationDurationMs) {
    decoder = decoderName;
    decoderInitMs = initializationDurationMs;
    hardware = "unknown";
    if (Build.VERSION.SDK_INT >= 29) {
      try {
        for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
          if (info.getName().equals(decoderName) || info.getCanonicalName().equals(decoderName)) {
            hardware = Boolean.toString(info.isHardwareAccelerated());
            break;
          }
        }
      } catch (RuntimeException ignored) {
      }
    }
  }

  @Override
  public void onVideoCodecError(EventTime eventTime, Exception error) {
    codecError = error.getClass().getSimpleName() + ":" + error.getMessage();
  }

  Map<String, Object> snapshot() {
    DecoderCounters counters = new DecoderCounters();
    counters.merge(finishedCounters);
    if (activeCounters != null) {
      activeCounters.ensureUpdated();
      counters.merge(activeCounters);
    }
    Format format = player.getVideoFormat();
    Map<String, Object> values = new LinkedHashMap<>();
    values.put("output", output);
    values.put("decoder", decoder);
    values.put("hardware", hardware);
    values.put("decoderInitMs", decoderInitMs);
    values.put("codecError", codecError);
    values.put("mime", format == null ? "unknown" : format.sampleMimeType);
    values.put("codecs", format == null ? "unknown" : format.codecs);
    values.put("fps", format == null ? -1.0 : (double) format.frameRate);
    values.put("renderedTotal", counters.renderedOutputBufferCount);
    values.put("droppedTotal", counters.droppedBufferCount);
    values.put("skippedTotal", counters.skippedOutputBufferCount);
    values.put("maxConsecutiveDrops", counters.maxConsecutiveDroppedBufferCount);
    values.put("droppedToKeyframe", counters.droppedToKeyframeCount);
    values.put("decoderInitCount", counters.decoderInitCount);
    values.put("processingOffsetAvgUs", counters.videoFrameProcessingOffsetCount == 0 ? 0L
        : counters.totalVideoFrameProcessingOffsetUs / counters.videoFrameProcessingOffsetCount);
    values.put("durationMs", Math.max(0L, player.getDuration()));
    values.put("positionMs", player.getCurrentPosition());
    values.put("bufferedAheadMs", Math.max(0L, player.getBufferedPosition() - player.getCurrentPosition()));
    values.put("playing", player.isPlaying());
    values.put("state", player.getPlaybackState());
    return values;
  }
}
