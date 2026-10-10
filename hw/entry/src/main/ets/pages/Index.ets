import { webview } from '@kit.ArkWeb';
import { bundleManager } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'SuenMusic_IndexPage';
const DOMAIN = 0x0000;
const LOCAL_ORIGIN = 'http://localhost';

class HarmonyBridge {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
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
}

@Entry
@Component
struct Index {
  private webviewController: webview.WebviewController = new webview.WebviewController();
  @StorageProp('topAvoidHeight') topAvoidHeight: number = 0;
  @StorageProp('bottomAvoidHeight') bottomAvoidHeight: number = 0;
  private bridge: HarmonyBridge = new HarmonyBridge(getContext(this) as common.UIAbilityContext);

  aboutToAppear(): void {
    try {
      // 开启 ArkWeb 调试模式（支持通过 Chrome DevTools inspect 调试）
      webview.WebviewController.setWebDebuggingAccess(true);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Failed to set web debugging: %{public}s', JSON.stringify(err));
    }
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
          methodList: ['getAppVersion', 'openInBrowser', 'isNativePlatform', 'getPlatform'],
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
