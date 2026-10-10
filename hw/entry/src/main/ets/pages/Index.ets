import { webview } from '@kit.ArkWeb';
import { bundleManager, common, Want, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { avSession } from '@kit.AVSessionKit';
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';

const TAG = 'SuenMusic_IndexPage';
const DOMAIN = 0x0000;
const LOCAL_ORIGIN = 'http://localhost';

class HarmonyAVSessionManager {
  private session: avSession.AVSession | null = null;
  private context: common.UIAbilityContext;
  private webviewController: webview.WebviewController;
  private currentPixelMap: image.PixelMap | null = null;
  private currentCoverUrl: string = '';
  private currentMetadata: avSession.AVMetadata | null = null;
  private isContinuousTaskRunning: boolean = false;
  private stopTaskTimer: number = -1;

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
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to create AVSession: %{public}s', JSON.stringify(err));
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

  async updateMetadata(meta: {
    assetId?: string;
    title?: string;
    artist?: string;
    album?: string;
    coverUrl?: string;
    durationMs?: number;
    lyric?: string;
  }): Promise<void> {
    if (!this.session) return;

    let pixelMap: image.PixelMap | undefined = undefined;
    const cover = meta.coverUrl ? meta.coverUrl.trim() : '';

    if (cover && (cover.startsWith('http://') || cover.startsWith('https://'))) {
      if (cover === this.currentCoverUrl && this.currentPixelMap) {
        pixelMap = this.currentPixelMap;
      } else {
        pixelMap = await this.downloadCoverPixelMap(cover);
        if (pixelMap) {
          if (this.currentPixelMap && this.currentPixelMap !== pixelMap) {
            try {
              await this.currentPixelMap.release();
            } catch (e) {
              // ignore
            }
          }
          this.currentPixelMap = pixelMap;
          this.currentCoverUrl = cover;
        }
      }
    }

    let lyricStr = meta.lyric;
    if (lyricStr === undefined && this.currentMetadata && this.currentMetadata.assetId === meta.assetId) {
      lyricStr = this.currentMetadata.lyric;
    }

    const metadata: avSession.AVMetadata = {
      assetId: meta.assetId || 'suen_' + Date.now(),
      title: meta.title || '未知曲目',
      artist: meta.artist || '未知歌手',
      album: meta.album || 'SuenMusic',
      duration: meta.durationMs || 0,
      mediaImage: pixelMap || this.currentPixelMap || undefined,
      lyric: lyricStr || undefined
    };

    this.currentMetadata = metadata;

    try {
      await this.session.setAVMetadata(metadata);
      hilog.info(DOMAIN, TAG, 'setAVMetadata success: title=%{public}s, hasCover=%{public}s, hasLyric=%{public}s',
        metadata.title || '', (pixelMap || this.currentPixelMap) ? 'true' : 'false', metadata.lyric ? 'true' : 'false');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setAVMetadata failed: %{public}s', JSON.stringify(err));
    }
  }

  async updateLyric(assetId: string, lyricLrc: string): Promise<void> {
    if (!this.session) return;

    if (!this.currentMetadata) {
      this.currentMetadata = {
        assetId: assetId || 'suen_current',
        title: '未知曲目',
        lyric: lyricLrc
      };
    } else {
      if (!assetId || this.currentMetadata.assetId === assetId || this.currentMetadata.assetId.startsWith('suen_')) {
        this.currentMetadata.lyric = lyricLrc;
      } else {
        return;
      }
    }

    try {
      await this.session.setAVMetadata(this.currentMetadata);
      hilog.info(DOMAIN, TAG, 'AVSession lyric updated for %{public}s, len=%{public}d',
        this.currentMetadata.title || '', lyricLrc ? lyricLrc.length : 0);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to update AVSession lyric: %{public}s', JSON.stringify(err));
    }
  }

  private async getContinuousTaskWantAgent(): Promise<wantAgent.WantAgent> {
    const bundleName = this.context.abilityInfo?.bundleName || 'com.suenmusic.app';
    const abilityName = this.context.abilityInfo?.name || 'EntryAbility';
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: bundleName,
          abilityName: abilityName
        }
      ],
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
      const playbackState: avSession.AVPlaybackState = {
        state: state,
        position: {
          elapsedTime: elapsed,
          updateTime: new Date().getTime()
        },
        duration: durationMs || 0
      };

      await this.session.setAVPlaybackState(playbackState);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'setAVPlaybackState failed: %{public}s', JSON.stringify(err));
    }
  }

  private async downloadCoverPixelMap(url: string): Promise<image.PixelMap | undefined> {
    try {
      const httpRequest = http.createHttp();
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 5000,
        header: {
          'Referer': ''
        }
      });

      if (response.responseCode === 200 && response.result instanceof ArrayBuffer) {
        const imageSource = image.createImageSource(response.result);
        const decodingOptions: image.DecodingOptions = {
          desiredSize: { width: 512, height: 512 }
        };
        const pixelMap = await imageSource.createPixelMap(decodingOptions);
        await imageSource.release();
        httpRequest.destroy();
        return pixelMap;
      }
      httpRequest.destroy();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to downloadCoverPixelMap from %{public}s: %{public}s', url, JSON.stringify(err));
    }
    return undefined;
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

  updateMediaMetadata(metaJson: string): void {
    try {
      const data: Record<string, string | number> = JSON.parse(metaJson);
      this.avSessionManager.updateMetadata({
        assetId: String(data.assetId || ''),
        title: String(data.title || ''),
        artist: String(data.artist || ''),
        album: String(data.album || ''),
        coverUrl: String(data.coverUrl || ''),
        durationMs: Number(data.durationMs || 0)
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'updateMediaMetadata parse failed: %{public}s', JSON.stringify(err));
    }
  }

  updatePlaybackState(stateJson: string): void {
    try {
      const data: Record<string, string | number> = JSON.parse(stateJson);
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
      const data: Record<string, string> = JSON.parse(lyricJson);
      this.avSessionManager.updateLyric(String(data.assetId || ''), String(data.lyric || ''));
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'updateLyric parse failed: %{public}s', JSON.stringify(err));
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
            'updateLyric'
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
