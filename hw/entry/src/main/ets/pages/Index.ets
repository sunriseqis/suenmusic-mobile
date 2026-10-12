import { webview } from '@kit.ArkWeb';
import { bundleManager, common, Want, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { avSession } from '@kit.AVSessionKit';
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { formBindingData, formProvider, formInfo } from '@kit.FormKit';
import {
  NowPlayingSnapshot,
  writeSnapshot,
  buildFormBindingObject,
  LyricLine,
  parseLyricLines,
  activeLyricIndex
} from '../common/NowPlaying';
import { attachWebviewController, markWebPageReady } from '../common/PlayerControlHub';

const TAG = 'SuenMusic_IndexPage';
const DOMAIN = 0x0000;
const LOCAL_ORIGIN = 'http://localhost';
/** 卡片封面文件（formImages 的数据源），与 FormExtensionAbility 共享沙箱 */
const CARD_COVER_PATH = '/card_cover.img';

/**
 * web 侧送来的曲目信息。**两条消息共用同一个形状**：
 *   - `SuenHarmony.updateMediaMetadata(metaJson)` —— 曲目变化时推元数据
 *   - `SuenHarmony.updateLyric(payloadJson)`      —— 歌词消息，**也带完整元数据**
 *
 * 之所以让歌词消息也带元数据：两条路若只有一条能到（历史上就是这样），
 * 控件就会整条缺失。带上之后，任何一条先到都能把播控中心建立起来。
 */
interface MusicMetadataParam {
  assetId?: string;
  title?: string;
  artist?: string;
  album?: string;
  coverUrl?: string;
  durationMs?: number;
  lyric?: string;
  /** 当前曲目是否已收藏（web 侧收藏集合的已知状态） */
  favorite?: boolean;
}

/** web 侧收藏变化上报的形状（SuenHarmony.updateFavorite） */
interface FavoriteUpdateParam {
  assetId?: string;
  favorite?: boolean;
}

interface PlaybackStateJsonData {
  state?: string;
  positionMs?: number;
  durationMs?: number;
}

class HarmonyAVSessionManager {
  private session: avSession.AVSession | null = null;
  private context: common.UIAbilityContext;
  private webviewController: webview.WebviewController;
  private currentPixelMap: image.PixelMap | null = null;
  private currentCoverUrl: string = '';
  private currentMetadata: avSession.AVMetadata | null = null;
  /** 当前这首的 assetId。歌词只对"当时那首"有效，靠它判断一次歌词该不该收 */
  private currentAssetId: string = '';
  /** 当前这首的歌词。**单独存**，不再借"伪造一条 AVMetadata"来表达 */
  private currentLyric: string = '';
  /**
   * 元数据上报的单调序号。
   *
   * 一次切歌会触发多次上报（加载时 + loadedmetadata），JS 侧是发完就不管
   * （不 await），所以多个 async 调用会同时在飞 —— 谁最后 resolve 谁就赢。
   * 封面下载走网络（超时预算 5s+5s），旧的那次如果晚回来就会把新歌覆盖，
   * 表现就是「切歌后仍显示上一首」。只有序号等于最新值的结果才允许落地。
   */
  private metaSeq: number = 0;
  private isContinuousTaskRunning: boolean = false;
  private stopTaskTimer: number = -1;

  // ---- 桌面卡片用的当前曲目（播放状态变化时不必等元数据重来一遍） ----
  private isPlaying: boolean = false;
  private currentCardTitle: string = '';
  private currentCardArtist: string = '';
  private currentCardCover: string = '';
  /** 当前曲目是否已收藏（web 收藏集合的已知状态，卡片红心用） */
  private currentFavorite: boolean = false;
  /** 当前播放位置（毫秒）。web 每 ~1s 上报一次，卡片歌词靠它滚动 */
  private currentPositionMs: number = 0;
  /** 封面字节是否已落盘（卡片 formImages 的前提） */
  private coverFileReady: boolean = false;
  /** 最新下载的封面原始字节（写盘 + 解码共用一次下载） */
  private cachedCoverBuffer: ArrayBuffer | undefined = undefined;
  /** 卡片上次推送时的歌词活跃行（-2 = 尚未算过；行变化才推卡片） */
  private lastCardLyricIndex: number = -2;
  /** LRC 解析缓存：currentLyric 变了才重 parse */
  private lyricCacheSource: string = '';
  private lyricCacheLines: LyricLine[] = [];

  constructor(context: common.UIAbilityContext, webviewController: webview.WebviewController) {
    this.context = context;
    this.webviewController = webviewController;
  }

  async init(): Promise<void> {
    try {
      this.session = await avSession.createAVSession(this.context, 'SuenMusicSession', 'audio');
      await this.session.activate();
      hilog.info(DOMAIN, TAG, 'AVSession created and activated successfully');
      this.registerSessionListeners();
      // 会话一建好就先给它一条**只有应用名**的最小元数据：系统要看到会话有
      // 元数据才会在锁屏/播控中心给出那条控件。真曲目信息随后被覆盖。
      // 这里写应用名而不是编一个歌名 —— 不知道就不知道，别骗系统。
      await this.pushMinimalMetadata();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to create AVSession: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 推一条最小元数据（只有应用名），保证播控中心那条控件先出现。
   *
   * ⚠️ 同样遵守"不写 undefined 键"的规矩：只给 assetId/title/artist/album，
   * 不碰 lyric 与 mediaImage。
   */
  private async pushMinimalMetadata(): Promise<void> {
    const session = this.session;
    if (!session) return;
    const metadata: avSession.AVMetadata = {
      assetId: 'suen_app',
      title: 'SuenMusic',
      artist: 'SuenMusic',
      album: 'SuenMusic',
      duration: 0
    };
    this.currentMetadata = metadata;
    try {
      await session.setAVMetadata(metadata);
      hilog.info(DOMAIN, TAG, 'setAVMetadata(最小元数据) success');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setAVMetadata(最小元数据) failed: %{public}s', JSON.stringify(err));
    }
  }

  private registerSessionListeners(): void {
    if (!this.session) return;

    this.session.on('play', () => {
      hilog.info(DOMAIN, TAG, 'AVSession received: play');
      this.dispatchWebControl('play');
    });

    this.session.on('pause', () => {
      hilog.info(DOMAIN, TAG, 'AVSession received: pause');
      this.dispatchWebControl('pause');
    });

    this.session.on('stop', () => {
      hilog.info(DOMAIN, TAG, 'AVSession received: stop');
      this.dispatchWebControl('stop');
    });

    this.session.on('playNext', () => {
      hilog.info(DOMAIN, TAG, 'AVSession received: playNext');
      this.dispatchWebControl('next');
    });

    this.session.on('playPrevious', () => {
      hilog.info(DOMAIN, TAG, 'AVSession received: playPrevious');
      this.dispatchWebControl('prev');
    });

    this.session.on('seek', (timeMs: number) => {
      hilog.info(DOMAIN, TAG, 'AVSession received: seek %{public}d', timeMs);
      this.dispatchWebControl('seek', timeMs);
    });
  }

  private dispatchWebControl(action: string, param?: number): void {
    try {
      let script = '';
      if (action === 'seek' && typeof param === 'number') {
        script = `if (window.__suenAudioControl) { window.__suenAudioControl.seek(${param}); }`;
      } else {
        script = `if (window.__suenAudioControl) { window.__suenAudioControl.${action}(); }`;
      }
      this.webviewController.runJavaScript(script);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'Failed to run web control script: %{public}s', JSON.stringify(e));
    }
  }

  /**
   * 推送曲目元数据（标题 / 歌手 / 专辑 / 时长）。
   *
   * 两条铁律，都是踩过的坑：
   *
   * 1) **绝不等封面**：封面下载走网络（超时预算 5s + 5s），把它 await 在
   *    setAVMetadata 之前，会让"新歌的元数据被堵在慢网络后面"；而上一首那次
   *    如果晚回来就会覆盖新歌 —— 表现就是「切歌后仍显示上一首」。
   *    现在先推纯文本元数据（立刻生效），封面回来后异步再补一次。
   *
   * 2) **metaSeq 守卫**：一次切歌会触发多次上报，多个 async 调用同时在飞，
   *    谁最后 resolve 谁就赢。只有序号仍是最新值的结果才允许落地。
   */
  async updateMetadata(meta: MusicMetadataParam): Promise<void> {
    try {
      await this.doUpdateMetadata(meta);
    } catch (err) {
      // JS 桥是"发完不管"地调它（不 await），异常绝不能抛回桥 ——
      // 未处理的 Promise 拒绝在鸿蒙上会被记成应用错误。
      hilog.error(DOMAIN, TAG, 'updateMetadata 异常: %{public}s', JSON.stringify(err));
    }
  }

  /** updateMetadata 的实现体。外面那层只负责兜异常 */
  private async doUpdateMetadata(meta: MusicMetadataParam): Promise<void> {
    const session = this.session;
    if (!session) {
      // 以前这里是静默 return —— 元数据被丢弃却毫无痕迹，极难排查
      hilog.error(DOMAIN, TAG, '元数据被丢弃：AVSession 尚未就绪（assetId=%{public}s）',
        meta.assetId || '');
      return;
    }

    const seq = ++this.metaSeq;
    const assetId = meta.assetId || '';

    // 换曲：上一首的歌词、封面、收藏状态立即作废（它们只对"当时那首"有效）
    if (assetId !== this.currentAssetId) {
      this.currentAssetId = assetId;
      this.currentLyric = '';
      this.currentCoverUrl = '';
      this.currentFavorite = false;
      this.coverFileReady = false;
      this.lastCardLyricIndex = -2;
    }
    if (meta.lyric) {
      this.currentLyric = meta.lyric;
    }
    if (meta.favorite !== undefined) {
      this.currentFavorite = meta.favorite;
    }

    // ⚠️⚠️ **绝不能把 undefined 的键塞进 AVMetadata**。
    //
    // 实测代价（2026-10-10）：旧代码这里写的是
    //   `mediaImage: pixelMap || this.currentPixelMap || undefined, lyric: lyricStr || undefined`
    // 那两次 setAVMetadata **一次都没成功过**（catch 里有日志但没人看到），于是
    //   · 歌名一直是「未知曲目」—— 那是 updateLyric 里伪造的那条撑着的
    //   · 封面永远拉不到 —— 封面逻辑压根没跑到
    //   · 切歌后仍显示上一首 —— 元数据从未被更新
    // 而那条伪造数据 `{assetId, title, lyric}` 之所以能成功，正因为它
    // **一个 undefined 字段都没有**。所以这里改成"有值才赋键"。
    const metadata: avSession.AVMetadata = {
      assetId: assetId || 'suen_' + Date.now(),
      title: meta.title || '未知曲目',
      artist: meta.artist || '未知歌手',
      album: meta.album || 'SuenMusic',
      duration: meta.durationMs || 0
    };
    if (this.currentLyric) {
      metadata.lyric = this.currentLyric;
    }
    if (this.currentPixelMap) {
      metadata.mediaImage = this.currentPixelMap;
    }
    this.currentMetadata = metadata;

    try {
      await session.setAVMetadata(metadata);
      hilog.info(DOMAIN, TAG,
        'setAVMetadata(文本) success: seq=%{public}d, title=%{public}s, artist=%{public}s, hasLyric=%{public}s',
        seq, metadata.title || '', metadata.artist || '', metadata.lyric ? 'true' : 'false');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setAVMetadata(文本) failed: %{public}s', JSON.stringify(err));
      return;
    }

    // 桌面卡片跟着换歌（卡片进程读的是 preferences 里的快照，不是内存）
    this.currentCardTitle = meta.title ? meta.title.trim() : '';
    this.currentCardArtist = meta.artist ? meta.artist.trim() : '';
    this.currentCardCover = meta.coverUrl ? meta.coverUrl.trim() : '';
    this.syncCard();

    // 封面单独补，不阻塞上面的标题；回来后必须还是"最新一次"才认
    this.attachCover(meta.coverUrl ? meta.coverUrl.trim() : '', seq);
  }

  /**
   * 把"正在听什么"写进快照，并主动刷新所有桌面卡片。
   *
   * 为什么不靠卡片自己来取：卡片进程是**独立进程**，且 SDK 禁止在那里引用
   * multimedia.media 等模块 —— 它只能被动接收。这里写快照 + updateForm，
   * 才是卡片更新的主动来源（否则只能等 updateDuration 到点的 30 分钟定时刷新）。
   *
   * 封面走官方 formImages 机制（卡片 Image 不能加载网络 URL）：
   * 字节先落盘 cacheDir/card_cover.img → 每次推送前开 fd →
   * `{'formImages': {'suen_cover_img': fd}}` 随 payload 一起送 →
   * 卡片侧 Image('memory://suen_cover_img') 显示。fd 在 IPC 中被系统
   * 复制，await updateForm 之后关掉自己这份是安全的。
   *
   * 失败不外抛：卡片是附加功能，不该因为它拖垮播控中心那条主链路。
   */
  private async syncCard(): Promise<void> {
    const hasTrack = this.currentCardTitle.length > 0;
    const snap: NowPlayingSnapshot = {
      title: hasTrack ? this.currentCardTitle : '还没在听',
      artist: hasTrack ? (this.currentCardArtist.length > 0 ? this.currentCardArtist : '未知歌手') : '打开 SuenMusic 放首歌',
      coverUrl: hasTrack ? this.currentCardCover : '',
      playing: hasTrack && this.isPlaying,
      favorite: hasTrack && this.currentFavorite,
      lyric: hasTrack ? this.currentLyric : '',
      positionMs: this.currentPositionMs,
      coverReady: hasTrack && this.coverFileReady,
      alive: true,
      updatedAt: new Date().getTime()
    };
    // 封面 fd：文件就绪才开，失败降级为无封面（卡片画占位块）
    let coverFd = -1;
    if (snap.coverReady) {
      coverFd = this.openCoverFd();
    }
    try {
      await writeSnapshot(this.context, snap);
      // 注意用的是 RunningFormInfo 而不是 FormInfo —— 后者没有 id 字段，
      // 拿不到 formId 就没法 updateForm（实测踩过：'formId' does not exist）。
      const infos: Array<formInfo.RunningFormInfo> = await formProvider.getPublishedRunningFormInfos();
      if (infos.length === 0) {
        return;
      }
      for (const info of infos) {
        const obj = buildFormBindingObject(snap, this.dimensionOfForm(info), coverFd);
        try {
          // await 之后系统已在 IPC 中复制 fd，可以安全关闭自己这份
          await formProvider.updateForm(info.formId, formBindingData.createFormBindingData(obj));
        } catch (err) {
          hilog.error(DOMAIN, TAG, '卡片刷新失败 formId=%{public}s: %{public}s',
            info.formId, JSON.stringify(err));
        }
      }
      hilog.info(DOMAIN, TAG, '已刷新 %{public}d 张桌面卡片：%{public}s（封面 fd=%{public}d）',
        infos.length, snap.title, coverFd);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'syncCard 失败: %{public}s', JSON.stringify(err));
    } finally {
      this.closeCoverFd(coverFd);
    }
  }

  /** 打开卡片封面文件的 fd（-1 = 文件不存在/打开失败，调用方按无封面降级） */
  private openCoverFd(): number {
    try {
      const file = fileIo.openSync(this.context.cacheDir + CARD_COVER_PATH, fileIo.OpenMode.READ_ONLY);
      return file.fd;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '封面文件打开失败（卡片按无封面降级）：%{public}s', JSON.stringify(err));
      return -1;
    }
  }

  private closeCoverFd(fd: number): void {
    if (fd < 0) {
      return;
    }
    try {
      fileIo.closeSync(fd);
    } catch (err) {
      // 关 fd 失败无须处理：fd 生命周期随进程结束
    }
  }

  /** 当前歌词的活跃行下标（带 LRC 解析缓存；positionMs 由 web 每秒上报） */
  private currentLyricActiveIndex(positionMs: number): number {
    if (this.lyricCacheSource !== this.currentLyric) {
      this.lyricCacheSource = this.currentLyric;
      this.lyricCacheLines = parseLyricLines(this.currentLyric);
    }
    return activeLyricIndex(this.lyricCacheLines, positionMs);
  }

  /** 卡片规格 → CardPayload 的 dimension 字符串（与 formInfo.FormDimension 数值一致） */
  private dimensionOfForm(info: formInfo.RunningFormInfo): string {
    return info.dimension === formInfo.FormDimension.Dimension_2_4 ? '3' : '2';
  }

  /**
   * web 侧收藏状态变化上报（SuenHarmony.updateFavorite）。
   *
   * assetId 与当前曲目不符时忽略 —— 上报者（收藏页批量操作等）不知道
   * "正在播哪首"，过滤这一层放在这里。
   */
  updateFavorite(assetId: string, favorite: boolean): void {
    if (assetId.length === 0 || assetId !== this.currentAssetId) {
      hilog.info(DOMAIN, TAG, '收藏上报与非当前曲目不符，忽略（assetId=%{public}s）', assetId);
      return;
    }
    if (this.currentFavorite === favorite) return;
    this.currentFavorite = favorite;
    this.syncCard();
  }

  /**
   * 异步补封面。封面是这个链路里唯一走网络的一步，所以必须自带守卫：
   * 下载期间用户又切了歌（seq 变了），这次的结果就属于旧曲目，连同已解码的
   * PixelMap 一起丢弃 —— 否则旧封面会盖在新歌上。
   *
   * 一次下载两用：原始字节写盘（卡片 formImages 用）+ 解码成 PixelMap
   * （播控中心 mediaImage 用）。写盘失败只降级卡片（画占位块），不阻塞
   * 播控中心那条主链路。
   */
  private async attachCover(cover: string, seq: number): Promise<void> {
    if (!cover) return;
    if (!(cover.startsWith('http://') || cover.startsWith('https://'))) return;

    let buffer: ArrayBuffer | undefined = undefined;
    if (cover === this.currentCoverUrl && this.currentPixelMap && this.cachedCoverBuffer) {
      buffer = this.cachedCoverBuffer;
    } else {
      buffer = await this.downloadCoverData(cover);
    }
    if (!buffer) return;

    if (seq !== this.metaSeq) {
      hilog.info(DOMAIN, TAG, '封面到达时已切歌，丢弃（封面 seq=%{public}d，当前 seq=%{public}d）',
        seq, this.metaSeq);
      return;
    }

    // 1) 字节落盘 —— 卡片 formImages 的数据源（失败只降级，不挡主链路）
    this.coverFileReady = this.saveCoverFile(buffer);
    if (!this.coverFileReady) {
      hilog.warn(DOMAIN, TAG, '封面落盘失败，卡片本次按无封面显示');
    }

    // 2) 解码 PixelMap 给播控中心
    const pixelMap = await this.decodeCoverPixelMap(buffer);
    const session = this.session;
    if (!session || !pixelMap) {
      // 播控中心拿不到封面不算失败：卡片那份已经准备好了
      this.syncCard();
      return;
    }

    // ⚠️ **不释放** this.currentPixelMap：它已经被交给系统播控中心当作
    // mediaImage 了，释放正在被系统持有的 PixelMap 有让那条控件渲染失败的
    // 风险。旧的那张交给 GC 回收即可（每张 512×512，代价可接受）。
    this.currentPixelMap = pixelMap;
    this.currentCoverUrl = cover;
    this.cachedCoverBuffer = buffer;
    const meta = this.currentMetadata;
    if (meta) {
      meta.mediaImage = pixelMap;
    }

    try {
      await session.setAVMetadata(meta);
      hilog.info(DOMAIN, TAG, 'setAVMetadata(补封面) success: seq=%{public}d', seq);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setAVMetadata(补封面) failed: %{public}s', JSON.stringify(err));
    }
    // 3) 卡片补推：封面从"无"变"有"，卡片需要拿到 formImages 才显示得了
    this.syncCard();
  }

  /** 把封面原始字节写进 cacheDir/card_cover.img（覆盖写） */
  private saveCoverFile(buffer: ArrayBuffer): boolean {
    let file: fileIo.File | null = null;
    try {
      const path = this.context.cacheDir + CARD_COVER_PATH;
      file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, buffer);
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '封面落盘失败: %{public}s', JSON.stringify(err));
      return false;
    } finally {
      if (file) {
        try {
          fileIo.closeSync(file);
        } catch (err) {
          // ignore
        }
      }
    }
  }

  /**
   * 更新歌词（系统锁屏 / 播控中心显示用）。
   *
   * ⚠️ 这里曾经在 currentMetadata 为空时**凭空造一条 AVMetadata** 推给系统
   * （assetId 写死 'suen_current'、title 写死 '未知曲目'），于是播控中心一上来
   * 就是「未知曲目」。现在**只用 web 真实送来的数据，绝不编造标题**。
   *
   * ⚠️ 更要紧的一条：**不能依赖 updateMetadata 先到**。web 侧的歌词消息现在
   * 带上了完整元数据，所以单靠这条消息也能把播控中心建立起来 ——
   * 两条路互不依赖，任何一条先到都不会让控件缺失（这是上一版"控件完全消失"
   * 的根因方向：当时歌词消息只在元数据已存在时才推，元数据那条要是没到，
   * 控件就整条都没有了）。
   */
  async updateLyric(payload: MusicMetadataParam): Promise<void> {
    try {
      const session = this.session;
      if (!session) {
        hilog.error(DOMAIN, TAG, '歌词被丢弃：AVSession 尚未就绪');
        return;
      }

      const assetId = payload.assetId || '';

      // 换曲（或首次）：用这条消息自带的元数据把整条状态重建起来。
      // doUpdateMetadata 会推文本、把 lyric 一起带上、再异步补封面。
      if (assetId && assetId !== this.currentAssetId) {
        hilog.info(DOMAIN, TAG, '歌词消息带来新曲目，先重建元数据（assetId=%{public}s）', assetId);
        await this.doUpdateMetadata(payload);
        return;
      }

      const meta = this.currentMetadata;
      if (!meta) {
        // 还没有当前曲目的元数据：这条消息若自带元数据就用它建立，否则只暂存歌词
        if (assetId && (payload.title || payload.artist)) {
          hilog.info(DOMAIN, TAG, '歌词消息自带元数据，先建立播控中心（assetId=%{public}s）', assetId);
          await this.doUpdateMetadata(payload);
          return;
        }
        this.currentLyric = assetId ? payload.lyric || '' : '';
        hilog.info(DOMAIN, TAG, '歌词先于元数据到达，暂存 %{public}d 字（assetId=%{public}s）',
          this.currentLyric.length, assetId || '(空)');
        return;
      }

      // 走到这里说明曲目相同（assetId 为空 = web 那边暂时没有曲目）：
      // 只清/更新歌词，绝不动标题与封面。
      if (!assetId && payload.lyric) {
        hilog.info(DOMAIN, TAG, '歌词缺少 assetId，忽略');
        return;
      }

      const lyric = payload.lyric || '';
      this.currentLyric = lyric;
      // 同上：绝不能赋 undefined。空字符串是"没有歌词"的正常表达。
      meta.lyric = lyric;

      await session.setAVMetadata(meta);
      hilog.info(DOMAIN, TAG, 'setAVMetadata(歌词) success: assetId=%{public}s, len=%{public}d',
        this.currentAssetId || '(空)', lyric.length);

      // 卡片背面显示的歌词跟这一条是同一份 —— 歌词到了就顺带刷卡片
      this.syncCard();
    } catch (err) {
      // 同 updateMetadata：JS 桥不 await，异常绝不能抛回去
      hilog.error(DOMAIN, TAG, 'updateLyric 异常: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 连续任务（AUDIO_PLAYBACK 长时任务）需要的 WantAgent。
   *
   * ⚠️ 这里**故意不写返回类型**，两个"显然"的写法都是错的：
   *   - `Promise<wantAgent.WantAgent>`：`@kit.AbilityKit` 的 wantAgent 命名空间
   *     **没有导出 `WantAgent` 这个名字**（只有 `getWantAgent`），
   *     报 10505001 'wantAgent' has no exported member named 'WantAgent'。
   *   - `Promise<Object>`：`backgroundTaskManager.startBackgroundRunning()`
   *     的第三个参数正是那个未导出的类型，`Object` 是它的父类型、传不进去，
   *     只会把"名字找不到"换成一个新的"类型不匹配"。
   * 交给类型推断：`getWantAgent()` 的返回类型恰好就是 API 期望的那个类型。
   */
  private async getContinuousTaskWantAgent() {
    const bundleName = this.context.abilityInfo?.bundleName || 'com.suenmusic.app';
    const abilityName = this.context.abilityInfo?.name || 'EntryAbility';
    const targetWant: Want = {
      bundleName: bundleName,
      abilityName: abilityName
    };
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [targetWant],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(wantAgentInfo);
  }

  async startContinuousTask(): Promise<void> {
    if (this.isContinuousTaskRunning) {
      return;
    }
    try {
      const agent = await this.getContinuousTaskWantAgent();
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        agent
      );
      this.isContinuousTaskRunning = true;
      hilog.info(DOMAIN, TAG, 'Continuous task AUDIO_PLAYBACK started successfully');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to start continuous task: %{public}s', JSON.stringify(err));
    }
  }

  async stopContinuousTask(): Promise<void> {
    if (!this.isContinuousTaskRunning) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.context);
      this.isContinuousTaskRunning = false;
      hilog.info(DOMAIN, TAG, 'Continuous task AUDIO_PLAYBACK stopped successfully');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to stop continuous task: %{public}s', JSON.stringify(err));
      this.isContinuousTaskRunning = false;
    }
  }

  async updatePlaybackState(stateStr: string, positionMs?: number, durationMs?: number): Promise<void> {
    if (!this.session) return;

    try {
      let state = avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
      if (stateStr === 'playing') {
        state = avSession.PlaybackState.PLAYBACK_STATE_PLAY;
        // 收到播放态：清除待停止定时器，并确保后台长时任务已启动（防止切后台被系统冻结挂起）
        if (this.stopTaskTimer !== -1) {
          clearTimeout(this.stopTaskTimer);
          this.stopTaskTimer = -1;
        }
        await this.startContinuousTask();
      } else if (stateStr === 'stopped' || stateStr === 'idle' || stateStr === 'paused') {
        state = (stateStr === 'stopped' || stateStr === 'idle')
          ? avSession.PlaybackState.PLAYBACK_STATE_STOP
          : avSession.PlaybackState.PLAYBACK_STATE_PAUSE;

        // 暂停或切歌间歇：延时 30 秒停止长时任务。
        // 避免切歌缓冲、短暂停顿导致长时任务被立即注销而引发进程被冻结挂起。
        // 若 30 秒内未恢复播放，则自动释放长时任务以满足系统能效审计要求。
        if (this.stopTaskTimer === -1) {
          this.stopTaskTimer = setTimeout(() => {
            this.stopContinuousTask();
            this.stopTaskTimer = -1;
          }, 30000);
        }
      }

      const elapsed = Math.max(0, Math.round(positionMs || 0));
      const updateTime = new Date().getTime();
      const playbackState: avSession.AVPlaybackState = {
        state: state,
        position: {
          elapsedTime: elapsed,
          updateTime: updateTime
        },
        duration: durationMs || 0
      };

      // 留痕：锁屏歌词的滚动位置由这组数据推算（elapsed + updateTime 外推）。
      // 一旦再出现"控件里比实际快/慢"，这行能直接看出是推的值不对还是外推不对。
      hilog.info(DOMAIN, TAG, 'setAVPlaybackState: state=%{public}d, elapsed=%{public}d, updateTime=%{public}d',
        state, elapsed, updateTime);

      await this.session.setAVPlaybackState(playbackState);

      // web 每 ~1 秒上报一次 positionMs —— 卡片歌词按时间轴滚动靠它。
      // 只在活跃行变化时才推卡片：卡片刷新走 IPC，逐秒推既浪费也不平滑。
      this.currentPositionMs = elapsed;
      const activeIdx = this.currentLyricActiveIndex(elapsed);
      if (activeIdx !== this.lastCardLyricIndex) {
        this.lastCardLyricIndex = activeIdx;
        this.syncCard();
      }

      // 播放/暂停状态一变，卡片上的"播放中/已暂停"就该跟着变
      const nowPlaying = state === avSession.PlaybackState.PLAYBACK_STATE_PLAY;
      if (nowPlaying !== this.isPlaying) {
        this.isPlaying = nowPlaying;
        this.syncCard();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setAVPlaybackState failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 下载封面原始字节。
   *
   * ⚠️ 必须显式 `expectDataType: ARRAY_BUFFER`：不指定时拿到的可能是 string，
   *    下面 `instanceof ArrayBuffer` 就永远为 false —— 封面永远拉不到，
   *    而且旧代码在这条分支上**一行日志都不打**，是它最难排查的地方。
   *    现在三种失败（非 200 / 拿到非二进制 / 解码抛异常）都会留下日志。
   */
  private async downloadCoverData(url: string): Promise<ArrayBuffer | undefined> {
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 5000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        header: {
          'Referer': ''
        }
      });

      if (response.responseCode !== 200) {
        hilog.error(DOMAIN, TAG, '封面下载失败：HTTP %{public}d（%{public}s）',
          response.responseCode, url);
        return undefined;
      }

      if (!(response.result instanceof ArrayBuffer)) {
        hilog.error(DOMAIN, TAG,
          '封面下载拿到的是非二进制内容（HTTP %{public}d）：expectDataType 未生效或上游返回了文本（%{public}s）',
          response.responseCode, url);
        return undefined;
      }
      hilog.info(DOMAIN, TAG, '封面下载成功：%{public}s（%{public}d 字节）',
        url, response.result.byteLength);
      return response.result;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '封面下载异常 %{public}s: %{public}s', url, JSON.stringify(err));
      return undefined;
    } finally {
      httpRequest.destroy();
    }
  }

  /** 解码封面字节为 PixelMap（播控中心 mediaImage 用） */
  private async decodeCoverPixelMap(buffer: ArrayBuffer): Promise<image.PixelMap | undefined> {
    try {
      const imageSource = image.createImageSource(buffer);
      const decodingOptions: image.DecodingOptions = {
        desiredSize: { width: 512, height: 512 }
      };
      const pixelMap = await imageSource.createPixelMap(decodingOptions);
      await imageSource.release();
      hilog.info(DOMAIN, TAG, '封面解码成功');
      return pixelMap;
    } catch (err) {
      hilog.error(DOMAIN, TAG, '封面解码异常: %{public}s', JSON.stringify(err));
      return undefined;
    }
  }

  async destroy(): Promise<void> {
    if (this.stopTaskTimer !== -1) {
      clearTimeout(this.stopTaskTimer);
      this.stopTaskTimer = -1;
    }
    await this.stopContinuousTask();
    if (!this.session) return;
    try {
      if (this.currentPixelMap) {
        await this.currentPixelMap.release();
        this.currentPixelMap = null;
      }
      await this.session.destroy();
      this.session = null;
      hilog.info(DOMAIN, TAG, 'AVSession destroyed');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to destroy AVSession: %{public}s', JSON.stringify(e));
    }
  }
}

class HarmonyBridge {
  private context: common.UIAbilityContext;
  private avSessionManager: HarmonyAVSessionManager;

  constructor(context: common.UIAbilityContext, avSessionManager: HarmonyAVSessionManager) {
    this.context = context;
    this.avSessionManager = avSessionManager;
  }

  // 获取当前原生应用版本号
  getAppVersion(): string {
    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return JSON.stringify({
        versionName: bundleInfo.versionName,
        versionCode: bundleInfo.versionCode,
        platform: 'harmony_next'
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to get bundle info: %{public}s', JSON.stringify(err));
      return JSON.stringify({
        versionName: '1.5',
        versionCode: 20150,
        platform: 'harmony_next'
      });
    }
  }

  // 唤起外部默认浏览器打开链接（用于自更新下载或外部查看）
  openInBrowser(url: string): boolean {
    try {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      };
      this.context.startAbility(want);
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to open browser: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  // 平台标识
  isNativePlatform(): boolean {
    return true;
  }

  getPlatform(): string {
    return 'harmony_next';
  }

  /**
   * 元数据消息与歌词消息**形状相同**，解析逻辑共用。
   * 歌词消息也带完整元数据 —— 这样任何一条先到都能把播控中心建立起来。
   */
  private parseMeta(json: string): MusicMetadataParam {
    const data = JSON.parse(json) as MusicMetadataParam;
    return {
      assetId: String(data.assetId || ''),
      title: String(data.title || ''),
      artist: String(data.artist || ''),
      album: String(data.album || ''),
      coverUrl: String(data.coverUrl || ''),
      durationMs: Number(data.durationMs || 0),
      lyric: String(data.lyric || ''),
      favorite: data.favorite === true
    };
  }

  updateMediaMetadata(metaJson: string): void {
    try {
      const meta = this.parseMeta(metaJson);
      // 入口留痕：这条日志能直接回答"web 到底有没有调这个接口"
      hilog.info(DOMAIN, TAG, '收到元数据上报: assetId=%{public}s, title=%{public}s, 有封面=%{public}s',
        meta.assetId || '', meta.title || '', meta.coverUrl ? 'yes' : 'no');
      this.avSessionManager.updateMetadata(meta);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'updateMediaMetadata parse failed: %{public}s', JSON.stringify(err));
    }
  }

  updatePlaybackState(stateJson: string): void {
    try {
      const data = JSON.parse(stateJson) as PlaybackStateJsonData;
      this.avSessionManager.updatePlaybackState(
        String(data.state || ''),
        Number(data.positionMs || 0),
        Number(data.durationMs || 0)
      );
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'updatePlaybackState parse failed: %{public}s', JSON.stringify(err));
    }
  }

  updateLyric(lyricJson: string): void {
    try {
      const meta = this.parseMeta(lyricJson);
      hilog.info(DOMAIN, TAG, '收到歌词上报: assetId=%{public}s, len=%{public}d, 带元数据=%{public}s',
        meta.assetId || '', meta.lyric ? meta.lyric.length : 0, meta.title ? 'yes' : 'no');
      this.avSessionManager.updateLyric(meta);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'updateLyric parse failed: %{public}s', JSON.stringify(err));
    }
  }

  /** web 侧收藏状态变化上报（toggle 后、收藏集合拉全纠偏后都会调） */
  updateFavorite(favJson: string): void {
    try {
      const data = JSON.parse(favJson) as FavoriteUpdateParam;
      hilog.info(DOMAIN, TAG, '收到收藏上报: assetId=%{public}s, favorite=%{public}s',
        String(data.assetId || ''), data.favorite === true ? 'true' : 'false');
      this.avSessionManager.updateFavorite(String(data.assetId || ''), data.favorite === true);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'updateFavorite parse failed: %{public}s', JSON.stringify(err));
    }
  }
}

@Entry
@Component
struct Index {
  private webviewController: webview.WebviewController = new webview.WebviewController();
  @StorageProp('topAvoidHeight') topAvoidHeight: number = 0;
  @StorageProp('bottomAvoidHeight') bottomAvoidHeight: number = 0;
  private avSessionManager: HarmonyAVSessionManager = new HarmonyAVSessionManager(
    getContext(this) as common.UIAbilityContext,
    this.webviewController
  );
  private bridge: HarmonyBridge = new HarmonyBridge(
    getContext(this) as common.UIAbilityContext,
    this.avSessionManager
  );

  aboutToAppear(): void {
    try {
      // 开启 ArkWeb 调试模式（支持通过 Chrome DevTools inspect 调试）
      webview.WebviewController.setWebDebuggingAccess(true);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to set web debugging: %{public}s', JSON.stringify(err));
    }
    // 把 controller 挂给卡片控制中枢：桌面卡片按钮的指令从那里分发进来
    attachWebviewController(this.webviewController);
    this.avSessionManager.init();
  }

  aboutToDisappear(): void {
    this.avSessionManager.destroy();
  }

  // 拦截系统返回手势/返回键：优先让网页后退
  onBackPress(): boolean {
    if (this.webviewController.accessBackward()) {
      this.webviewController.backward();
      return true;
    }
    return false;
  }

  // 辅助函数：根据文件后缀匹配 MIME 类型
  private getMimeType(filePath: string): string {
    const lower = filePath.toLowerCase();
    if (lower.endsWith('.html') || lower.endsWith('.htm')) return 'text/html';
    if (lower.endsWith('.js') || lower.endsWith('.mjs')) return 'application/javascript';
    if (lower.endsWith('.css')) return 'text/css';
    if (lower.endsWith('.json')) return 'application/json';
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    if (lower.endsWith('.ico')) return 'image/x-icon';
    if (lower.endsWith('.woff')) return 'font/woff';
    if (lower.endsWith('.woff2')) return 'font/woff2';
    if (lower.endsWith('.ttf')) return 'font/ttf';
    if (lower.endsWith('.mp3')) return 'audio/mpeg';
    if (lower.endsWith('.flac')) return 'audio/flac';
    if (lower.endsWith('.m4a')) return 'audio/mp4';
    if (lower.endsWith('.ogg')) return 'audio/ogg';
    return 'application/octet-stream';
  }

  // 从 rawfile 读取本地资源构建 WebResourceResponse
  private loadRawFile(rawPath: string): WebResourceResponse | null {
    try {
      const resMgr = getContext(this).resourceManager;
      const content = resMgr.getRawFileContentSync(rawPath);
      const response = new WebResourceResponse();
      response.setResponseData(content.buffer as ArrayBuffer);
      response.setResponseMimeType(this.getMimeType(rawPath));
      response.setResponseEncoding('utf-8');
      response.setResponseCode(200);
      response.setReasonMessage('OK');
      response.setResponseIsReady(true);
      return response;
    } catch (err) {
      return null;
    }
  }

  build() {
    Column() {
      Web({
        src: `${LOCAL_ORIGIN}/index.html`,
        controller: this.webviewController
      })
        .domStorageAccess(true)
        .fileAccess(true)
        .imageAccess(true)
        .databaseAccess(true) // 启用 IndexedDB 支持封面与元数据离线缓存
        .mixedMode(MixedMode.All)
        .javaScriptAccess(true)
        .mediaPlayGestureAccess(false) // 允许切歌无手势自动连播
        .javaScriptProxy({
          object: this.bridge,
          name: 'SuenHarmony',
          methodList: [
            'getAppVersion',
            'openInBrowser',
            'isNativePlatform',
            'getPlatform',
            'updateMediaMetadata',
            'updatePlaybackState',
            'updateLyric',
            'updateFavorite'
          ],
          controller: this.webviewController
        })
        .onInterceptRequest((event) => {
          if (!event) return null;
          const reqUrl = event.request.getRequestUrl();

          // 仅拦截指向 http://localhost 的本地静态资源请求
          if (!reqUrl.startsWith(`${LOCAL_ORIGIN}/`) && reqUrl !== LOCAL_ORIGIN) {
            return null;
          }

          let relativePath = reqUrl.substring(LOCAL_ORIGIN.length);
          if (relativePath.startsWith('/')) {
            relativePath = relativePath.substring(1);
          }
          relativePath = relativePath.split('?')[0].split('#')[0];

          try {
            relativePath = decodeURIComponent(relativePath);
          } catch (e) {
            // 忽略 URI 解码异常
          }

          if (!relativePath || relativePath === '') {
            relativePath = 'index.html';
          }

          // 1. 优先尝试直接从 rawfile 读取文件
          const directFile = this.loadRawFile(relativePath);
          if (directFile) {
            return directFile;
          }

          // 2. SPA 路由回退：非静态文件请求（无文件扩展名，如 /favorites, /search, /settings）回退返回 index.html
          if (!relativePath.includes('.')) {
            const spaIndex = this.loadRawFile('index.html');
            if (spaIndex) {
              return spaIndex;
            }
          }

          hilog.warn(DOMAIN, TAG, 'Rawfile resource not found: %{public}s', relativePath);
          return null;
        })
        .onConsole((event) => {
          if (event) {
            hilog.info(DOMAIN, TAG, 'WebConsole: %{public}s', event.message.getMessage());
          }
          return false;
        })
        .onErrorReceive((event) => {
          if (event) {
            hilog.error(DOMAIN, TAG, 'WebError: %{public}s, code: %{public}d',
              event.error.getErrorInfo(), event.error.getErrorCode());
          }
        })
        .onHttpErrorReceive((event) => {
          if (event) {
            hilog.error(DOMAIN, TAG, 'WebHttpError: %{public}s, status: %{public}d',
              event.request.getRequestUrl(), event.response.getResponseCode());
          }
        })
        .onPageEnd(() => {
          // 网页加载完成：脚本已执行、__suenAudioControl 已注册。
          // 桌面卡片积压的控制指令从这里开始放行。
          markWebPageReady();
          // 注入安全区高度与平台全局标记
          const topPx = px2vp(this.topAvoidHeight);
          const bottomPx = px2vp(this.bottomAvoidHeight);
          const injectScript = `
            document.documentElement.style.setProperty('--safe-top', '${topPx}px');
            document.documentElement.style.setProperty('--safe-bottom', '${bottomPx}px');
            window.__HARMONY_NEXT__ = true;
          `;
          try {
            this.webviewController.runJavaScript(injectScript);
          } catch (e) {
            hilog.error(DOMAIN, TAG, 'Failed to inject CSS safe area: %{public}s', JSON.stringify(e));
          }
        })
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8FAFC')
  }
}
