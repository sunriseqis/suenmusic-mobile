package com.suenmusic.app;

import android.content.Context;
import androidx.annotation.OptIn;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.database.StandaloneDatabaseProvider;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.datasource.cache.CacheDataSource;
import androidx.media3.datasource.cache.CacheSpan;
import androidx.media3.datasource.cache.ContentMetadata;
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor;
import androidx.media3.datasource.cache.SimpleCache;
import java.io.File;
import java.util.Set;

/**
 * 离线音频缓存（v1 的 L1：边播边存）。
 *
 * 设计要点（都是踩过的坑换来的）：
 *
 * 1. **缓存键 = 曲目 id，不是 URL。**
 *    流地址带时效签名（`?t=...`），签名一换 URL 就变——按 URL 做键会让缓存
 *    在签名轮换后集体失效。曲目 id 稳定，换路径（内网/反代）、换令牌都不影响。
 *
 * 2. **容量 4GB，LRU 淘汰**（用户拍板）。
 *    超出后自动丢最久没播的；用户不需要手动清理。
 *
 * 3. **放在 external-files 目录**：不占应用内部数据配额，卸载时一并清除。
 *
 * 4. **单例与容灾**：SimpleCache 每个进程只能有一个实例。
 *    若 SQLite 数据库因断电损坏，自动清空损坏索引并重建；若仍失败则优雅降级为直连，
 *    彻底杜绝服务启动死循环崩溃（CrashLoop）。
 */
@UnstableApi
public final class SuenAudioCache {

  /** 缓存上限：4GB（用户拍板），超出 LRU 淘汰 */
  private static final long MAX_BYTES = 4L * 1024 * 1024 * 1024L;

  private static final String DIR_NAME = "suen-audio-cache";

  private static SimpleCache cache;
  private static DataSource.Factory factory;

  private SuenAudioCache() {}

  private static void deleteRecursively(File file) {
    if (file == null || !file.exists()) return;
    if (file.isDirectory()) {
      File[] children = file.listFiles();
      if (children != null) {
        for (File child : children) {
          deleteRecursively(child);
        }
      }
    }
    file.delete();
  }

  private static synchronized File cacheDir(Context ctx) {
    File base = ctx.getExternalFilesDir(null);
    if (base == null) base = ctx.getFilesDir();   // 外部存储不可用时退回内部
    return new File(base, DIR_NAME);
  }

  /** 取（或懒建）进程内唯一的 SimpleCache，含崩溃自愈与降级保护 */
  public static synchronized SimpleCache get(Context ctx) {
    if (cache == null) {
      File dir = cacheDir(ctx);
      if (!dir.exists() && !dir.mkdirs()) {
        android.util.Log.w("SuenAudioCache", "缓存目录创建失败：" + dir.getAbsolutePath());
      }
      try {
        cache = new SimpleCache(
            dir,
            new LeastRecentlyUsedCacheEvictor(MAX_BYTES),
            new StandaloneDatabaseProvider(ctx)
        );
      } catch (Throwable e) {
        android.util.Log.e("SuenAudioCache", "SimpleCache 初始化失败，尝试重置索引重建", e);
        deleteRecursively(dir);
        if (!dir.exists()) dir.mkdirs();
        try {
          cache = new SimpleCache(
              dir,
              new LeastRecentlyUsedCacheEvictor(MAX_BYTES),
              new StandaloneDatabaseProvider(ctx)
          );
        } catch (Throwable e2) {
          android.util.Log.e("SuenAudioCache", "重置后二次初始化失败，降级为直连无缓存模式", e2);
          cache = null;
        }
      }
    }
    return cache;
  }

  /** 播放器要用的数据源工厂：优先读缓存，未命中则走上游并写入缓存；缓存不可用时降级直连 */
  public static synchronized DataSource.Factory dataSourceFactory(Context ctx) {
    if (factory == null) {
      DefaultHttpDataSource.Factory httpFactory = new DefaultHttpDataSource.Factory()
          .setUserAgent("SuenMusic/1.0 (Android)")
          .setConnectTimeoutMs(8_000)
          .setReadTimeoutMs(15_000);

      SimpleCache c = get(ctx);
      if (c == null) {
        factory = httpFactory;
      } else {
        factory = new CacheDataSource.Factory()
            .setCache(c)
            .setUpstreamDataSourceFactory(httpFactory)
            .setCacheKeyFactory(dataSpec ->
                dataSpec.key != null ? dataSpec.key : dataSpec.uri.toString())
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR);
      }
    }
    return factory;
  }

  public static long maxBytes() {
    return MAX_BYTES;
  }

  /** 已用字节（缓存索引损坏时给 0，界面按"未知"处理） */
  public static long usedBytes(Context ctx) {
    try {
      SimpleCache c = get(ctx);
      return c != null ? c.getCacheSpace() : 0;
    } catch (Exception e) {
      return 0;
    }
  }

  /**
   * 清空缓存。仅由用户在设置页显式触发 —— 播放中清空会让当前曲目重新拉流。
   */
  @OptIn(markerClass = UnstableApi.class)
  public static synchronized void clear(Context ctx) {
    try {
      SimpleCache c = get(ctx);
      if (c != null) {
        Set<String> keys = c.getKeys();
        for (String k : keys) c.removeResource(k);
      }
    } catch (Exception e) {
      android.util.Log.w("SuenAudioCache", "清空缓存失败：" + e.getMessage());
    }
  }

  /**
   * 清掉**单首**曲目的缓存。
   *
   * 用途：重新锚定音源后，缓存键（曲目 id）没变、内容却已经换了音源 ——
   * 不清掉的话 CacheDataSource 会继续回放旧音源的字节，表现为"锚定了却没变化"。
   */
  @OptIn(markerClass = UnstableApi.class)
  public static synchronized void evict(Context ctx, String id) {
    if (id == null || id.isEmpty()) return;
    try {
      SimpleCache c = get(ctx);
      if (c != null) c.removeResource(id);
    } catch (Exception e) {
      android.util.Log.w("SuenAudioCache", "驱逐缓存失败 " + id + "：" + e.getMessage());
    }
  }

  /**
   * 这首曲子是否**完整且连续**在缓存里（离线播放判定用）。
   *
   * 采用 Media3 原生 c.isCached(id, 0, length) 判定整段连续性，
   * 避免拖动跳段产生的空洞导致离线播放卡住。
   */
  @OptIn(markerClass = UnstableApi.class)
  public static synchronized boolean isFullyCached(Context ctx, String id) {
    if (id == null || id.isEmpty()) return false;
    try {
      SimpleCache c = get(ctx);
      if (c == null) return false;
      long length = ContentMetadata.getContentLength(c.getContentMetadata(id));
      if (length <= 0) return false;
      return c.isCached(id, 0, length);
    } catch (Exception e) {
      return false;
    }
  }
}
