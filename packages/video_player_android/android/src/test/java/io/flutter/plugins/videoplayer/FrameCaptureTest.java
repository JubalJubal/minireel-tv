package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;
import static org.mockito.Mockito.*;
import static org.mockito.AdditionalMatchers.aryEq;

import android.graphics.Bitmap;
import android.view.PixelCopy;
import android.view.Surface;
import io.flutter.plugin.common.MethodChannel;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.shadows.ShadowLooper;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class FrameCaptureTest {
  private FrameCapture capture;
  private ExecutorService executor;
  private MethodChannel.Result result;
  private Surface surface;
  private Bitmap bitmap;
  private PixelCopy.OnPixelCopyFinishedListener copyResult;
  private final List<Runnable> encoding = new ArrayList<>();
  private final AtomicBoolean valid = new AtomicBoolean(true);

  @Before
  public void setUp() {
    executor = mock(ExecutorService.class);
    doAnswer(call -> { encoding.add(call.getArgument(0)); return null; })
        .when(executor).execute(any(Runnable.class));
    capture = new FrameCapture((source, target, callback, handler) -> {
      bitmap = target;
      copyResult = callback;
    }, executor, target -> new byte[] {1, 2, 3});
    result = mock(MethodChannel.Result.class);
    surface = mock(Surface.class);
    when(surface.isValid()).thenReturn(true);
  }

  private void start() {
    capture.capture(surface, 3840, 2160, valid::get, result);
  }

  private void encode() {
    encoding.remove(0).run();
    ShadowLooper.idleMainLooper();
  }

  @Test
  public void boundsBitmapAndSchedulesEncodingOffMainCopyCallback() {
    start();
    assertEquals(960, bitmap.getWidth());
    assertEquals(540, bitmap.getHeight());
    assertTrue((long) bitmap.getWidth() * bitmap.getHeight() <= 1_000_000);
    copyResult.onPixelCopyFinished(PixelCopy.SUCCESS);
    assertEquals(1, encoding.size());
    verifyNoInteractions(result);
    encode();
    verify(result).success(aryEq(new byte[] {1, 2, 3}));
    assertTrue(bitmap.isRecycled());
    capture.dispose();
    verify(executor).shutdown();
  }

  @Test
  public void onlyOneCaptureCanOwnABitmapAtOnce() {
    start();
    MethodChannel.Result other = mock(MethodChannel.Result.class);
    capture.capture(surface, 1920, 1080, valid::get, other);
    verify(other).success(null);
    copyResult.onPixelCopyFinished(PixelCopy.SUCCESS);
    capture.capture(surface, 1920, 1080, valid::get, other);
    verify(other, times(2)).success(null);
    encode();
  }

  @Test
  public void invalidOrMissingSurfaceAndMissingDimensionsReturnNull() {
    capture.capture(null, 1920, 1080, valid::get, result);
    when(surface.isValid()).thenReturn(false);
    capture.capture(surface, 1920, 1080, valid::get, result);
    when(surface.isValid()).thenReturn(true);
    capture.capture(surface, 0, 1080, valid::get, result);
    verify(result, times(3)).success(null);
    verifyNoInteractions(executor);
    assertNull(bitmap);
  }

  @Test
  public void replacementBeforeCopyOrAfterCompressionRejectsStalePixels() {
    start();
    valid.set(false);
    copyResult.onPixelCopyFinished(PixelCopy.SUCCESS);
    verify(result).success(null);
    assertTrue(bitmap.isRecycled());
    assertTrue(encoding.isEmpty());
    valid.set(true);
    start();
    copyResult.onPixelCopyFinished(PixelCopy.SUCCESS);
    valid.set(false);
    encode();
    verify(result, times(2)).success(null);
  }

  @Test
  public void timeoutDiscardsLateCopyAndRepliesOnlyOnce() {
    start();
    ShadowLooper.idleMainLooper(150, TimeUnit.MILLISECONDS);
    verify(result).success(null);
    assertFalse(bitmap.isRecycled());
    copyResult.onPixelCopyFinished(PixelCopy.SUCCESS);
    assertTrue(bitmap.isRecycled());
    assertTrue(encoding.isEmpty());
    verifyNoMoreInteractions(result);
  }

  @Test
  public void disposeWhileCopyingDefersRecycleUntilPixelCopyIsDone() {
    start();
    capture.dispose();
    capture.dispose();
    verify(result).success(null);
    assertFalse(bitmap.isRecycled());
    copyResult.onPixelCopyFinished(PixelCopy.SUCCESS);
    assertTrue(bitmap.isRecycled());
    verify(executor, times(1)).shutdown();
    verifyNoMoreInteractions(result);
  }

  @Test
  public void disposeWithQueuedEncodingRecyclesAndCannotDeliverBytes() {
    start();
    copyResult.onPixelCopyFinished(PixelCopy.SUCCESS);
    capture.dispose();
    encode();
    assertTrue(bitmap.isRecycled());
    verify(result).success(null);
    verifyNoMoreInteractions(result);
  }

  @Test
  public void failedCopyRecyclesAndAllowsNextAttempt() {
    start();
    copyResult.onPixelCopyFinished(PixelCopy.ERROR_SOURCE_NO_DATA);
    verify(result).success(null);
    assertTrue(bitmap.isRecycled());
    start();
    assertFalse(bitmap.isRecycled());
    copyResult.onPixelCopyFinished(PixelCopy.SUCCESS);
    encode();
    verify(result).success(aryEq(new byte[] {1, 2, 3}));
  }

  @Test
  public void portraitExtremeAndSmallSizesStayBounded() {
    assertArrayEquals(new int[] {540, 960}, FrameCapture.dimensions(2160, 3840));
    assertArrayEquals(new int[] {1, 960}, FrameCapture.dimensions(1, Integer.MAX_VALUE));
    assertArrayEquals(new int[] {240, 160}, FrameCapture.dimensions(240, 160));
  }
  @Test
  public void televisionCaptureHasSmallerBoundAndDoesNotUpscale() {
    capture.capture(surface, 3840, 2160, FrameCapture.TELEVISION_MAX_EDGE, valid::get, result);
    assertEquals(640, bitmap.getWidth());
    assertEquals(360, bitmap.getHeight());
    assertEquals(921600, bitmap.getAllocationByteCount());
    copyResult.onPixelCopyFinished(PixelCopy.SUCCESS);
    encode();
    verify(result).success(aryEq(new byte[] {1, 2, 3}));
    assertArrayEquals(new int[] {360, 640}, FrameCapture.dimensions(2160, 3840, 640));
    assertArrayEquals(new int[] {240, 160}, FrameCapture.dimensions(240, 160, 640));
    assertArrayEquals(new int[] {960, 540}, FrameCapture.dimensions(1920, 1080, 2000));
    assertNull(FrameCapture.dimensions(1920, 1080, 0));
  }

}
