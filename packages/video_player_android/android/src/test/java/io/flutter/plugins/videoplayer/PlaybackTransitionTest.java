package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;

import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.Timeline;
import androidx.media3.common.Tracks;
import androidx.media3.common.VideoSize;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import androidx.media3.exoplayer.source.MediaSource;
import io.flutter.plugin.common.MethodChannel;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.ArgumentCaptor;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowLooper;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class PlaybackTransitionTest {
  private ExoPlayer player;
  private PlaybackTransition transition;
  private MethodChannel.Result result;
  private MediaSource source;
  private MediaItem item;

  @Before
  public void setUp() {
    player = mock(ExoPlayer.class);
    Tracks tracks = mock(Tracks.class);
    when(tracks.isTypeSupported(C.TRACK_TYPE_VIDEO)).thenReturn(true);
    when(player.getCurrentTracks()).thenReturn(tracks);
    when(player.getDuration()).thenReturn(90000L);
    when(player.getVideoSize()).thenReturn(new VideoSize(1920, 1080));
    item = new MediaItem.Builder().setUri("http://127.0.0.1/synthetic").setMediaId("first").build();
    source = source(item);
    result = mock(MethodChannel.Result.class);
    transition = new PlaybackTransition(player);
  }

  private static MediaSource source(MediaItem item) {
    MediaSource source = mock(MediaSource.class);
    when(source.getMediaItem()).thenReturn(item);
    return source;
  }

  private AnalyticsListener listener() {
    ArgumentCaptor<AnalyticsListener> capture = ArgumentCaptor.forClass(AnalyticsListener.class);
    verify(player, atLeastOnce()).addAnalyticsListener(capture.capture());
    return capture.getValue();
  }

  private static AnalyticsListener.EventTime time(MediaItem item) {
    Timeline timeline = mock(Timeline.class);
    when(timeline.getWindowCount()).thenReturn(1);
    when(timeline.isEmpty()).thenReturn(false);
    when(timeline.getWindow(eq(0), any(Timeline.Window.class))).thenAnswer(invocation -> {
      Timeline.Window window = invocation.getArgument(1);
      window.mediaItem = item;
      return window;
    });
    return new AnalyticsListener.EventTime(0, timeline, 0, null, 0, timeline, 0, null, 0, 0);
  }

  private void ready(AnalyticsListener listener) {
    listener.onPlaybackStateChanged(time(item), Player.STATE_READY);
  }

  private void frame(AnalyticsListener listener) {
    listener.onRenderedFirstFrame(time(item), new Object(), 0);
  }

  @Test
  public void readyWaitsForActualFirstFrameWithoutReleasingPlayerOrSurface() {
    transition.replace(source, result);
    AnalyticsListener listener = listener();
    verify(player).setPlayWhenReady(false);
    verify(player).setMediaSource(source);
    verify(player).prepare();
    ready(listener);
    verifyNoInteractions(result);
    assertTrue(transition.pending());
    frame(listener);
    verify(result).success(argThat(value -> Boolean.TRUE.equals(((Map<?, ?>) value).get("firstFrame"))
        && ((Map<?, ?>) value).get("durationMs").equals(90000L)));
    assertFalse(transition.pending());
    verify(player, never()).release();
    verify(player, never()).clearVideoSurface();
    frame(listener);
    verify(result, times(1)).success(any());
  }

  @Test
  public void timeoutAndDisposeReplyOnceAndDetachListener() {
    transition.replace(source, result);
    AnalyticsListener listener = listener();
    ShadowLooper.idleMainLooper(8, TimeUnit.SECONDS);
    verify(result).error(eq("transition_timeout"), anyString(), isNull());
    verify(player).removeAnalyticsListener(listener);
    assertFalse(transition.pending());
    transition.dispose();
    frame(listener);
    verify(result, never()).success(any());
    verifyNoMoreInteractions(result);
  }

  @Test
  public void readyFallbackReportsNoFrameAndRecordsActualFrameLater() {
    transition.replace(source, null, 450, result);
    AnalyticsListener listener = listener();
    ready(listener);
    ShadowLooper.idleMainLooper(250, TimeUnit.MILLISECONDS);
    verify(result).success(argThat(value ->
        Boolean.FALSE.equals(((Map<?, ?>) value).get("firstFrame"))
            && Boolean.TRUE.equals(((Map<?, ?>) value).get("ready"))
            && ((Long) ((Map<?, ?>) value).get("requestElapsedMs")) >= 700));
    assertFalse(transition.pending());
    assertFalse((Boolean) transition.snapshot().get("transitionFirstFrame"));
    ShadowLooper.idleMainLooper(100, TimeUnit.MILLISECONDS);
    frame(listener);
    assertTrue((Boolean) transition.snapshot().get("transitionFirstFrame"));
    assertEquals(350L, transition.snapshot().get("transitionFirstFrameMs"));
    assertEquals(800L, transition.snapshot().get("transitionRequestFirstFrameMs"));
    verify(player).removeAnalyticsListener(listener);
    ShadowLooper.idleMainLooper(8, TimeUnit.SECONDS);
    frame(listener);
    verify(result, times(1)).success(any());
    verify(result, never()).error(anyString(), anyString(), any());
  }

  @Test
  public void bufferingCancelsReadyGraceUntilReadyAgain() {
    transition.replace(source, result);
    AnalyticsListener listener = listener();
    ready(listener);
    listener.onPlaybackStateChanged(time(item), Player.STATE_BUFFERING);
    ShadowLooper.idleMainLooper(300, TimeUnit.MILLISECONDS);
    verifyNoInteractions(result);
    ready(listener);
    ShadowLooper.idleMainLooper(250, TimeUnit.MILLISECONDS);
    verify(result).success(any());
  }

  @Test
  public void unknownDurationDoesNotPreventPreparedMediaFromStarting() {
    when(player.getDuration()).thenReturn(C.TIME_UNSET);
    transition.replace(source, result);
    AnalyticsListener listener = listener();
    ready(listener);
    frame(listener);
    ShadowLooper.idleMainLooper(250, TimeUnit.MILLISECONDS);
    verify(result).success(argThat(value -> ((Map<?, ?>) value).get("durationMs").equals(0L)));
  }

  @Test
  public void replacementAndReversedSwitchRejectCallbacksFromOlderGenerations() {
    transition.replace(source, result);
    AnalyticsListener previous = listener();
    MediaItem nextItem = item.buildUpon().setMediaId("second").build();
    MethodChannel.Result next = mock(MethodChannel.Result.class);
    transition.replace(source(nextItem), next);
    AnalyticsListener current = listener();
    verify(result).error(eq("transition_cancelled"), anyString(), isNull());
    previous.onRenderedFirstFrame(time(item), new Object(), 0);
    ready(previous);
    current.onRenderedFirstFrame(time(item), new Object(), 0);
    ready(current);
    current.onPlayerError(time(item), new PlaybackException("stale", null, 1000));
    verifyNoInteractions(next);
    current.onPlaybackStateChanged(time(nextItem), Player.STATE_READY);
    current.onRenderedFirstFrame(time(nextItem), new Object(), 0);
    verify(next).success(any());
    MethodChannel.Result reversed = mock(MethodChannel.Result.class);
    MediaItem reversedItem = item.buildUpon().setMediaId("third").build();
    transition.replace(source(reversedItem), reversed);
    AnalyticsListener latest = listener();
    latest.onRenderedFirstFrame(time(item), new Object(), 0);
    latest.onPlaybackStateChanged(time(item), Player.STATE_READY);
    verifyNoInteractions(reversed);
    latest.onPlaybackStateChanged(time(reversedItem), Player.STATE_READY);
    latest.onRenderedFirstFrame(time(reversedItem), new Object(), 0);
    verify(reversed).success(any());
  }

  @Test
  public void preparationExceptionReportsFailureWithoutReleasingExistingPlayer() {
    doThrow(new IllegalStateException("synthetic failure")).when(player).prepare();
    transition.replace(source, result);
    verify(result).error(eq("transition_failed"), anyString(), isNull());
    assertFalse(transition.pending());
    verify(player, never()).release();
    verify(player, never()).clearVideoSurface();
  }

  @Test
  public void playerErrorAndDisposeClearTimersAndReplyOnce() {
    transition.replace(source, result);
    listener().onPlayerError(time(item), new PlaybackException("synthetic", null, 1000));
    verify(result).error(eq("transition_failed"), anyString(), isNull());
    ShadowLooper.idleMainLooper(8, TimeUnit.SECONDS);
    transition.dispose();
    verifyNoMoreInteractions(result);
  }
  private long generation() {
    return (Long) transition.snapshot().get("transitionGeneration");
  }

  @Test
  public void frameWaitSurvivesReadyFallbackAndOnlyCompletesForMatchingTarget() {
    transition.replace(source, result);
    long generation = generation();
    AnalyticsListener listener = listener();
    ready(listener);
    ShadowLooper.idleMainLooper(250, TimeUnit.MILLISECONDS);
    MethodChannel.Result frameReply = mock(MethodChannel.Result.class);
    transition.waitForFirstFrame(generation, frameReply);
    verifyNoInteractions(frameReply);
    MediaItem stale = item.buildUpon().setMediaId("stale").build();
    listener.onRenderedFirstFrame(time(stale), new Object(), 0);
    ShadowLooper.idleMainLooper(100, TimeUnit.MILLISECONDS);
    verifyNoInteractions(frameReply);
    frame(listener);
    verify(frameReply).success(argThat(value ->
        Boolean.TRUE.equals(((Map<?, ?>) value).get("firstFrame"))
            && ((Long) ((Map<?, ?>) value).get("generation")) == generation));
    frame(listener);
    ShadowLooper.idleMainLooper(8, TimeUnit.SECONDS);
    verifyNoMoreInteractions(frameReply);
    verify(result, times(1)).success(any());
  }

  @Test
  public void completedFrameIsAvailableOnlyUntilReplacementOrDispose() {
    transition.replace(source, result);
    long completed = generation();
    AnalyticsListener first = listener();
    ready(first);
    frame(first);
    MethodChannel.Result alreadyRendered = mock(MethodChannel.Result.class);
    transition.waitForFirstFrame(completed, alreadyRendered);
    verify(alreadyRendered).success(argThat(value ->
        Boolean.TRUE.equals(((Map<?, ?>) value).get("firstFrame"))));
    MediaItem replacement = item.buildUpon().setMediaId("replacement").build();
    transition.replace(source(replacement), mock(MethodChannel.Result.class));
    assertTrue(generation() > completed);
    MethodChannel.Result stale = mock(MethodChannel.Result.class);
    transition.waitForFirstFrame(completed, stale);
    verify(stale).error(eq("transition_cancelled"), anyString(), isNull());
    AnalyticsListener latest = listener();
    latest.onPlaybackStateChanged(time(replacement), Player.STATE_READY);
    latest.onRenderedFirstFrame(time(replacement), new Object(), 0);
    transition.dispose();
    MethodChannel.Result disposed = mock(MethodChannel.Result.class);
    transition.waitForFirstFrame(generation(), disposed);
    verify(disposed).error(eq("transition_cancelled"), anyString(), isNull());
  }

  @Test
  public void frameWaitDeadlineIsAbsoluteAndLateWaitKeepsTimeoutOutcome() {
    transition.replace(source, result);
    AnalyticsListener listener = listener();
    ready(listener);
    ShadowLooper.idleMainLooper(7, TimeUnit.SECONDS);
    MethodChannel.Result frameReply = mock(MethodChannel.Result.class);
    transition.waitForFirstFrame(generation(), frameReply);
    verifyNoInteractions(frameReply);
    ShadowLooper.idleMainLooper(1, TimeUnit.SECONDS);
    verify(frameReply).error(eq("transition_timeout"), anyString(), isNull());
    MethodChannel.Result late = mock(MethodChannel.Result.class);
    transition.waitForFirstFrame(generation(), late);
    verify(late).error(eq("transition_timeout"), anyString(), isNull());
    frame(listener);
    verifyNoMoreInteractions(frameReply, late);
    verify(result, never()).error(anyString(), anyString(), any());
  }

  @Test
  public void replacementCancelsAllPendingFrameWaitsAndRejectsOldCallbacks() {
    transition.replace(source, result);
    AnalyticsListener previous = listener();
    ready(previous);
    ShadowLooper.idleMainLooper(250, TimeUnit.MILLISECONDS);
    long previousGeneration = generation();
    MethodChannel.Result firstWait = mock(MethodChannel.Result.class);
    MethodChannel.Result secondWait = mock(MethodChannel.Result.class);
    transition.waitForFirstFrame(previousGeneration, firstWait);
    transition.waitForFirstFrame(previousGeneration, secondWait);
    MediaItem replacement = item.buildUpon().setMediaId("replacement").build();
    transition.replace(source(replacement), mock(MethodChannel.Result.class));
    verify(firstWait).error(eq("transition_cancelled"), anyString(), isNull());
    verify(secondWait).error(eq("transition_cancelled"), anyString(), isNull());
    MethodChannel.Result latestWait = mock(MethodChannel.Result.class);
    transition.waitForFirstFrame(generation(), latestWait);
    frame(previous);
    frame(listener());
    verifyNoInteractions(latestWait);
    listener().onRenderedFirstFrame(time(replacement), new Object(), 0);
    verify(latestWait).success(any());
    verifyNoMoreInteractions(firstWait, secondWait);
    transition.dispose();
  }

  @Test
  public void errorsAndDisposalCompleteFrameWaitExactlyOnceAfterReady() {
    transition.replace(source, result);
    AnalyticsListener listener = listener();
    ready(listener);
    ShadowLooper.idleMainLooper(250, TimeUnit.MILLISECONDS);
    MethodChannel.Result frameReply = mock(MethodChannel.Result.class);
    transition.waitForFirstFrame(generation(), frameReply);
    listener.onPlayerError(time(item), new PlaybackException("synthetic", null, 1000));
    verify(frameReply).error(eq("transition_failed"), anyString(), isNull());
    MethodChannel.Result late = mock(MethodChannel.Result.class);
    transition.waitForFirstFrame(generation(), late);
    verify(late).error(eq("transition_failed"), anyString(), isNull());
    frame(listener);
    transition.dispose();
    ShadowLooper.idleMainLooper(8, TimeUnit.SECONDS);
    verifyNoMoreInteractions(frameReply, late);
    transition = new PlaybackTransition(player);
    transition.replace(source, mock(MethodChannel.Result.class));
    MethodChannel.Result disposedWait = mock(MethodChannel.Result.class);
    transition.waitForFirstFrame(generation(), disposedWait);
    transition.dispose();
    verify(disposedWait).error(eq("transition_cancelled"), anyString(), isNull());
    ShadowLooper.idleMainLooper(8, TimeUnit.SECONDS);
    verifyNoMoreInteractions(disposedWait);
  }

  @Test
  public void unknownAndNonpositiveGenerationsCannotObserveCurrentFrame() {
    transition.replace(source, result);
    ready(listener());
    frame(listener());
    MethodChannel.Result invalid = mock(MethodChannel.Result.class);
    transition.waitForFirstFrame(0, invalid);
    transition.waitForFirstFrame(generation() + 1, invalid);
    verify(invalid, times(2)).error(eq("transition_cancelled"), anyString(), isNull());
    verify(invalid, never()).success(any());
  }

}
