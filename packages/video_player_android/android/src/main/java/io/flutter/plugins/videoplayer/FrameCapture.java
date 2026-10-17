package io.flutter.plugins.videoplayer;

import android.graphics.Bitmap;
import android.os.Handler;
import android.os.Looper;
import android.view.PixelCopy;
import android.view.Surface;
import io.flutter.plugin.common.MethodChannel;
import java.io.ByteArrayOutputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.BooleanSupplier;

final class FrameCapture {
  static final int MAX_EDGE = 960;
  static final int TELEVISION_MAX_EDGE = 640;
  static final int MAX_ENCODED_BYTES = 1024 * 1024;

  interface Copier {
    void copy(Surface surface, Bitmap bitmap, PixelCopy.OnPixelCopyFinishedListener listener,
        Handler handler);
  }

  interface Encoder {
    byte[] encode(Bitmap bitmap);
  }

  private static final class Operation {
    final Bitmap bitmap;
    final BooleanSupplier valid;
    MethodChannel.Result reply;
    Runnable timeout;
    volatile boolean cancelled;

    Operation(Bitmap bitmap, BooleanSupplier valid, MethodChannel.Result reply) {
      this.bitmap = bitmap;
      this.valid = valid;
      this.reply = reply;
    }
  }

  private final Handler handler = new Handler(Looper.getMainLooper());
  private final Copier copier;
  private final ExecutorService executor;
  private final Encoder encoder;
  private Operation active;
  private boolean disposed;

  FrameCapture() {
    this(PixelCopy::request, Executors.newSingleThreadExecutor(), FrameCapture::encodeJpeg);
  }

  FrameCapture(Copier copier, ExecutorService executor, Encoder encoder) {
    this.copier = copier;
    this.executor = executor;
    this.encoder = encoder;
  }

  static int[] dimensions(int width, int height) {
    return dimensions(width, height, MAX_EDGE);
  }

  static int[] dimensions(int width, int height, int maxEdge) {
    if (width <= 0 || height <= 0 || maxEdge <= 0) return null;
    double scale = Math.min(1.0, (double) Math.min(MAX_EDGE, maxEdge) / Math.max(width, height));
    return new int[] {Math.max(1, (int) (width * scale)), Math.max(1, (int) (height * scale))};
  }

  void capture(Surface surface, int width, int height, BooleanSupplier valid,
      MethodChannel.Result reply) {
    capture(surface, width, height, MAX_EDGE, valid, reply);
  }

  void capture(Surface surface, int width, int height, int maxEdge, BooleanSupplier valid,
      MethodChannel.Result reply) {
    int[] size = dimensions(width, height, maxEdge);
    if (disposed || active != null || surface == null || !surface.isValid()
        || size == null || !valid.getAsBoolean()) {
      reply.success(null);
      return;
    }
    Bitmap bitmap;
    try {
      bitmap = Bitmap.createBitmap(size[0], size[1], Bitmap.Config.ARGB_8888);
    } catch (RuntimeException | OutOfMemoryError error) {
      reply.success(null);
      return;
    }
    Operation operation = new Operation(bitmap, valid, reply);
    active = operation;
    operation.timeout = () -> {
      operation.cancelled = true;
      reply(operation, null);
    };
    handler.postDelayed(operation.timeout, 150);
    try {
      copier.copy(surface, bitmap, status -> copied(operation, status), handler);
    } catch (RuntimeException error) {
      finish(operation, null);
      bitmap.recycle();
    }
  }

  private void copied(Operation operation, int status) {
    if (status != PixelCopy.SUCCESS || disposed || operation.cancelled
        || !operation.valid.getAsBoolean()) {
      operation.bitmap.recycle();
      finish(operation, null);
      return;
    }
    try {
      executor.execute(() -> {
        byte[] encoded = null;
        try {
          if (!operation.cancelled) encoded = encoder.encode(operation.bitmap);
        } catch (RuntimeException | OutOfMemoryError ignored) {
        } finally {
          operation.bitmap.recycle();
        }
        byte[] bytes = encoded;
        handler.post(() -> finish(operation, bytes));
      });
    } catch (RuntimeException error) {
      operation.bitmap.recycle();
      finish(operation, null);
    }
  }

  private void finish(Operation operation, byte[] bytes) {
    if (active != operation) return;
    active = null;
    handler.removeCallbacks(operation.timeout);
    boolean usable = !disposed && !operation.cancelled && operation.valid.getAsBoolean()
        && bytes != null && bytes.length <= MAX_ENCODED_BYTES;
    reply(operation, usable ? bytes : null);
  }

  private static void reply(Operation operation, byte[] bytes) {
    MethodChannel.Result reply = operation.reply;
    operation.reply = null;
    if (reply != null) reply.success(bytes);
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    if (active != null) {
      active.cancelled = true;
      handler.removeCallbacks(active.timeout);
      reply(active, null);
    }
    executor.shutdown();
  }

  private static byte[] encodeJpeg(Bitmap bitmap) {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    return bitmap.compress(Bitmap.CompressFormat.JPEG, 78, bytes) ? bytes.toByteArray() : null;
  }
}
