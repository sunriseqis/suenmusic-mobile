/**
 * 卡片控制指令的分发中枢。
 *
 * 桌面卡片的按钮通过 postCardAction 的 call 事件 → EntryAbility 的 callee
 * 到达这里，这里再把指令翻译成 runJavaScript 调进 WebView 里的网页播放器
 * （window.__suenAudioControl，见 web 侧 stores/player.ts 的
 * registerGlobalAudioControl）。
 *
 * 为什么需要一个"Hub"而不是 EntryAbility 直接持引用：webviewController 的
 * 真正持有者是 pages/Index（@Entry 组件），UIAbility 拿不到组件实例。模块级
 * 单例是 ArkTS 里跨这两层最朴素的通道（不能把 controller 塞进 AppStorage：
 * 它不是可序列化状态，也没有观察方需要它）。
 *
 * 进程被杀后的链路：call 事件会把 UIAbility **后台拉起** → onCreate 注册
 * callee（指令此刻可能已到达，先入队）→ windowStage 加载 Index →
 * aboutToAppear 挂上 controller → 网页 onPageEnd → markWebPageReady()
 * 把队列里积压的指令按序执行。
 */
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'SuenMusic_CardControl';
const DOMAIN = 0x0000;

/** pending 队列上限。连点保护：排队的指令超过这个数就丢最旧的 */
const MAX_PENDING = 8;

/** 卡片 call 事件送来的参数形状（postCardAction params，经 JSON 序列化） */
export interface CardControlRequest {
  method?: string;
  control?: string;
  formId?: string;
}

/** 支持的控制指令。与卡片按钮、web 侧 __suenAudioControl 一一对应 */
const VALID_CONTROLS: string[] = ['play', 'pause', 'toggle', 'next', 'prev', 'favorite'];

let controllerRef: webview.WebviewController | null = null;
let pageReady = false;
const pendingControls: string[] = [];

/** Index.aboutToAppear 调用：把真正的 webviewController 挂进来 */
export function attachWebviewController(controller: webview.WebviewController): void {
  controllerRef = controller;
  hilog.info(DOMAIN, TAG, 'webviewController 已挂接');
}

/**
 * Index 的 Web.onPageEnd 调用：网页加载完成（脚本已执行，
 * __suenAudioControl 已注册）。积压指令在此刻统一放行。
 */
export function markWebPageReady(): void {
  if (pageReady) return;
  pageReady = true;
  hilog.info(DOMAIN, TAG, '网页就绪，开始放行积压指令：%{public}d 条', pendingControls.length);
  while (pendingControls.length > 0) {
    const control = pendingControls.shift();
    if (control) {
      runControl(control);
    }
  }
}

/**
 * 收到一条控制指令（EntryAbility callee 转发而来）。
 *
 * 网页没就绪就排队；就绪了就直接执行。指令本身是幂等的（play 在播放中
 * 是空操作），排队重放不会造成状态错乱。
 */
export function dispatchCardControl(control: string): void {
  if (VALID_CONTROLS.indexOf(control) < 0) {
    hilog.warn(DOMAIN, TAG, '忽略未知控制指令：%{public}s', control);
    return;
  }
  hilog.info(DOMAIN, TAG, '收到控制指令：%{public}s（网页就绪=%{public}s）',
    control, pageReady ? 'yes' : 'no');
  if (!pageReady) {
    if (pendingControls.length >= MAX_PENDING) {
      pendingControls.shift();
    }
    pendingControls.push(control);
    return;
  }
  runControl(control);
}

function runControl(control: string): void {
  const controller = controllerRef;
  if (!controller) {
    hilog.warn(DOMAIN, TAG, 'webviewController 未挂接，指令丢弃：%{public}s', control);
    return;
  }
  // 卡片上的 'favorite' 对应 web 侧的 toggleFavorite()
  const method = control === 'favorite' ? 'toggleFavorite' : control;
  const script = `if (window.__suenAudioControl) { window.__suenAudioControl.${method}(); }`;
  try {
    controller.runJavaScript(script);
  } catch (err) {
    hilog.error(DOMAIN, TAG, 'runJavaScript 失败（%{public}s）：%{public}s', control, JSON.stringify(err));
  }
}

/**
 * 网页是否已就绪（EntryAbility 冷启动自检用）。
 *
 * call 事件把 UIAbility 后台拉起时**不执行 onWindowStageCreate**（官方
 * UIAbility 生命周期文档），Index/WebView 根本没加载 —— pending 队列
 * 也就永远不会放行。调用方据此判断要不要把自己拉到前台。
 */
export function isWebPageReady(): boolean {
  return pageReady;
}
