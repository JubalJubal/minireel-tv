package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;

import android.content.Context;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.ExoPlaybackException;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.LoadingInfo;
import androidx.media3.datasource.TransferListener;
import androidx.media3.exoplayer.drm.DrmSessionManager;
import androidx.media3.exoplayer.drm.DrmSessionEventListener;
import androidx.media3.exoplayer.source.MediaPeriod;
import androidx.media3.exoplayer.source.MediaSourceEventListener;
import androidx.media3.exoplayer.source.TrackGroupArray;
import androidx.media3.exoplayer.upstream.Allocator;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.RenderersFactory;
import androidx.media3.test.utils.FakeMediaPeriod;
import androidx.media3.test.utils.FakeMediaSource;
import androidx.media3.test.utils.FakeRenderer;
import androidx.media3.test.utils.FakeTimeline;
import androidx.test.core.app.ApplicationProvider;
import io.flutter.plugin.common.MethodChannel;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BooleanSupplier;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowLooper;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class PreparedPlaybackIntegrationTest {
  private static final class EnabledRenderers {
    final AtomicInteger active = new AtomicInteger();
    final AtomicInteger peak = new AtomicInteger();
  }

  private static final class CountingRenderer extends FakeRenderer {
    final EnabledRenderers counts;

    CountingRenderer(EnabledRenderers counts) {
      super(C.TRACK_TYPE_VIDEO);
      this.counts = counts;
    }

    @Override
    protected void onEnabled(boolean joining, boolean mayRenderStartOfStream) throws ExoPlaybackException {
      super.onEnabled(joining, mayRenderStartOfStream);
      int active = counts.active.incrementAndGet();
      counts.peak.accumulateAndGet(active, Math::max);
    }

    @Override
    protected void onDisabled() {
      counts.active.decrementAndGet();
      super.onDisabled();
    }
  }

  private static final class Reply implements MethodChannel.Result {
    Object value;
    String error;

    @Override
    public void success(Object value) {
      this.value = value;
    }

    @Override
    public void error(String code, String message, Object details) {
      error = code;
    }

    @Override
    public void notImplemented() {
      error = "not_implemented";
    }
  }

  private static FakeMediaSource source(String id) {
    MediaItem item = new MediaItem.Builder().setUri("http://127.0.0.1/unused/" + id).setMediaId(id).build();
    FakeTimeline timeline = new FakeTimeline(new FakeTimeline.TimelineWindowDefinition.Builder()
        .setMediaItem(item).setUid(id).setDurationUs(5_000_000)
        .setDefaultPositionUs(0).setWindowPositionInFirstPeriodUs(0).build());
    return new FakeMediaSource(timeline,
        new Format.Builder().setSampleMimeType(MimeTypes.VIDEO_H264).build()) {
      @Override
      protected MediaPeriod createMediaPeriod(MediaPeriodId id, TrackGroupArray tracks,
          Allocator allocator, MediaSourceEventListener.EventDispatcher events,
          DrmSessionManager drm, DrmSessionEventListener.EventDispatcher drmEvents,
          TransferListener transfer) {
        return new FakeMediaPeriod(tracks, allocator,
            FakeMediaPeriod.TrackDataFactory.samplesWithRateDurationAndKeyframeInterval(
                0, 30f, 5_000_000, 1), events, drm, drmEvents, false) {
          private Callback callback;

          @Override
          public synchronized void prepare(Callback callback, long positionUs) {
            this.callback = callback;
            super.prepare(callback, positionUs);
          }

          @Override
          public boolean continueLoading(LoadingInfo loadingInfo) {
            boolean loaded = super.continueLoading(loadingInfo);
            if (loaded) callback.onContinueLoadingRequested(this);
            return loaded;
          }
        };
      }
    };
  }

  private static void await(BooleanSupplier condition) throws Exception {
    long deadline = System.nanoTime() + 10_000_000_000L;
    while (!condition.getAsBoolean()) {
      if (System.nanoTime() >= deadline) fail("Synthetic Media3 condition timed out");
      ShadowLooper.idleMainLooper();
      Thread.sleep(1);
    }
  }

  @Test
  public void realManagerTransfersLoadedPeriodAndRemovingPreloadKeepsPlaybackAlive() throws Exception {
    Context context = ApplicationProvider.getApplicationContext();
    EnabledRenderers counts = new EnabledRenderers();
    RenderersFactory renderers = (handler, video, audio, text, metadata) ->
        new Renderer[] {new CountingRenderer(counts)};
    PreparedPlayerProvider provider = new PreparedPlayerProvider(context,
        new FakeVideoAsset("http://127.0.0.1/unused"), new VideoPlayerOptions(), renderers);
    ExoPlayer player = provider.get();
    assertSame(player, provider.get());
    FakeMediaSource first = source("first");
    FakeMediaSource next = source("second");
    try {
      player.setMediaSource(first);
      player.prepare();
      await(() -> player.getPlaybackState() == Player.STATE_READY);
      assertEquals(1, counts.active.get());
      PreparedMediaRequest request = new PreparedMediaRequest("session-2",
          "http://127.0.0.1/unused/second", null, "mp4");
      Reply reply = new Reply();
      provider.preparedNext.prepare(request, next, 1, reply);
      await(() -> reply.value != null || reply.error != null);
      assertNull(reply.error);
      assertEquals("first", player.getCurrentMediaItem().mediaId);
      assertEquals(1, player.getMediaItemCount());
      assertEquals(1, next.getCreatedMediaPeriods().size());
      assertEquals(1, counts.active.get());
      assertEquals(1, counts.peak.get());
      assertFalse(player.getPlayWhenReady());
      assertNull(player.getSecondaryRenderer(0));
      PreparedNext.Selection selection = provider.preparedNext.take(request);
      assertNotNull(selection);
      assertTrue(selection.ready);
      player.setMediaSource(selection.source);
      player.prepare();
      await(() -> player.getPlaybackState() == Player.STATE_READY);
      assertEquals("second", player.getCurrentMediaItem().mediaId);
      assertEquals(1, next.getCreatedMediaPeriods().size());
      selection.release();
      player.createMessage((type, payload) -> {}).send().blockUntilDelivered(5000);
      ShadowLooper.idleMainLooper();
      assertTrue(next.isPrepared());
      assertNotNull(next.getLastCreatedActiveMediaPeriod());
      assertEquals(Player.STATE_READY, player.getPlaybackState());
      assertNull(player.getPlayerError());
      assertEquals(1, counts.peak.get());
      assertEquals(0, provider.preparedNext.snapshot().get("preloadSourceCount"));
      player.play();
      ShadowLooper.idleMainLooper(100, java.util.concurrent.TimeUnit.MILLISECONDS);
      await(() -> player.getCurrentPosition() > 0);
      assertEquals(Player.STATE_READY, player.getPlaybackState());
      player.pause();
      assertFalse(player.getPlayWhenReady());
    } finally {
      player.release();
      provider.preparedNext.dispose();
    }
    assertEquals(0, counts.active.get());
    next.assertReleased();
    first.assertReleased();
  }
}
