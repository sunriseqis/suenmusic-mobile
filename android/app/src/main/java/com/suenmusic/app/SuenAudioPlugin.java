package com.suenmusic.app;

import android.content.ComponentName;
import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import com.getcapacitor.Bridge;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.session.MediaController;
import androidx.media3.session.SessionToken;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.common.util.concurrent.MoreExecutors;
import java.util.ArrayList;
import java.util.List;

/**
 * 原生音频的 Capacitor 插件：Web 端播放控制的桥。
 *
 * 职责边界（对齐"壳"架构）：
 *   - 原生只负责"播放 Web 端排好的队列"：setQueue 收到曲目列表（id + 元数据）后
 *     交给 MediaController / SuenAudioService 出声
 *   - 队列顺序、播放模式、解析重试全部还在 Web 端 player store 里
 *   - 原生往回推三类事件：progress（进度心跳）、trackChange（曲目切换）、
 *     error（播放错误）、networkChanged（网络变化）——Web 端据此同步 UI 与快速切网
 */
@CapacitorPlugin(name = "SuenAudio")
public class SuenAudioPlugin extends Plugin {

  private static final String TAG = "SuenAudio";
  private static final long TICK_MS = 500;

  private final Handler main = new Handler(Looper.getMainLooper());
  private MediaController controller;
  private ListenableFuture<MediaController> controllerFuture;
  private final List<Runnable> pendingControllerCallbacks = new ArrayList<>();
  private boolean tickerRunning;
  private ConnectivityManager.NetworkCallback networkCallback;

  @Override
  public void load() {
    super.load();
    registerNetworkCallback();
  }

  private void registerNetworkCallback() {
    try {
      Context ctx = getContext();
      if (ctx == null) return;
      ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
      if (cm == null) return;
      NetworkRequest request = new NetworkRequest.Builder()
          .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
          .build();
      networkCallback = new ConnectivityManager.NetworkCallback() {
        @Override
        public void onAvailable(Network network) {
          notifyNetworkChanged("available");
        }

        @Override
        public void onLost(Network network) {
          notifyNetworkChanged("lost");
        }

        @Override
        public void onCapabilitiesChanged(Network network, NetworkCapabilities caps) {
          notifyNetworkChanged("changed");
        }
      };
      cm.registerNetworkCallback(request, networkCallback);
    } catch (Throwable t) {
      Log.w(TAG, "注册网络监听失败", t);
    }
  }

  private void notifyNetworkChanged(String type) {
    main.post(() -> {
      try {
        JSObject data = new JSObject();
        data.put("type", type);
        notifyListeners("networkChanged", data);
      } catch (Throwable ignored) {}
    });
  }

  private final Player.Listener playerListener = new Player.Listener() {
    @Override
    public void onMediaItemTransition(MediaItem mediaItem, int reason) {
      if (controller == null) return;
      try {
        JSObject data = new JSObject();
        data.put("index", controller.getCurrentMediaItemIndex());
        String id = mediaItem != null ? mediaItem.mediaId : null;
        if ((id == null || id.isEmpty()) && controller.getCurrentMediaItem() != null) {
          id = controller.getCurrentMediaItem().mediaId;
        }
        data.put("id", id != null ? id : "");
        data.put("reason", reason);   // 1=AUTO（播完接续） 2=SEEK 3=PLAYLIST_CHANGED
        notifyListeners("trackChange", data);
      } catch (Throwable t) {
        Log.w(TAG, "onMediaItemTransition error", t);
      }
    }

    @Override
    public void onIsPlayingChanged(boolean isPlaying) {
      try {
        if (isPlaying) {
          startTicker();
        } else {
          stopTicker();
        }
        JSObject data = new JSObject();
        data.put("playing", isPlaying);
        notifyListeners("state", data);
      } catch (Throwable t) {
        Log.w(TAG, "onIsPlayingChanged error", t);
      }
    }

    @Override
    public void onPlayerError(PlaybackException error) {
      try {
        JSObject data = new JSObject();
        data.put("message", error.getMessage() != null ? error.getMessage() : "播放错误");
        notifyListeners("error", data);
      } catch (Throwable t) {
        Log.w(TAG, "onPlayerError error", t);
      }
    }
  };

  private final Runnable ticker = new Runnable() {
    @Override
    public void run() {
      if (!tickerRunning) return;
      try {
        if (controller != null && controller.isPlaying()) {
          JSObject data = new JSObject();
          data.put("index", controller.getCurrentMediaItemIndex());
          data.put("positionMs", Math.max(0, controller.getCurrentPosition()));
          long dur = controller.getDuration();
          data.put("durationMs", dur > 0 ? dur : 0);
          data.put("playing", controller.isPlaying());
          notifyListeners("progress", data);
          if (tickerRunning) {
            main.postDelayed(this, TICK_MS);
          }
        } else {
          stopTicker();
        }
      } catch (Throwable t) {
        Log.w(TAG, "Ticker error", t);
        stopTicker();
      }
    }
  };

  /** 连接 MediaController（单例 Future 保护，全生命周期复用），就绪后在主线程回调 */
  private void ensureController(Runnable onReady, PluginCall call) {
    main.post(() -> {
      if (controller != null) {
        try {
          onReady.run();
          if (controller != null && controller.isPlaying()) startTicker();
        } catch (Throwable t) {
          Log.e(TAG, "Controller action error", t);
          if (call != null && !call.isReleased()) call.reject("播放控制器执行失败: " + t.getMessage());
        }
        return;
      }
      if (controllerFuture != null) {
        synchronized (pendingControllerCallbacks) {
          pendingControllerCallbacks.add(onReady);
        }
        return;
      }

      Context ctx = getContext();
      if (ctx == null) {
        if (call != null && !call.isReleased()) call.reject("Context 为空，无法启动播放服务");
        return;
      }

      try {
        controllerFuture = new MediaController.Builder(
            ctx, new SessionToken(ctx, new ComponentName(ctx, SuenAudioService.class))).buildAsync();
      } catch (Throwable t) {
        Log.e(TAG, "创建 MediaController 失败", t);
        if (call != null && !call.isReleased()) call.reject("创建 MediaController 失败: " + t.getMessage());
        return;
      }

      controllerFuture.addListener(() -> {
        main.post(() -> {
          try {
            final MediaController c = controllerFuture.get();
            controller = c;
            c.addListener(playerListener);
            if (c.isPlaying()) startTicker();
            try {
              onReady.run();
            } catch (Throwable t) {
              Log.e(TAG, "Initial controller callback error", t);
              if (call != null && !call.isReleased()) call.reject("播放执行失败: " + t.getMessage());
            }
            List<Runnable> pending;
            synchronized (pendingControllerCallbacks) {
              pending = new ArrayList<>(pendingControllerCallbacks);
              pendingControllerCallbacks.clear();
            }
            for (Runnable cb : pending) {
              try {
                cb.run();
              } catch (Throwable t) {
                Log.e(TAG, "Pending controller callback error", t);
              }
            }
          } catch (Throwable e) {
            Log.e(TAG, "连接播放服务失败", e);
            if (controllerFuture != null) {
              MediaController.releaseFuture(controllerFuture);
              controllerFuture = null;
            }
            synchronized (pendingControllerCallbacks) {
              pendingControllerCallbacks.clear();
            }
            final String msg = e.getCause() != null ? e.getCause().getMessage() : e.getMessage();
            if (call != null && !call.isReleased()) call.reject("连接播放服务失败: " + msg);
          }
        });
      }, MoreExecutors.directExecutor());
    });
  }

  private void startTicker() {
    if (tickerRunning) return;
    tickerRunning = true;
    main.post(ticker);
  }

  private void stopTicker() {
    tickerRunning = false;
    main.removeCallbacks(ticker);
  }

  /**
   * 健壮的数字取值：Capacitor 的 getLong/getInt 读不出 JS 传来的数字
   * （JSON 解析后可能是 Integer/Long/Double），会返回 null。opt() 拿到原始对象再转。
   */
  private Long numberArg(PluginCall call, String name) {
    Object raw = call.getData().opt(name);
    return raw instanceof Number ? ((Number) raw).longValue() : null;
  }

  // 入参放宽到 org.json.JSONObject：JSArray.getJSONObject() 返回的就是它，
  // 而 Capacitor 的 JSObject 只是它的子类，子类引用收不了父类对象。
  private Long numberArg(org.json.JSONObject object, String name) {
    Object raw = object.opt(name);
    return raw instanceof Number ? ((Number) raw).longValue() : null;
  }

  /** Web 端排好队的整条队列：条目（id+元数据）+ 起始位置 + 流会话凭据 */
  @PluginMethod
  public void setQueue(PluginCall call) {
    String baseUrl = call.getString("baseUrl");
    String token = call.getString("token");
    JSArray items = call.getArray("items");
    Long startParsed = numberArg(call, "startIndex");
    final int startIndex = startParsed != null ? (int) startParsed.longValue() : 0;
    // 新队列从当前位置起播：随机打乱/换路径重发队列时，正在听的这首不被打断
    Long posParsed = numberArg(call, "startPositionMs");
    final long startPositionMs = posParsed != null ? posParsed : 0L;
    // 装载后是否立刻出声，默认 true。恢复上次会话时 Web 端传 false：
    // 打开 App 不该自己响起来（出声一律由 play() 触发）
    final boolean autoplay = Boolean.TRUE.equals(call.getBoolean("autoplay", true));
    // tailOnly=true：items 只覆盖 [startIndex, 队尾) 这一段（重排未播部分）。
    // 正在播的那首不在替换范围内 → 不重新 prepare → 切模式不再"卡一下"。
    final boolean tailOnly = Boolean.TRUE.equals(call.getBoolean("tailOnly", false));
    if (baseUrl == null || token == null || items == null) {
      call.reject("缺少 baseUrl / token / items");
      return;
    }
    SuenAudio.setStreamSession(baseUrl, token);

    List<MediaItem> mediaItems = new ArrayList<>();
    try {
      for (int i = 0; i < items.length(); i++) {
        org.json.JSONObject o = items.getJSONObject(i);
        String id = o.optString("id", "");
        if (id == null || id.isEmpty()) continue;
        MediaMetadata.Builder mb = new MediaMetadata.Builder()
            .setTitle(o.optString("title", "未知曲目"))
            .setArtist(o.optString("artist", "未知歌手"));
        String album = o.optString("album", null);
        if (album != null && !album.trim().isEmpty()) {
          mb.setAlbumTitle(album.trim());
        }
        String cover = o.optString("coverUrl", null);
        if (cover != null && !cover.trim().isEmpty()) {
          try {
            mb.setArtworkUri(Uri.parse(cover.trim()));
          } catch (Exception ignored) {}
        }
        mediaItems.add(new MediaItem.Builder()
            .setMediaId(id)
            // 缓存键：曲目 id 会被带进 DataSpec.key，离线缓存按它索引（见 SuenAudioCache）
            .setCustomCacheKey(id)
            .setMediaMetadata(mb.build())
            .setRequestMetadata(new MediaItem.RequestMetadata.Builder()
                .setMediaUri(Uri.parse("suenmusic://track/" + Uri.encode(id)))
                .build())
            .build());
      }
    } catch (Exception e) {
      call.reject("队列解析失败: " + e.getMessage());
      return;
    }

    if (mediaItems.isEmpty()) {
      call.reject("播放队列为空");
      return;
    }

    final int safeStartIndex = Math.max(0, Math.min(startIndex, mediaItems.size() - 1));
    final long safeStartPositionMs = Math.max(0L, startPositionMs);

    ensureController(() -> {
      if (tailOnly) {
        final int from = Math.max(0, safeStartIndex);
        final int count = controller.getMediaItemCount();
        if (from < count && !mediaItems.isEmpty()) {
          controller.replaceMediaItems(from, count, mediaItems);
          // 读回校验：命令若不被允许会静默 no-op，那时退回整队列重发（今天的行为）
          if (sameFirstId(controller, from, mediaItems)) {
            call.resolve();
            return;
          }
          Log.w(TAG, "尾段重排未生效，退回整队列重发");
        } else {
          // 队尾本来就没有内容可替换（例如只剩当前这一首），什么都不用做
          call.resolve();
          return;
        }
      }
      controller.setMediaItems(mediaItems, safeStartIndex, safeStartPositionMs);
      controller.prepare();
      // autoplay=false 时只装载（prepare 让它处于"点一下就能响"的就绪态）
      if (autoplay) controller.play();
      call.resolve();
    }, call);
  }

  /** 读回第 index 项，确认尾段重排真的生效了（MediaController 对不可用命令是静默 no-op） */
  private boolean sameFirstId(MediaController c, int index, List<MediaItem> items) {
    if (items == null || items.isEmpty()) return false;
    if (index < 0 || index >= c.getMediaItemCount()) return false;
    MediaItem current = c.getMediaItemAt(index);
    return current != null && items.get(0).mediaId.equals(current.mediaId);
  }

  @PluginMethod
  public void play(PluginCall call) {
    ensureController(() -> {
      if (controller.getMediaItemCount() == 0) {
        call.reject("播放队列为空");
        return;
      }
      if (controller.getPlaybackState() == Player.STATE_IDLE || controller.getPlaybackState() == Player.STATE_ENDED) {
        controller.prepare();
      }
      controller.play();
      call.resolve();
    }, call);
  }

  @PluginMethod
  public void pause(PluginCall call) {
    ensureController(() -> {
      controller.pause();
      call.resolve();
    }, call);
  }

  @PluginMethod
  public void seek(PluginCall call) {
    Long ms = numberArg(call, "positionMs");
    if (ms == null) { call.reject("缺少 positionMs"); return; }
    final long target = ms;
    ensureController(() -> {
      controller.seekTo(target);
      call.resolve();
    }, call);
  }

  /**
   * 蓝牙歌词：把"当前歌词行"写进 MediaSession 元数据 → AVRCP 自动转发给车机/耳机。
   *
   * 做法（开源蓝牙歌词的通用方案）：AVRCP 没有歌词字段，但**元数据变更会实时转发**，
   * 所以每换一行歌词就更新一次 MediaMetadata。约定：
   *   - artist 位 = 当前行歌词（车机小字滚动显示）
   *   - title 保持歌名不变（不顶掉真实信息）
   *   - text 传空 = 清掉歌词、恢复原始歌手名（切歌/暂停时）
   *
   * @param text 当前行歌词；空串表示清除
   */
  private final java.util.Map<String, String> originalArtists = new java.util.HashMap<>();
  private String lastLyricLine = null;
  private String lastLyricLineTrackId = null;

  @PluginMethod
  public void requestNotificationPermission(PluginCall call) {
    if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.TIRAMISU
        || getActivity().checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
            == android.content.pm.PackageManager.PERMISSION_GRANTED) {
      call.resolve();
      return;
    }
    getActivity().requestPermissions(
        new String[]{android.Manifest.permission.POST_NOTIFICATIONS}, 101);
    call.resolve();
  }

  @PluginMethod
  public void setLyricTimeline(PluginCall call) {
    String trackId = call.getString("trackId", "");
    Long revisionValue = numberArg(call, "revision");
    JSArray lines = call.getArray("lines");
    if (trackId == null || trackId.trim().isEmpty() || revisionValue == null || lines == null) {
      call.reject("缺少歌词时间轴参数");
      return;
    }
    ArrayList<Long> starts = new ArrayList<>();
    ArrayList<String> texts = new ArrayList<>();
    try {
      for (int i = 0; i < lines.length(); i++) {
        org.json.JSONObject line = lines.getJSONObject(i);
        if (line == null) continue;
        Long start = numberArg(line, "startMs");
        String text = line.optString("text", "");
        if (start == null || text == null || text.trim().isEmpty()) continue;
        starts.add(Math.max(0L, start));
        texts.add(text.trim());
      }
    } catch (Exception e) {
      call.reject("歌词时间轴解析失败: " + e.getMessage());
      return;
    }
    final long revision = revisionValue;
    ensureController(() -> {
      SuenAudioService.submitLyricTimeline(trackId.trim(), revision, starts, texts);
      call.resolve();
    }, call);
  }

  @PluginMethod
  public void setLyricLine(PluginCall call) {
    final String text = call.getString("text", "");
    ensureController(() -> {
      try {
        if (controller.getMediaItemCount() == 0) {
          call.resolve();
          return;
        }
        int index = controller.getCurrentMediaItemIndex();
        MediaItem cur = controller.getMediaItemAt(index);
        if (cur == null || cur.mediaMetadata == null) {
          call.resolve();
          return;
        }
        String id = cur.mediaId;
        boolean hasText = text != null && !text.trim().isEmpty();
        if (hasText && text.equals(lastLyricLine) && id.equals(lastLyricLineTrackId)) {
          call.resolve(); // 同一首同一行，别频繁 replace
          return;
        }
        lastLyricLine = hasText ? text : null;
        lastLyricLineTrackId = hasText ? id : null;

        String newArtist;
        if (hasText) {
          CharSequence orig = cur.mediaMetadata.artist;
          if (orig != null && !originalArtists.containsKey(id)) {
            originalArtists.put(id, orig.toString());
          }
          newArtist = text;
        } else {
          String orig = originalArtists.remove(id);
          newArtist = orig != null ? orig : (cur.mediaMetadata.artist == null ? "" : cur.mediaMetadata.artist.toString());
        }

        androidx.media3.common.MediaMetadata mb = cur.mediaMetadata.buildUpon()
            .setArtist(newArtist)
            .build();
        controller.replaceMediaItem(index, cur.buildUpon().setMediaMetadata(mb).build());
        call.resolve();
      } catch (Exception e) {
        call.reject("蓝牙歌词更新失败: " + e.getMessage());
      }
    }, call);
  }

  @PluginMethod
  public void seekToIndex(PluginCall call) {
    Long parsed = numberArg(call, "index");
    if (parsed == null) { call.reject("缺少 index"); return; }
    final int index = (int) parsed.longValue();
    // 定位后是否顺便出声，默认 true；Web 端"装载就位"（bridge.load）传 false，
    // 出声由随后的 play() 负责 —— 否则恢复会话时会自己响起来
    final boolean autoplay = Boolean.TRUE.equals(call.getBoolean("autoplay", true));
    final boolean force = Boolean.TRUE.equals(call.getBoolean("force", false));
    ensureController(() -> {
      // 越界索引会让 MediaController.seekTo 抛 IllegalArgumentException
      // 直接崩掉应用（实测）：这里改为拒绝调用，让 Web 端自己修正
      if (index < 0 || index >= controller.getMediaItemCount()) {
        call.reject("曲目索引越界: " + index + " / " + controller.getMediaItemCount());
        return;
      }
      final int currentState = controller.getPlaybackState();
      final boolean needPrepare = force || currentState == Player.STATE_IDLE || currentState == Player.STATE_ENDED;
      // 目标就是当前条目时**不要**移动位置：seekToIndex 的语义是"选中这一首"，
      // 不是"从头播这一首"。恢复会话后原生已带着续播位置停在这首上，
      // 再 seekTo(index, 0) 会把位置归零（真机报障："一点播放就从头开始"）。
      // 但如果处于 IDLE/ENDED 故障态，或者调用方显式指定 force，则必须从头重新 prepare
      if (force || index != controller.getCurrentMediaItemIndex() || needPrepare) {
        controller.seekTo(index, 0);
        if (needPrepare) {
          controller.prepare();
        }
      }
      if (autoplay) controller.play();
      call.resolve();
    }, call);
  }

  /**
   * 硬重载当前（或指定）条目：**换了音源之后必须走这里**。
   *
   * 为什么光改 Web 层的 `el.src` 没用、光调 seekToIndex 也没用：
   *   1. `src` 在原生路径下只用来识别 trackId，URL 不进播放器（代理流地址由
   *      服务端会话回调按 mediaId 组装）；
   *   2. ExoPlayer 的磁盘缓存键是**曲目 id**（见 SuenAudioService 的
   *      setCustomCacheKey），同一首歌换了音源后键不变 —— 不 evict 就会拿旧字节；
   *   3. 已经读进内存的缓冲不受 seek 影响，**只有 stop() 回 IDLE 才丢得掉**。
   *
   * 三者叠加的真实表现（真机报障）：锚定换了音源，播放继续放旧音源，
   * 时长要等旧缓冲耗尽才变 —— 甚至一直不变。所以这里 stop() 丢缓冲 →
   * 重建条目（重设 URI 与缓存键）→ prepare → 定位 → 出声。
   */
  @PluginMethod
  public void reloadCurrent(PluginCall call) {
    Long idxArg = numberArg(call, "index");
    Long posArg = numberArg(call, "positionMs");
    final long positionMs = posArg == null ? 0L : Math.max(0L, posArg);
    final boolean autoplay = Boolean.TRUE.equals(call.getBoolean("autoplay", true));

    ensureController(() -> {
      if (controller.getMediaItemCount() == 0) {
        call.reject("原生队列为空，无法重载");
        return;
      }
      final int index =
          idxArg == null ? controller.getCurrentMediaItemIndex() : (int) idxArg.longValue();
      if (index < 0 || index >= controller.getMediaItemCount()) {
        call.reject("曲目索引越界: " + index + " / " + controller.getMediaItemCount());
        return;
      }
      final MediaItem cur = controller.getMediaItemAt(index);
      final String id = cur.mediaId;
      if (id == null || id.isEmpty()) {
        call.reject("当前条目缺少 mediaId");
        return;
      }

      // 1) 回 IDLE：丢掉内存缓冲与错误态（关键一步，seek 做不到）
      controller.stop();
      // 2) 重建条目：服务端会按 mediaId 重新组装代理流地址 —— 于是拿到新锚点的音源。
      //    缓存键必须显式重设（经会话 IPC 会丢，丢了缓存永不命中，离线播放全废）
      controller.replaceMediaItem(
          index,
          cur.buildUpon()
              .setUri(SuenAudio.streamUrlFor(id))
              .setCustomCacheKey(id)
              .build());
      // 3) 重新准备并回到原位置
      controller.prepare();
      controller.seekTo(index, positionMs);
      if (autoplay) controller.play();
      call.resolve();
    }, call);
  }

  /** 离线缓存信息：已用字节 / 上限（设置页展示用） */
  @PluginMethod
  public void getCacheInfo(PluginCall call) {
    JSObject data = new JSObject();
    data.put("usedBytes", SuenAudioCache.usedBytes(getContext()));
    data.put("maxBytes", SuenAudioCache.maxBytes());
    call.resolve(data);
  }

  /**
   * 封面本地缓存：把远程封面下载到应用目录，返回**可直接给 `<img src>` 用的本地 URL**。
   *
   * 为什么必须自己做：封面走的是上游 CDN（y.gtimg.cn 之类），离线时 WebView
   * 不保证从它自己的磁盘缓存里取（实测离线全裂图），所以由原生落盘、返回本地
   * 文件 URL —— 离线时 `<img>` 直接读本地文件，稳。
   *
   * 已存在的不重复下载；单个失败不影响其它（尽力而为）。
   */
  @PluginMethod
  public void cacheImages(PluginCall call) {
    JSArray urls = call.getArray("urls");
    if (urls == null) {
      call.reject("缺少 urls");
      return;
    }
    final Context ctx = getContext();
    new Thread(() -> {
      JSObject out = new JSObject();
      File dir = new File(ctx.getFilesDir(), "covers");
      if (!dir.exists() && !dir.mkdirs()) {
        call.reject("封面目录创建失败");
        return;
      }
      int cached = 0;
      for (int i = 0; i < urls.length(); i++) {
        String url = urls.optString(i, "");
        if (url == null || url.isEmpty()) continue;
        File f = new File(dir, sha1Hex(url) + ".img");
        try {
          if (!f.exists() || f.length() == 0) downloadToFile(url, f);
          out.put(url, getBridge().getLocalUrl() + Bridge.CAPACITOR_FILE_START + f.getAbsolutePath());
          cached += 1;
        } catch (Exception e) {
          Log.w(TAG, "封面缓存失败 " + url + "：" + e.getMessage());
        }
      }
      Log.i(TAG, "封面缓存：" + cached + "/" + urls.length());
      call.resolve(out);
    }, "suen-cover-cache").start();
  }

  private static String sha1Hex(String raw) {
    try {
      MessageDigest md = MessageDigest.getInstance("SHA-1");
      byte[] digest = md.digest(raw.getBytes(StandardCharsets.UTF_8));
      StringBuilder sb = new StringBuilder();
      for (byte b : digest) sb.append(String.format("%02x", b));
      return sb.toString();
    } catch (Exception e) {
      return Integer.toHexString(raw.hashCode());
    }
  }

  private static void downloadToFile(String url, File dest) throws IOException {
    HttpURLConnection conn = (HttpURLConnection) new URL(url).openConnection();
    conn.setConnectTimeout(10_000);
    conn.setReadTimeout(20_000);
    conn.setRequestProperty("User-Agent", "SuenMusic/1.0 (Android)");
    File tmp = new File(dest.getAbsolutePath() + ".part");
    try (InputStream in = conn.getInputStream(); OutputStream out = new FileOutputStream(tmp)) {
      byte[] buf = new byte[8192];
      int n;
      while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
    } finally {
      conn.disconnect();
    }
    // 下载完成后原子改名：避免半截文件被当成已缓存
    if (!tmp.renameTo(dest)) {
      // 极端情况（同名已存在）兜底
      if (!dest.exists()) throw new IOException("封面落盘失败");
    }
  }

  /** 这首曲子是否完整在缓存里（离线播放判定用） */
  @PluginMethod
  public void isCached(PluginCall call) {
    String id = call.getString("id");
    if (id == null || id.isEmpty()) {
      call.reject("缺少 id");
      return;
    }
    JSObject data = new JSObject();
    data.put("cached", SuenAudioCache.isFullyCached(getContext(), id));
    call.resolve(data);
  }

  /**
   * 清掉单首曲目的离线缓存。
   *
   * 重新锚定音源后必须调用：缓存键是曲目 id，旧音源的字节还在缓存里，
   * 会盖住新锚定的音源（锚定了却听不出变化）。
   */
  @PluginMethod
  public void evictCache(PluginCall call) {
    String id = call.getString("id");
    if (id == null || id.isEmpty()) {
      call.reject("缺少 id");
      return;
    }
    SuenAudioCache.evict(getContext(), id);
    call.resolve();
  }

  /** 清空离线缓存（同时清空音频缓存与本地封面） */
  @PluginMethod
  public void clearCache(PluginCall call) {
    SuenAudioCache.clear(getContext());
    try {
      File coverDir = new File(getContext().getFilesDir(), "covers");
      if (coverDir.exists()) {
        File[] files = coverDir.listFiles();
        if (files != null) {
          for (File f : files) {
            f.delete();
          }
        }
      }
    } catch (Exception e) {
      Log.w(TAG, "清理封面缓存失败", e);
    }
    call.resolve();
  }

  /** 播放模式：让原生队列自己接续时也遵守单曲/列表循环（off/one/all） */
  @PluginMethod
  public void setRepeatMode(PluginCall call) {
    String mode = call.getString("mode", "off");
    ensureController(() -> {
      if ("one".equals(mode)) {
        controller.setRepeatMode(Player.REPEAT_MODE_ONE);
      } else if ("all".equals(mode)) {
        controller.setRepeatMode(Player.REPEAT_MODE_ALL);
      } else {
        controller.setRepeatMode(Player.REPEAT_MODE_OFF);
      }
      call.resolve();
    }, call);
  }

  @PluginMethod
  public void getStatus(PluginCall call) {
    ensureController(() -> {
      JSObject data = new JSObject();
      data.put("index", controller.getCurrentMediaItemIndex());
      data.put("positionMs", Math.max(0, controller.getCurrentPosition()));
      long dur = controller.getDuration();
      data.put("durationMs", dur > 0 ? dur : 0);
      data.put("playing", controller.isPlaying());
      data.put("queueLength", controller.getMediaItemCount());
      call.resolve(data);
    }, call);
  }

  @PluginMethod
  public void stop(PluginCall call) {
    ensureController(() -> {
      controller.stop();
      stopTicker();
      call.resolve();
    }, call);
  }

  @Override
  protected void handleOnDestroy() {
    main.post(() -> {
      stopTicker();
      if (networkCallback != null) {
        try {
          Context ctx = getContext();
          if (ctx != null) {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm != null) cm.unregisterNetworkCallback(networkCallback);
          }
        } catch (Throwable ignored) {}
        networkCallback = null;
      }
      if (controllerFuture != null) {
        MediaController.releaseFuture(controllerFuture);
        controllerFuture = null;
      }
      if (controller != null) {
        controller.removeListener(playerListener);
        controller.release();
        controller = null;
      }
    });
    super.handleOnDestroy();
  }
}
