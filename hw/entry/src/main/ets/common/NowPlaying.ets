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

const TAG = 'SuenMusic_Card';
const DOMAIN = 0x0000;

const STORE_NAME = 'suenmusic_widget';
const KEY_NOW_PLAYING = 'now_playing';

/** 卡片要显示的内容。字段全是实值，没有可选字段。 */
export interface NowPlayingSnapshot {
  /** 歌名 */
  title: string;
  /** 歌手 */
  artist: string;
  /** 封面 URL（空串 = 没有封面，卡片画占位块） */
  coverUrl: string;
  /** 是否正在播放 */
  playing: boolean;
  /** 快照写入时间戳（毫秒），卡片用来显示"更新于…" */
  updatedAt: number;
}

/** 没在听的时候长什么样。写实值而不是空串，是为了让卡片有话可说。 */
export function emptySnapshot(): NowPlayingSnapshot {
  const snap: NowPlayingSnapshot = {
    title: '还没在听',
    artist: '打开 SuenMusic 放首歌',
    coverUrl: '',
    playing: false,
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
 */
export function readSnapshotSync(ctx: common.Context): NowPlayingSnapshot {
  try {
    const store = preferences.getPreferencesSync(ctx, storeOptions());
    const raw = store.getSync(KEY_NOW_PLAYING, '');
    if (typeof raw !== 'string' || raw.length === 0) {
      return emptySnapshot();
    }
    const snap = JSON.parse(raw) as NowPlayingSnapshot;
    return snap;
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'readSnapshotSync 失败: %{public}s', JSON.stringify(err));
    return emptySnapshot();
  }
}

/** 异步写（App 侧调用）。 */
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
 * 推给卡片的数据。
 *
 * ⚠️ 字段名必须同时对上三处，改任何一处都要三处一起改：
 *   1. 这里的字段名
 *   2. `form_config.json` 的 `metadata[].value`
 *   3. `SuenFormCard` 里 `@LocalStorageProp('key')` 的 key
 *
 * 所以把它做成一个共享转换函数：App 侧主动刷新、卡片侧 onAddForm/onUpdateForm
 * 都走它，两边不可能走偏。
 */
export interface CardPayload {
  title: string;
  artist: string;
  coverUrl: string;
  playing: boolean;
}

export function toCardPayload(snap: NowPlayingSnapshot): CardPayload {
  const p: CardPayload = {
    title: snap.title,
    artist: snap.artist,
    coverUrl: snap.coverUrl,
    playing: snap.playing
  };
  return p;
}
