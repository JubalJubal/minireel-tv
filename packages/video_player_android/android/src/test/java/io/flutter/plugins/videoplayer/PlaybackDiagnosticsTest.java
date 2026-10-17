package io.flutter.plugins.videoplayer;

import static org.junit.Assert.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import androidx.media3.common.Format;
import androidx.media3.common.C;
import androidx.media3.exoplayer.DecoderCounters;
import androidx.media3.exoplayer.ExoPlayer;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28)
public class PlaybackDiagnosticsTest {
  @Test
  public void durationRefreshesAfterInitiallyUnknownTimeline() {
    ExoPlayer player = mock(ExoPlayer.class);
    PlaybackDiagnostics stats = new PlaybackDiagnostics(player, "surface-hybrid");
    when(player.getDuration()).thenReturn(C.TIME_UNSET);
    assertEquals(0L, stats.snapshot().get("durationMs"));
    when(player.getDuration()).thenReturn(90000L);
    assertEquals(90000L, stats.snapshot().get("durationMs"));
  }

  @Test
  public void countersSurviveDecoderRestartWithoutDoubleCountingSnapshots() {
    ExoPlayer player = mock(ExoPlayer.class);
    when(player.getVideoFormat()).thenReturn(new Format.Builder()
        .setSampleMimeType("video/avc").setFrameRate(30).build());
    PlaybackDiagnostics stats = new PlaybackDiagnostics(player, "surface-hybrid");
    DecoderCounters first = new DecoderCounters();
    first.renderedOutputBufferCount = 900;
    first.droppedBufferCount = 7;
    stats.onVideoEnabled(null, first);
    assertEquals(900, stats.snapshot().get("renderedTotal"));
    assertEquals(900, stats.snapshot().get("renderedTotal"));
    stats.onVideoDisabled(null, first);
    DecoderCounters second = new DecoderCounters();
    second.renderedOutputBufferCount = 20;
    second.droppedBufferCount = 2;
    stats.onVideoEnabled(null, second);
    stats.onVideoDecoderInitialized(null, "synthetic.vendor.avc", 1L, 12L);
    Map<String, Object> result = stats.snapshot();
    assertEquals(920, result.get("renderedTotal"));
    assertEquals(9, result.get("droppedTotal"));
    assertEquals("synthetic.vendor.avc", result.get("decoder"));
    assertEquals("unknown", result.get("hardware"));
    assertEquals(30.0, result.get("fps"));
    assertEquals("surface-hybrid", result.get("output"));
  }
}
