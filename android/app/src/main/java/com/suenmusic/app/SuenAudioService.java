package com.suenmusic.app;

import android.app.PendingIntent;
import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import androidx.annotation.OptIn;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MediaMetadata;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy;
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy;
import androidx.media3.session.MediaSession;
import androidx.media3.session.MediaSessionService;
import com.google.common.collect.ImmutableList;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 原生音频前台服务（Media3）。
 *
 * 锁屏/通知栏控制、耳机线控、音频焦点全部由 MediaSession 体系接管：
 *   - 通知：MediaSessionService 默认提供媒体样式通知（含封面/标题/暂停/上下首）
 *   - 音频焦点：ExoPlayer.setAudioAttributes(..., handleAudioFocus=true)
 *   - 拔耳机暂停：setHandleAudioBecomingNoisy(true)
 *
 * 控制器（Capacitor 插件）发来的 MediaItem 只有 mediaId 与元数据、没有真实 URI
 * —— 安卓 13+ 的媒体会话协议不允许控制器直接指定 URI。真实地址在
 * onAddMediaItems 里按 `SuenAudio.streamUrlFor(id)` 组装（带会话流令牌的代理流）。
 */
public class SuenAudioService extends MediaSessionService {

  private static SuenAudioService activeService;
  private static final long LYRIC_TICK_MS = 200;

  private MediaSession session;
  private ExoPlayer player;
  private final Handler lyricHandler = new Handler(Looper.getMainLooper());
  private final Map<String, LyricTimeline> lyricTimelines = new HashMap<>();
  private final Map<String, Long> lyricRevisions = new HashMap<>();
  private final Map<String, String> originalArtists = new HashMap<>();
  private String lastLyricKey;

  private final Runnable lyricTicker = new Runnable() {
    @Override
    public void run() {
      if (player == null) return;
      updateLyricMetadata();
      if (player.isPlaying()) lyricHandler.postDelayed(this, LYRIC_TICK_MS);
    }
  };

  public static void submitLyricTimeline(
      String trackId, long revision, List<Long> starts, List<String> texts) {
    if (activeService != null) {
      activeService.acceptLyricTimeline(trackId, revision, starts, texts);
    }
  }

  @Override
  public void onCreate() {
    super.onCreate();
    activeService = this;
    player = new ExoPlayer.Builder(this)
        // 离线缓存（L1）：优先读本地缓存，未命中走上游并边播边存
        .setMediaSourceFactory(
            new DefaultMediaSourceFactory(SuenAudioCache.dataSourceFactory(this))
                // 熄屏自愈：重试窗口拉长到覆盖上游冷却，见 SuenRetryPolicy
                .setLoadErrorHandlingPolicy(new SuenRetryPolicy())
        )
        .setAudioAttributes(SuenAudio.AUDIO_ATTRIBUTES, /* handleAudioFocus= */ true)
        .setHandleAudioBecomingNoisy(true)
        .setWakeMode(SuenAudio.WAKE_MODE)
        // ⚠️ 必须让 Media3 **自己接续下一首**（true 会停在曲末）。
        //
        // 教训：此前设为 true（把"下一首放谁"交给 Web 端），熄屏后自动续播
        // 会失败 —— 安卓会节流/挂起 WebView 的 JS，桥的曲终判定根本不执行；
        // 用户一解锁 JS 恢复才补上切歌（实测报障：锁屏不续、解锁后跳曲）。
        // 现在由原生队列自己走，播放模式（单曲/列表循环）通过 setRepeatMode 下发。
        .setPauseAtEndOfMediaItems(false)
        .build();
    player.addListener(new androidx.media3.common.Player.Listener() {
      @Override
      public void onMediaItemTransition(MediaItem item, int reason) {
        lastLyricKey = null;
        updateLyricMetadata();
      }

      @Override
      public void onPositionDiscontinuity(
          androidx.media3.common.Player.PositionInfo oldPosition,
          androidx.media3.common.Player.PositionInfo newPosition,
          int reason) {
        updateLyricMetadata();
      }

      @Override
      public void onIsPlayingChanged(boolean isPlaying) {
        lyricHandler.removeCallbacks(lyricTicker);
        updateLyricMetadata();
        if (isPlaying) lyricHandler.post(lyricTicker);
      }
    });

    Intent intent = new Intent(this, MainActivity.class);
    PendingIntent pendingIntent = PendingIntent.getActivity(
        this,
        0,
        intent,
        PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT
    );
    session = new MediaSession.Builder(this, player)
        .setSessionActivity(pendingIntent)
        .setCallback(callback)
        .build();
  }

  /** 会话回调：控制器发来的条目没有真实 URI，在这里按 mediaId 组装代理流地址 */
  private final MediaSession.Callback callback = new MediaSession.Callback() {
    @Override
    public ListenableFuture<List<MediaItem>> onAddMediaItems(
        MediaSession mediaSession,
        MediaSession.ControllerInfo controller,
        List<MediaItem> mediaItems) {

      if (SuenAudio.getBaseUrl() == null || SuenAudio.getSessionToken() == null) {
        return Futures.immediateFailedFuture(
            new IllegalStateException("尚未配置服务器地址或流会话令牌"));
      }

      List<MediaItem> resolved = new ArrayList<>();
      for (MediaItem item : mediaItems) {
        String id = item.mediaId;
        if (id == null || id.isEmpty()) {
          return Futures.immediateFailedFuture(new IllegalStateException("队列条目缺少 mediaId"));
        }
        resolved.add(item.buildUpon()
            .setUri(SuenAudio.streamUrlFor(id))
            // ⚠️ 必须在这里再设一次缓存键：经会话 IPC 传来的条目 customCacheKey
            // 会丢失，丢失后 CacheDataSource 退回"按完整 URL（含时效令牌）做键"——
            // 令牌一换键就换，缓存只增永不命中，离线播放全废（实测踩过：
            // 索引里全是带 ?t= 的 URL 键，isFullyCached(id) 永远查不到）
            .setCustomCacheKey(id)
            .build());
      }
      return Futures.immediateFuture(ImmutableList.copyOf(resolved));
    }
  };

  private void acceptLyricTimeline(
      String trackId, long revision, List<Long> starts, List<String> texts) {
    if (trackId == null || trackId.isEmpty() || starts == null || texts == null) return;
    Long previous = lyricRevisions.get(trackId);
    if (previous != null && revision < previous) return;
    lyricRevisions.put(trackId, revision);
    if (starts.isEmpty() || texts.isEmpty()) {
      lyricTimelines.remove(trackId);
    } else {
      int n = Math.min(starts.size(), texts.size());
      ArrayList<Long> cleanStarts = new ArrayList<>();
      ArrayList<String> cleanTexts = new ArrayList<>();
      long last = 0;
      for (int i = 0; i < n; i++) {
        String text = texts.get(i) == null ? "" : texts.get(i).trim();
        if (text.isEmpty()) continue;
        long start = Math.max(0L, starts.get(i) == null ? 0L : starts.get(i));
        if (!cleanStarts.isEmpty() && start < last) continue;
        cleanStarts.add(start);
        cleanTexts.add(text.length() > 256 ? text.substring(0, 256) : text);
        last = start;
      }
      lyricTimelines.put(trackId, new LyricTimeline(cleanStarts, cleanTexts));
    }
    lastLyricKey = null;
    updateLyricMetadata();
  }

  private void updateLyricMetadata() {
    if (player == null || player.getMediaItemCount() == 0) return;
    int index = player.getCurrentMediaItemIndex();
    if (index < 0 || index >= player.getMediaItemCount()) return;
    MediaItem current = player.getMediaItemAt(index);
    if (current == null || current.mediaMetadata == null) return;
    String trackId = current.mediaId == null ? "" : current.mediaId;
    if (trackId.isEmpty()) return;

    String original = originalArtists.get(trackId);
    if (original == null) {
      original = current.mediaMetadata.artist == null ? "" : current.mediaMetadata.artist.toString();
      originalArtists.put(trackId, original);
    }

    LyricTimeline timeline = lyricTimelines.get(trackId);
    int lineIndex = timeline == null ? -1 : timeline.indexAt(player.getCurrentPosition());
    String text = lineIndex >= 0 ? timeline.texts.get(lineIndex) : "";
    String key = trackId + ":" + lyricRevisions.getOrDefault(trackId, 0L) + ":" + lineIndex
        + ":" + (player.isPlaying() ? "1" : "0");
    if (key.equals(lastLyricKey)) return;
    lastLyricKey = key;

    Bundle extras = new Bundle();
    extras.putString("suenmusic.track_id", trackId);
    extras.putString("suenmusic.original_artist", original);
    extras.putInt("suenmusic.lyric_line_index", lineIndex);
    extras.putString("suenmusic.lyric_text", text);
    extras.putBoolean("suenmusic.lyric_playing", player.isPlaying());
    String artist = text.isEmpty() ? original : text;
    MediaMetadata metadata = current.mediaMetadata.buildUpon()
        .setArtist(artist)
        .setExtras(extras)
        .build();
    player.replaceMediaItem(index, current.buildUpon().setMediaMetadata(metadata).build());
  }

  private static final class LyricTimeline {
    final ArrayList<Long> starts;
    final ArrayList<String> texts;

    LyricTimeline(ArrayList<Long> starts, ArrayList<String> texts) {
      this.starts = starts;
      this.texts = texts;
    }

    int indexAt(long positionMs) {
      int lo = 0;
      int hi = starts.size() - 1;
      int answer = -1;
      while (lo <= hi) {
        int mid = (lo + hi) >>> 1;
        if (starts.get(mid) <= positionMs) {
          answer = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      return answer;
    }
  }

  @Override
  public MediaSession onGetSession(MediaSession.ControllerInfo controllerInfo) {
    return session;
  }

  @Override
  public void onTaskRemoved(Intent rootIntent) {
    // 任务卡片被划掉时：
    // 若当前未在播放（已暂停、停止、无曲目或播放完毕），主动退出前台服务避免孤立悬挂
    if (player == null || !player.getPlayWhenReady()
        || player.getMediaItemCount() == 0
        || player.getPlaybackState() == androidx.media3.common.Player.STATE_ENDED
        || player.getPlaybackState() == androidx.media3.common.Player.STATE_IDLE) {
      stopSelf();
    }
  }

  @Override
  public void onDestroy() {
    lyricHandler.removeCallbacksAndMessages(null);
    lyricTimelines.clear();
    lyricRevisions.clear();
    originalArtists.clear();
    if (activeService == this) activeService = null;
    if (session != null) {
      session.release();
      session = null;
    }
    if (player != null) {
      player.release();
      player = null;
    }
    super.onDestroy();
  }

  /**
   * 熄屏自愈：把 ExoPlayer 的重试窗口拉长到覆盖上游风控冷却。
   *
   * ⚠️ 实测报障：后台播几首就停、解锁屏幕后才恢复。
   * 根因是**唯一的自愈在 WebView 的 JS 里**（player store 的 handlePlaybackError），
   * 而熄屏后安卓会挂起 WebView 的 JS（见上方 setPauseAtEndOfMediaItems 的注释）。
   * 服务端在解析失败/冷却中回 503、上游取流失败回 502、中途断流直接断 socket 时，
   * ExoPlayer 按默认策略只重试 3 次（累计约 25s）就放弃 —— 之后没有任何东西会再试，
   * 于是停在那里等解锁。
   *
   * 这里把重试拉长到约 6 分钟，且**完全在原生层完成**（不依赖 WebView 是否在跑）。
   * 每次重试都是重新请求同一个 `/api/stream/<id>?t=<token>`，服务端会重新解析音源，
   * 所以冷却一过就能自动接上。
   */
  @OptIn(markerClass = UnstableApi.class)
  private static final class SuenRetryPolicy extends DefaultLoadErrorHandlingPolicy {
    /**
     * 逐次重试的间隔（毫秒），累计约 6 分钟。
     * 覆盖 qqCooldown（60s 起、上限 600s）与 biliCooldown 的窗口。
     */
    private static final long[] RETRY_DELAYS_MS = {
        2_000, 5_000, 10_000, 20_000, 30_000, 45_000, 60_000, 60_000, 60_000, 60_000
    };

    @Override
    public int getMinimumLoadableRetryCount(int dataType) {
      return RETRY_DELAYS_MS.length;
    }

    @Override
    public long getRetryDelayMsFor(LoadErrorHandlingPolicy.LoadErrorInfo loadErrorInfo) {
      // 默认策略认定"不可重试"的（解析错误、文件不存在等）保持不重试 —— 只拉长可重试错误的间隔
      if (super.getRetryDelayMsFor(loadErrorInfo) == C.TIME_UNSET) return C.TIME_UNSET;
      // errorCount 从 1 开始计
      final int idx = loadErrorInfo.errorCount - 1;
      if (idx < 0 || idx >= RETRY_DELAYS_MS.length) return C.TIME_UNSET; // 不再重试，交由 WebView
      return RETRY_DELAYS_MS[idx];
    }
  }

}
