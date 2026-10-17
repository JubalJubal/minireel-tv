package io.flutter.plugins.videoplayer;

import static org.junit.Assert.*;

import androidx.media3.common.MimeTypes;
import androidx.media3.exoplayer.source.MediaSource;
import androidx.test.core.app.ApplicationProvider;
import java.util.HashMap;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34)
public class PreparedMediaRequestTest {
  @Test
  public void explicitMediaTypeWorksForExtensionlessProxyUrls() {
    PreparedMediaRequest hls = new PreparedMediaRequest("session", "http://127.0.0.1/media/id", null, "hls");
    assertEquals(MimeTypes.APPLICATION_M3U8, hls.mimeType);
    MediaSource source = hls.createSource(ApplicationProvider.getApplicationContext(), 21);
    assertEquals(MimeTypes.APPLICATION_M3U8, source.getMediaItem().localConfiguration.mimeType);
    assertEquals("hongguo:21", source.getMediaItem().mediaId);
    PreparedMediaRequest mp4 = new PreparedMediaRequest("session", hls.url, null, "mp4");
    assertEquals(MimeTypes.VIDEO_MP4, mp4.mimeType);
    assertNotEquals(hls, mp4);
  }

  @Test
  public void mimeAndExtensionNormalizeWithoutUsingQueryStringAsExtension() {
    assertEquals(new PreparedMediaRequest("x", "https://example.invalid/VIDEO.M3U8?x=1", null, null),
        new PreparedMediaRequest("x", "https://example.invalid/VIDEO.M3U8?x=1", null, "application/x-mpegurl"));
    assertNull(new PreparedMediaRequest("x", "https://example.invalid/media?x=.m3u8", null, null).mimeType);
  }

  @Test
  public void headersAreCopiedAndSessionIdentityIsPartOfTheMatch() {
    Map<String, String> headers = new HashMap<>();
    headers.put("X-Test", "original");
    PreparedMediaRequest request = new PreparedMediaRequest("first", "http://127.0.0.1/media", headers, "hls");
    headers.put("X-Test", "changed");
    assertEquals("original", request.headers.get("X-Test"));
    assertNotEquals(request, new PreparedMediaRequest("second", request.url, request.headers, "hls"));
    assertNotEquals(request, new PreparedMediaRequest("first", request.url, headers, "hls"));
  }
}
