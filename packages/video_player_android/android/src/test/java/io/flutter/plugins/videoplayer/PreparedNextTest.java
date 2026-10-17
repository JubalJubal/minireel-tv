package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;

import androidx.media3.common.MediaItem;
import androidx.media3.exoplayer.source.MediaSource;
import androidx.media3.exoplayer.source.preload.DefaultPreloadManager;
import androidx.media3.exoplayer.source.preload.PreloadException;
import io.flutter.plugin.common.MethodChannel;
import java.io.IOException;
import java.util.Collections;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowLooper;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class PreparedNextTest {
  private DefaultPreloadManager manager;
  private PreparedNext queue;
  private PreparedMediaRequest request;
  private MediaSource source;
  private MediaItem item;
  private MethodChannel.Result result;

  @Before
  public void setUp() {
    manager = mock(DefaultPreloadManager.class);
    queue = new PreparedNext(manager);
    request = request("session-2", "http://127.0.0.1/media/2", "hls");
    item = item("native-1");
    source = source(item);
    result = mock(MethodChannel.Result.class);
    when(manager.getMediaSource(item)).thenReturn(source);
  }

  private static PreparedMediaRequest request(String identity, String url, String type) {
    return new PreparedMediaRequest(identity, url, Collections.emptyMap(), type);
  }

  private static MediaItem item(String id) {
    return new MediaItem.Builder().setUri("http://127.0.0.1/synthetic").setMediaId(id).build();
  }

  private static MediaSource source(MediaItem item) {
    MediaSource source = mock(MediaSource.class);
    when(source.getMediaItem()).thenReturn(item);
    return source;
  }

  private void prepare() {
    queue.prepare(request, source, 1, result);
  }

  @Test
  public void preparesOneOffPlaylistSourceAndConsumesItWithoutAPlayerOrDecoder() {
    prepare();
    verify(manager).add(source, 1);
    verify(manager).invalidate();
    verifyNoInteractions(result);
    queue.onCompleted(item);
    verify(result).success(argThat(value -> Boolean.TRUE.equals(((Map<?, ?>) value).get("prepared"))));
    PreparedNext.Selection selected = queue.take(request);
    assertNotNull(selected);
    assertSame(source, selected.source);
    assertTrue(selected.ready);
    assertEquals(1, selected.generation);
    assertNull(queue.take(request));
    selected.release();
    verify(manager, times(1)).remove(item);
    verify(result, never()).error(anyString(), anyString(), any());
  }

  @Test
  public void duplicatePrepareUsesOneEntryAndCompletesAllWaiters() {
    prepare();
    MethodChannel.Result duplicate = mock(MethodChannel.Result.class);
    queue.prepare(request, source(item("unused")), 2, duplicate);
    verify(manager, times(1)).add(any(MediaSource.class), anyInt());
    queue.onCompleted(item);
    verify(result).success(any());
    verify(duplicate).success(any());
    MethodChannel.Result cached = mock(MethodChannel.Result.class);
    queue.prepare(request, source, 3, cached);
    verify(cached).success(any());
    assertEquals(1L, ((Map<?, ?>) queue.snapshot()).get("nextGeneration"));
  }

  @Test
  public void replacementAndReverseIgnoreOldCompletionAndError() {
    prepare();
    MethodChannel.Result replacement = mock(MethodChannel.Result.class);
    MediaItem newerItem = item("native-2");
    MediaSource newerSource = source(newerItem);
    when(manager.getMediaSource(newerItem)).thenReturn(newerSource);
    queue.prepare(request("session-1", "http://127.0.0.1/media/1", "mp4"), newerSource, 2, replacement);
    verify(result).error(eq("prepare_cancelled"), anyString(), isNull());
    verify(manager).remove(item);
    queue.onCompleted(item);
    queue.onError(new PreloadException(item, "old", new IOException()));
    verifyNoInteractions(replacement);
    queue.onCompleted(newerItem);
    verify(replacement).success(any());
    queue.clear(null);
    prepare();
    queue.onCompleted(newerItem);
    assertFalse((Boolean) queue.snapshot().get("nextPrepared"));
    queue.onCompleted(item);
    assertTrue((Boolean) queue.snapshot().get("nextPrepared"));
  }

  @Test
  public void staleClearCannotDiscardNewerIdentityAndClearDoesNotTouchPromoted() {
    prepare();
    assertFalse(queue.clear("old-session"));
    verify(manager, never()).remove(any(MediaItem.class));
    PreparedNext.Selection selected = queue.take(request);
    assertNotNull(selected);
    assertFalse(selected.ready);
    assertFalse(queue.clear(request.identity));
    verify(manager, never()).remove(any(MediaItem.class));
    selected.release();
    verify(manager).remove(item);
  }

  @Test
  public void mismatchedHeadersOrTypeOrIdentityFallBackAndReleasePendingSource() {
    PreparedMediaRequest[] mismatches = {
        new PreparedMediaRequest(request.identity, request.url, Map.of("Authorization", "synthetic"), "hls"),
        request(request.identity, request.url, "mp4"),
        request("different-session", request.url, "hls"),
        request(request.identity, request.url + "/changed", "hls")
    };
    for (PreparedMediaRequest mismatch : mismatches) {
      prepare();
      assertNull(queue.take(mismatch));
      assertFalse((Boolean) queue.snapshot().get("nextPreparing"));
    }
    verify(manager, times(mismatches.length)).remove(item);
  }

  @Test
  public void preloadErrorAndMissingPreparedSourceAllowColdFallback() {
    prepare();
    queue.onError(new PreloadException(item, "synthetic failure", new IOException()));
    verify(result).error(eq("prepare_failed"), anyString(), isNull());
    assertNull(queue.take(request));
    MethodChannel.Result retry = mock(MethodChannel.Result.class);
    queue.prepare(request, source, 2, retry);
    when(manager.getMediaSource(item)).thenReturn(null);
    assertNull(queue.take(request));
    verify(retry).error(eq("prepare_failed"), anyString(), isNull());
  }

  @Test
  public void timeoutCancellationAndReleaseCompleteOnlyOnce() {
    prepare();
    ShadowLooper.idleMainLooper(10, TimeUnit.SECONDS);
    verify(result).error(eq("prepare_timeout"), anyString(), isNull());
    queue.onCompleted(item);
    queue.dispose();
    queue.dispose();
    verify(manager, times(1)).release();
    verify(result, never()).success(any());
    verifyNoMoreInteractions(result);
    MethodChannel.Result late = mock(MethodChannel.Result.class);
    queue.prepare(request, source, 2, late);
    verify(late).error(eq("player_unavailable"), anyString(), isNull());
  }

  @Test
  public void disposalReleasesBothPromotedAndNextSources() {
    prepare();
    PreparedNext.Selection selected = queue.take(request);
    MediaItem nextItem = item("native-2");
    MethodChannel.Result nextResult = mock(MethodChannel.Result.class);
    queue.prepare(request("session-3", request.url + "/3", "hls"), source(nextItem), 2, nextResult);
    queue.dispose();
    verify(manager).remove(item);
    verify(manager).remove(nextItem);
    verify(manager).release();
    verify(nextResult).error(eq("prepare_cancelled"), anyString(), isNull());
    selected.release();
    verify(manager, times(1)).remove(item);
  }

  @Test
  public void synchronousManagerFailureClearsTheEntry() {
    doThrow(new IllegalStateException("synthetic")).when(manager).invalidate();
    prepare();
    verify(result).error(eq("prepare_failed"), anyString(), isNull());
    assertNull(queue.take(request));
    verify(manager).remove(item);
  }
}
