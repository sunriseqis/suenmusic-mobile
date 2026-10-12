/**
 * 「当前播放」快照：App 侧写、卡片侧读。
 *
 * 为什么必须落盘而不能用内存：FormExtensionAbility 是**独立进程**，
 * 拿不到 App 进程里的任何内存状态。同一沙箱内跨 Extension 可用的
 * 轻量通道只有 preferences，所以它就是这个功能的**唯一数据通路**。
 *
 * 序列化用 JSON 字符串而不是对象：`createFormBindingData` 明确接受
 * `Object | string`，走字符串这一侧就绕开了 ArkTS「对象字面量不能当类型」
 * 和「不能带 undefined 键」这两条限制（本项目已经各踩过一次）。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';

const TAG = 'SuenMusic_Card';
const DOMAIN = 0x0000;

const STORE_NAME = 'suenmusic_widget';
const KEY_NOW_PLAYING = 'now_playing';

/** 卡片封面在 formImages 里登记的 key。卡片侧用 Image('memory://suen_cover_img') 显示。 */
export const CARD_COVER_KEY = 'suen_cover_img';

/** 封面字节落盘的文件名（相对 cacheDir）。与 Index.ets 的 CARD_COVER_PATH 保持一致。 */
const CARD_COVER_PATH = '/card_cover.img';

/**
 * 打开已落盘的卡片封面 fd（-1 = 文件不存在/打开失败，调用方按无封面降级）。
 * EntryAbility 纠正 alive 标志推卡时用它，避免 formImages 缺失导致卡片丢封面。
 */
export function openCoverFd(ctx: common.Context): number {
  try {
    const file = fileIo.openSync(ctx.cacheDir + CARD_COVER_PATH, fileIo.OpenMode.READ_ONLY);
    return file.fd;
  } catch (err) {
    hilog.warn(DOMAIN, TAG, '封面文件打开失败（卡片按无封面降级）：%{public}s', JSON.stringify(err));
    return -1;
  }
}

/** 关 fd（-1 直接忽略）。 */
export function closeCoverFd(fd: number): void {
  if (fd < 0) {
    return;
  }
  try {
    fileIo.closeSync(fd);
  } catch (err) {
    hilog.warn(DOMAIN, TAG, '封面 fd 关闭失败：%{public}s', JSON.stringify(err));
  }
}

/** 卡片要显示的内容。字段全是实值，没有可选字段。 */
export interface NowPlayingSnapshot {
  /** 歌名 */
  title: string;
  /** 歌手 */
  artist: string;
  /** 封面 URL（仅作 App 内部比对用；卡片显示走 formImages 落盘文件） */
  coverUrl: string;
  /** 是否正在播放 */
  playing: boolean;
  /** 当前曲目是否已收藏（红心） */
  favorite: boolean;
  /** 当前曲目的原始 LRC 歌词（空串 = 没有歌词） */
  lyric: string;
  /** 当前播放位置（毫秒）。卡片用它算歌词该滚到哪一行 */
  positionMs: number;
  /** 封面字节是否已落盘到 cacheDir/card_cover.img（formImages 的前提） */
  coverReady: boolean;
  /**
   * 应用进程是否活着（且 WebView 已可受控）。
   * 卡片靠它在 call（后台直达）与 router（冷启动拉前台）之间分流：
   * alive=true → call，不惊动前台；alive=false → router，完整拉起。
   * App 每次推卡必置 true；EntryAbility.onDestroy 置 false；
   * 进程被系统杀掉（onDestroy 不保证回调）留下陈旧 true 时，
   * 由 call 冷启动路径检测并纠正（见 EntryAbility.healStaleAliveFlag）。
   */
  alive: boolean;
  /** 快照写入时间戳（毫秒） */
  updatedAt: number;
}

/** 没在听的时候长什么样。写实值而不是空串，是为了让卡片有话可说。 */
export function emptySnapshot(): NowPlayingSnapshot {
  const snap: NowPlayingSnapshot = {
    title: '还没在听',
    artist: '打开 SuenMusic 放首歌',
    coverUrl: '',
    playing: false,
    favorite: false,
    lyric: '',
    positionMs: 0,
    coverReady: false,
    alive: false,
    updatedAt: 0
  };
  return snap;
}

function storeOptions(): preferences.Options {
  const opts: preferences.Options = { name: STORE_NAME };
  return opts;
}

/**
 * 同步读。
 *
 * 必须同步：`onAddForm` 的返回值不能是 Promise，系统当场就要拿数据。
 * （SDK 也提示 FormExtensionAbility 空闲 10 秒就被清理，回调里别做耗时操作。）
 *
 * 落盘的 JSON 可能是**旧版本写进去的**（缺 positionMs / coverReady），
 * 所以这里解析后逐字段归一化，绝不把 undefined 放出函数。
 */
export function readSnapshotSync(ctx: common.Context): NowPlayingSnapshot {
  try {
    // 先清缓存再加载：preferences 实例会缓存文件内容，而 App 进程的写入
    // 不会通知卡片进程的缓存实例 —— 卡片进程若被系统保活，不清缓存就会
    // 一直读到上次加载时的旧数据。官方 FAQ（服务卡片与主应用共享持久化
    // 数据）要求的正是这一步。
    preferences.removePreferencesFromCacheSync(ctx, STORE_NAME);
    const store = preferences.getPreferencesSync(ctx, storeOptions());
    const raw = store.getSync(KEY_NOW_PLAYING, '');
    if (typeof raw !== 'string' || raw.length === 0) {
      return emptySnapshot();
    }
    const parsed = JSON.parse(raw) as NowPlayingSnapshot;
    const snap: NowPlayingSnapshot = {
      title: typeof parsed.title === 'string' ? parsed.title : '',
      artist: typeof parsed.artist === 'string' ? parsed.artist : '',
      coverUrl: typeof parsed.coverUrl === 'string' ? parsed.coverUrl : '',
      playing: parsed.playing === true,
      favorite: parsed.favorite === true,
      lyric: typeof parsed.lyric === 'string' ? parsed.lyric : '',
      positionMs: typeof parsed.positionMs === 'number' ? parsed.positionMs : 0,
      coverReady: parsed.coverReady === true,
      alive: parsed.alive === true,
      updatedAt: typeof parsed.updatedAt === 'number' ? parsed.updatedAt : 0
    };
    return snap;
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'readSnapshotSync 失败: %{public}s', JSON.stringify(err));
    return emptySnapshot();
  }
}

/** 异步写（App 侧常规调用）。 */
export async function writeSnapshot(ctx: common.Context, snap: NowPlayingSnapshot): Promise<void> {
  try {
    const store = await preferences.getPreferences(ctx, storeOptions());
    await store.put(KEY_NOW_PLAYING, JSON.stringify(snap));
    await store.flush();
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'writeSnapshot 失败: %{public}s', JSON.stringify(err));
  }
}

/**
 * 同步写。onDestroy 里用 —— 那里拿不到"等异步 flush"的时间预算，
 * 而且 onDestroy 之后进程随时可能被收走，异步路径等于没写。
 */
export function writeSnapshotSync(ctx: common.Context, snap: NowPlayingSnapshot): void {
  try {
    const store = preferences.getPreferencesSync(ctx, storeOptions());
    store.putSync(KEY_NOW_PLAYING, JSON.stringify(snap));
    store.flushSync();
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'writeSnapshotSync 失败: %{public}s', JSON.stringify(err));
  }
}

// ---------------------------------------------------------------------------
// LRC 解析：卡片歌词按时间轴滚动的数据来源
// ---------------------------------------------------------------------------

/** 一行带时间戳的歌词 */
export interface LyricLine {
  timeMs: number;
  text: string;
}

/**
 * 解析 LRC。容忍三种粒度的时间标签（[mm:ss] / [mm:ss.xx] / [mm:ss.xxx]），
 * 一行多标签展开成多行（QQ 音乐源常见）。元数据标签（[ar:] 等）不匹配
 * 时间正则、会被自然跳过。
 */
export function parseLyricLines(raw: string): LyricLine[] {
  const out: LyricLine[] = [];
  if (!raw || raw.length === 0) {
    return out;
  }
  const rows = raw.split('\n');
  for (const row of rows) {
    const times: number[] = [];
    const re = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g;
    let m = re.exec(row);
    while (m !== null) {
      const min = parseInt(m[1]);
      const sec = parseInt(m[2]);
      const fracStr = m[3] || '0';
      let frac = 0;
      if (fracStr.length === 1) {
        frac = parseInt(fracStr) * 100;
      } else if (fracStr.length === 2) {
        frac = parseInt(fracStr) * 10;
      } else {
        frac = parseInt(fracStr);
      }
      times.push(min * 60000 + sec * 1000 + frac);
      m = re.exec(row);
    }
    if (times.length === 0) {
      continue;
    }
    const text = row.replace(/\[[^\]]*\]/g, '').trim();
    if (text.length === 0) {
      continue;
    }
    for (const t of times) {
      const line: LyricLine = { timeMs: t, text: text };
      out.push(line);
    }
  }
  out.sort((a: LyricLine, b: LyricLine) => a.timeMs - b.timeMs);
  return out;
}

/** 播放位置对应的活跃行下标（-1 = 前奏/间奏，没有可高亮的行） */
export function activeLyricIndex(lines: LyricLine[], positionMs: number): number {
  if (lines.length === 0) {
    return -1;
  }
  let idx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].timeMs <= positionMs) {
      idx = i;
    } else {
      break;
    }
  }
  return idx;
}

/** 卡片歌词窗口的行数。卡片数据有大小限制，窗口比全量歌词更稳 */
const CARD_WINDOW_LINES = 6;

/** 卡片歌词的长度上限。卡片推送数据有大小限制，歌词只当展示层、宁可截断 */
const MAX_CARD_LYRIC_LEN = 800;

/** 歌词窗口：当前行 ± 若干行的文本，以及当前行在窗口内的下标 */
export interface LyricWindow {
  /** 窗口内各行，'\n' 连接 */
  text: string;
  /** 当前行在窗口内的下标（-1 = 无） */
  activeIndex: number;
}

/**
 * 按播放位置裁一个"当前行附近"的歌词窗口。
 * 窗口 = max(0, 当前行-1) 起、共 CARD_WINDOW_LINES 行，当前行尽量靠前
 * （它后面还有 3 行可看，滚动感由此而来）。
 */
export function buildLyricWindow(raw: string, positionMs: number): LyricWindow {
  const lines = parseLyricLines(raw);
  if (lines.length === 0) {
    const empty: LyricWindow = { text: '', activeIndex: -1 };
    return empty;
  }
  const active = activeLyricIndex(lines, positionMs);
  const start = active < 0 ? 0 : Math.max(0, active - 1);
  const end = Math.min(lines.length, start + CARD_WINDOW_LINES);
  const parts: string[] = [];
  for (let i = start; i < end; i++) {
    parts.push(lines[i].text);
  }
  let text = parts.join('\n');
  if (text.length > MAX_CARD_LYRIC_LEN) {
    text = text.substring(0, MAX_CARD_LYRIC_LEN);
  }
  const win: LyricWindow = { text: text, activeIndex: active - start };
  return win;
}

// ---------------------------------------------------------------------------
// 卡片 payload
// ---------------------------------------------------------------------------

/**
 * 推给卡片的数据。
 *
 * ⚠️ 这里的字段名就是 createFormBindingData 推数据的 key，必须与
 * `SuenFormCard` 里 `@LocalStorageProp('key')` 的 key **完全一致** ——
 * 卡片管理服务按同名 key 注入。
 *
 * ⚠️ 官方文档（ArkTS卡片页面刷新概述）明确：卡片侧接收数据时**一律被
 * 转成 string**。所以这里全部用 string 表达（playing 用 'true'/'false'），
 * 卡片端按字符串比较，避免类型失真。
 */
export interface CardPayload {
  suen_title: string;
  suen_artist: string;
  /** 'memory://suen_cover_img'（封面已落盘）或 ''（画占位块） */
  suen_cover: string;
  suen_playing: string;
  suen_favorite: string;
  /** 歌词窗口文本（'\n' 分行） */
  suen_lyric: string;
  /** 当前行在窗口内的下标（字符串数字，'-1' = 无） */
  suen_lyric_active: string;
  /** 应用进程是否活着（'true' → 卡片按钮走 call；'false' → 走 router 冷启动） */
  suen_alive: string;
  /** 卡片外观规格（formInfo.FormDimension 的数值字符串：'2'=2*2，'3'=2*4） */
  suen_dimension: string;
}

/**
 * @param dimension 卡片外观规格（'2'=2*2，'3'=2*4）。每张卡片的规格固定，
 *   由调用方从 want（onAddForm）或 RunningFormInfo.dimension（主动刷新）取。
 */
export function toCardPayload(snap: NowPlayingSnapshot, dimension: string): CardPayload {
  const win = buildLyricWindow(snap.lyric, snap.positionMs);
  const p: CardPayload = {
    suen_title: snap.title,
    suen_artist: snap.artist,
    suen_cover: snap.coverReady ? `memory://${CARD_COVER_KEY}` : '',
    suen_playing: snap.playing ? 'true' : 'false',
    suen_favorite: snap.favorite ? 'true' : 'false',
    suen_lyric: win.text,
    suen_lyric_active: String(win.activeIndex),
    suen_alive: snap.alive ? 'true' : 'false',
    suen_dimension: dimension
  };
  return p;
}

/**
 * 组装 createFormBindingData 的最终入参：payload 字段平铺 + 可选的
 * formImages（封面 fd）。SDK 对 formImages 的要求见
 * @ohos.app.form.formBindingData.d.ts：{'formImages': {'key1': fd1}}，
 * fd 指向的文件单张不超过 2MB。
 *
 * ⚠️ fd 由调用方打开、调用方负责关闭（onAddForm 例外：返回值要参与
 * IPC 序列化，不能提前关）。
 */
export function buildFormBindingObject(snap: NowPlayingSnapshot, dimension: string, coverFd: number): Record<string, Object> {
  const p = toCardPayload(snap, dimension);
  const obj: Record<string, Object> = {
    'suen_title': p.suen_title,
    'suen_artist': p.suen_artist,
    'suen_cover': p.suen_cover,
    'suen_playing': p.suen_playing,
    'suen_favorite': p.suen_favorite,
    'suen_lyric': p.suen_lyric,
    'suen_lyric_active': p.suen_lyric_active,
    'suen_alive': p.suen_alive,
    'suen_dimension': p.suen_dimension
  };
  if (coverFd >= 0) {
    // key 与 CARD_COVER_KEY 一致；卡片侧 Image('memory://suen_cover_img')
    const imgs: Record<string, number> = { 'suen_cover_img': coverFd };
    obj['formImages'] = imgs;
  }
  return obj;
}
