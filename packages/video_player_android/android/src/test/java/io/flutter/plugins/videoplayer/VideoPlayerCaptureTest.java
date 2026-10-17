package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;

import android.view.Surface;
import androidx.media3.common.Format;
import androidx.media3.common.Player;
import androidx.media3.common.Timeline;
import androidx.media3.common.MediaItem;
import androidx.media3.common.VideoSize;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import androidx.media3.test.utils.FakeTimeline;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugins.videoplayer.platformview.PlatformViewVideoPlayer;
import io.flutter.plugins.videoplayer.texture.TextureVideoPlayer;
import io.flutter.view.TextureRegistry.SurfaceProducer;
import java.lang.reflect.Field;
import java.util.function.BooleanSupplier;
import org.mockito.ArgumentCaptor;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class VideoPlayerCaptureTest {
  @Test
  public void rotatedAnamorphicAndUnknownFramesAreRejectedWithoutDistortingPixels() {
    Format normal = new Format.Builder().setRotationDegrees(0).build();
    assertTrue(VideoPlayer.canCaptureFrame(new VideoSize(1080, 1920), normal));
    assertFalse(VideoPlayer.canCaptureFrame(new VideoSize(1080, 1920),
        normal.buildUpon().setRotationDegrees(90).build()));
    assertFalse(VideoPlayer.canCaptureFrame(new VideoSize(1080, 1920, 1.5f), normal));
    assertFalse(VideoPlayer.canCaptureFrame(new VideoSize(0, 0), normal));
    assertFalse(VideoPlayer.canCaptureFrame(new VideoSize(1080, 1920), null));
  }

  @Test
  public void unattachedPlatformViewAndDisposedPlayersReturnNullWithoutCapturing() {
    ExoPlayer exoPlayer = mock(ExoPlayer.class);
    VideoPlayer player = new PlatformViewVideoPlayer(mock(VideoPlayerCallbacks.class),
        MediaItem.fromUri("http://127.0.0.1/unused"), new VideoPlayerOptions(), () -> exoPlayer);
    MethodChannel.Result result = mock(MethodChannel.Result.class);
    player.captureFrame(result);
    player.dispose();
    player.captureFrame(result);
    verify(result, times(2)).success(null);
    verify(exoPlayer, never()).getVideoSize();
  }
  private static AnalyticsListener.EventTime time(MediaItem item) {
    Timeline timeline = new FakeTimeline(new FakeTimeline.TimelineWindowDefinition.Builder()
        .setMediaItem(item).build());
    return new AnalyticsListener.EventTime(0, timeline, 0, null, 0, timeline, 0, null, 0, 0);
  }

  @Test
  public void readyForNewItemCannotCaptureOldFrameUntilNewItemActuallyRenders() {
    ExoPlayer exoPlayer = mock(ExoPlayer.class);
    SurfaceProducer producer = mock(SurfaceProducer.class);
    when(producer.getSurface()).thenReturn(mock(Surface.class));
    MediaItem first = MediaItem.fromUri("http://127.0.0.1/unused/first");
    MediaItem second = MediaItem.fromUri("http://127.0.0.1/unused/second");
    VideoPlayer player = new TextureVideoPlayer(mock(VideoPlayerCallbacks.class), producer,
        first, new VideoPlayerOptions(), () -> exoPlayer);
    ArgumentCaptor<AnalyticsListener> listener = ArgumentCaptor.forClass(AnalyticsListener.class);
    verify(exoPlayer).addAnalyticsListener(listener.capture());
    listener.getValue().onRenderedFirstFrame(time(first), new Object(), 0);
    when(exoPlayer.getCurrentMediaItem()).thenReturn(second);
    when(exoPlayer.getPlaybackState()).thenReturn(Player.STATE_READY);
    when(exoPlayer.getVideoSize()).thenReturn(new VideoSize(1080, 1920));
    when(exoPlayer.getVideoFormat()).thenReturn(new Format.Builder().setRotationDegrees(0).build());
    clearInvocations(exoPlayer, producer);
    MethodChannel.Result reply = mock(MethodChannel.Result.class);
    player.captureFrame(reply);
    verify(reply).success(null);
    verify(producer, never()).getSurface();
    verify(exoPlayer, never()).getVideoSize();
    listener.getValue().onRenderedFirstFrame(time(second), new Object(), 0);
    player.captureFrame(reply);
    verify(exoPlayer).getVideoSize();
    verify(producer).getSurface();
    player.dispose();
  }

  private static FrameCapture replaceCapture(VideoPlayer player) throws Exception {
    FrameCapture capture = mock(FrameCapture.class);
    Field field = VideoPlayer.class.getDeclaredField("frameCapture");
    field.setAccessible(true);
    ((FrameCapture) field.get(player)).dispose();
    field.set(player, capture);
    return capture;
  }

  private static void markRendered(ExoPlayer player, MediaItem item) {
    ArgumentCaptor<AnalyticsListener> listener = ArgumentCaptor.forClass(AnalyticsListener.class);
    verify(player).addAnalyticsListener(listener.capture());
    listener.getValue().onRenderedFirstFrame(time(item), new Object(), 0);
    when(player.getCurrentMediaItem()).thenReturn(item);
    when(player.getVideoSize()).thenReturn(new VideoSize(1920, 1080));
    when(player.getVideoFormat()).thenReturn(new Format.Builder().setRotationDegrees(0).build());
  }

  @Test
  public void completedTexturePlaybackCanCaptureItsLastRenderedFrame() throws Exception {
    ExoPlayer exoPlayer = mock(ExoPlayer.class);
    SurfaceProducer producer = mock(SurfaceProducer.class);
    Surface surface = mock(Surface.class);
    when(producer.getSurface()).thenReturn(surface);
    MediaItem item = MediaItem.fromUri("http://127.0.0.1/ended");
    VideoPlayer player = new TextureVideoPlayer(mock(VideoPlayerCallbacks.class), producer,
        item, new VideoPlayerOptions(), () -> exoPlayer);
    FrameCapture capture = replaceCapture(player);
    markRendered(exoPlayer, item);
    when(exoPlayer.getPlaybackState()).thenReturn(Player.STATE_ENDED);
    MethodChannel.Result reply = mock(MethodChannel.Result.class);
    player.captureFrame(reply);
    verify(capture).capture(eq(surface), eq(1920), eq(1080), eq(FrameCapture.MAX_EDGE),
        any(BooleanSupplier.class), eq(reply));
    verifyNoInteractions(reply);
    player.dispose();
  }

  @Test
  public void platformSurfaceCaptureKeepsBoundAndInvalidatesWhenSurfaceChanges() throws Exception {
    ExoPlayer exoPlayer = mock(ExoPlayer.class);
    MediaItem item = MediaItem.fromUri("http://127.0.0.1/surface");
    VideoPlayer player = new PlatformViewVideoPlayer(mock(VideoPlayerCallbacks.class),
        item, new VideoPlayerOptions(), () -> exoPlayer);
    FrameCapture capture = replaceCapture(player);
    markRendered(exoPlayer, item);
    when(exoPlayer.getPlaybackState()).thenReturn(Player.STATE_ENDED);
    Surface first = mock(Surface.class);
    Surface second = mock(Surface.class);
    player.setFrameCaptureSurface(first);
    MethodChannel.Result reply = mock(MethodChannel.Result.class);
    player.captureFrame(FrameCapture.TELEVISION_MAX_EDGE, reply);
    ArgumentCaptor<BooleanSupplier> valid = ArgumentCaptor.forClass(BooleanSupplier.class);
    verify(capture).capture(eq(first), eq(1920), eq(1080), eq(640), valid.capture(), eq(reply));
    assertTrue(valid.getValue().getAsBoolean());
    player.setFrameCaptureSurface(second);
    assertFalse(valid.getValue().getAsBoolean());
    player.clearFrameCaptureSurface(first);
    player.captureFrame(FrameCapture.TELEVISION_MAX_EDGE, reply);
    verify(capture).capture(eq(second), eq(1920), eq(1080), eq(640), valid.capture(), eq(reply));
    assertTrue(valid.getValue().getAsBoolean());
    player.clearFrameCaptureSurface(second);
    assertFalse(valid.getValue().getAsBoolean());
    player.captureFrame(reply);
    verify(reply).success(null);
    player.dispose();
    player.setFrameCaptureSurface(first);
    player.captureFrame(reply);
    verify(reply, times(2)).success(null);
    verify(capture).dispose();
    verifyNoMoreInteractions(capture);
  }

  @Test
  public void captureBecomesInvalidWhenTargetMediaChangesOrPlayerDisposes() throws Exception {
    ExoPlayer exoPlayer = mock(ExoPlayer.class);
    MediaItem item = MediaItem.fromUri("http://127.0.0.1/surface");
    VideoPlayer player = new PlatformViewVideoPlayer(mock(VideoPlayerCallbacks.class),
        item, new VideoPlayerOptions(), () -> exoPlayer);
    FrameCapture capture = replaceCapture(player);
    markRendered(exoPlayer, item);
    when(exoPlayer.getPlaybackState()).thenReturn(Player.STATE_READY);
    player.setFrameCaptureSurface(mock(Surface.class));
    MethodChannel.Result reply = mock(MethodChannel.Result.class);
    player.captureFrame(reply);
    ArgumentCaptor<BooleanSupplier> valid = ArgumentCaptor.forClass(BooleanSupplier.class);
    verify(capture).capture(any(Surface.class), eq(1920), eq(1080), eq(960), valid.capture(), eq(reply));
    assertTrue(valid.getValue().getAsBoolean());
    when(exoPlayer.getCurrentMediaItem()).thenReturn(item.buildUpon().setMediaId("new").build());
    assertFalse(valid.getValue().getAsBoolean());
    when(exoPlayer.getCurrentMediaItem()).thenReturn(item);
    assertTrue(valid.getValue().getAsBoolean());
    player.dispose();
    assertFalse(valid.getValue().getAsBoolean());
  }

}
