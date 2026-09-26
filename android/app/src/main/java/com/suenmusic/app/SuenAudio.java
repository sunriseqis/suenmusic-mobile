package com.suenmusic.app;

import android.net.Uri;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;

/**
 * 原生音频层的共享常量与流会话存储。
 *
 * 流会话（baseUrl + 会话流令牌）由 Web 端通过 Capacitor 插件写入，
 * SuenAudioService 在 onAddMediaItems 时用它把曲目 id 组装成
 * 带鉴权令牌的代理流地址。静态存储是因为插件与前台服务同进程，
 * 走 Intent 传参会把生命周期耦合在一起。
 */
public final class SuenAudio {

  /** 音乐类音频属性：true = 让 ExoPlayer 自动处理音频焦点（来电暂停、让路导航） */
  public static final AudioAttributes AUDIO_ATTRIBUTES = new AudioAttributes.Builder()
      .setUsage(C.USAGE_MEDIA)
      .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
      .build();

  /** 网络流需要 WAKE_MODE_NETWORK：熄屏时保持 CPU 拉流不断 */
  public static final int WAKE_MODE = C.WAKE_MODE_NETWORK;

  private static volatile String baseUrl;
  private static volatile String sessionToken;

  private SuenAudio() {}

  public static void setStreamSession(String base, String token) {
    baseUrl = base;
    sessionToken = token;
  }

  public static String getBaseUrl() {
    return baseUrl;
  }

  public static String getSessionToken() {
    return sessionToken;
  }

  /** 组装带会话令牌的代理流地址：`<base>/api/stream/<id>?t=<token>`（防御双斜杠） */
  public static String streamUrlFor(String trackId) {
    String raw = getBaseUrl();
    if (raw == null || raw.isEmpty()) return "";
    while (raw.endsWith("/")) {
      raw = raw.substring(0, raw.length() - 1);
    }
    String token = getSessionToken();
    String encId = Uri.encode(trackId);
    if (token != null && !token.isEmpty()) {
      return raw + "/api/stream/" + encId + "?t=" + Uri.encode(token);
    }
    return raw + "/api/stream/" + encId;
  }
}
