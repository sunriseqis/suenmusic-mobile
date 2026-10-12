import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { rpc } from '@kit.IPCKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { formBindingData, formProvider, formInfo } from '@kit.FormKit';
import { dispatchCardControl, isWebPageReady, CardControlRequest } from '../common/PlayerControlHub';
import {
  NowPlayingSnapshot,
  readSnapshotSync,
  writeSnapshotSync,
  buildFormBindingObject,
  openCoverFd,
  closeCoverFd
} from '../common/NowPlaying';

const TAG = 'SuenMusic_EntryAbility';
const DOMAIN = 0x0000;

/**
 * callee 回调必须返回至少一个空的 Parcelable（SDK 注释原话：Otherwise,
 * the function execution fails）—— postCardAction 的 call 事件同样受这条
 * 约束。这里回一个最小实现，内容不携带信息。
 */
class CardControlResult implements rpc.Parcelable {
  marshalling(sequence: rpc.MessageSequence): boolean {
    sequence.writeInt(0);
    return true;
  }

  unmarshalling(sequence: rpc.MessageSequence): boolean {
    return true;
  }
}

export default class EntryAbility extends UIAbility {
  /**
   * 进程是否处于「刚冷启动、WebView 必然还没加载」的阶段。
   * onCreate 置 true、onWindowStageCreate 置 false。
   * call 冷启动（卡片 alive 标志陈旧时会发生）借此识别出
   * 「这条 call 指令在无窗口的死路上」，转去纠正 alive 标志。
   */
  private justColdStarted: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    this.justColdStarted = true;
    this.registerCardCallee();
    // router 事件（或未来的其他前台拉起）可以带 control 参数进来
    this.dispatchControlFromWant(want);
  }

  /**
   * 桌面卡片按钮的后台落点：postCardAction 的 call 事件（method='control'）。
   *
   * 卡片按 suen_alive 分流：应用活着走 call（后台直达、不惊动前台），
   * 死了走 router（冷启动完整拉起）。call 冷启动 = 卡片的 alive 标志
   * 陈旧（进程被系统杀过、onDestroy 没回调）—— 这条路是无窗口的死路：
   * call 只走 onCreate → onBackground，WebView 永远不加载（生命周期文档），
   * 自拉前台已被实测否决（startAbility code=201，
   * START_ABILITIES_FROM_BACKGROUND 仅系统应用，call 链起自用户点击也不豁免）。
   *
   * 所以此时：丢弃这条指令（不排队 —— 排了它会和用户下一次 router 点击
   * 的指令叠加成两次 toggle 相互抵消），并把 alive 纠正为 false 推回卡片，
   * 用户第二次点击自然走 router 冷启动。
   */
  private registerCardCallee(): void {
    try {
      this.callee.on('control', (data: rpc.MessageSequence) => {
        try {
          const raw = data.readString();
          hilog.info(DOMAIN, TAG, '收到卡片 call 事件：%{public}s', raw);
          if (!isWebPageReady() && this.justColdStarted) {
            this.healStaleAliveFlag();
            return new CardControlResult();
          }
          const req = JSON.parse(raw) as CardControlRequest;
          if (req.control && req.control.length > 0) {
            dispatchCardControl(req.control);
          }
        } catch (err) {
          hilog.error(DOMAIN, TAG, '卡片指令解析失败：%{public}s', JSON.stringify(err));
        }
        return new CardControlResult();
      });
      hilog.info(DOMAIN, TAG, '卡片 callee(control) 注册成功');
    } catch (err) {
      hilog.error(DOMAIN, TAG, '卡片 callee 注册失败：%{public}s',
        JSON.stringify(err as BusinessError));
    }
  }

  /**
   * call 冷启动撞上陈旧 alive 标志：纠正为 false 落盘 + 推回卡片。
   * 全同步写（writeSnapshotSync），updateForm 发出去就不管。
   */
  private healStaleAliveFlag(): void {
    try {
      const snap: NowPlayingSnapshot = readSnapshotSync(this.context);
      if (!snap.alive) {
        return;
      }
      snap.alive = false;
      snap.updatedAt = new Date().getTime();
      writeSnapshotSync(this.context, snap);
      hilog.warn(DOMAIN, TAG,
        'call 冷启动：alive 标志陈旧（进程被系统杀过），已纠 false 推回卡片，下次点击走 router 冷启动');
      this.pushSnapshotToCards(snap);
    } catch (err) {
      hilog.error(DOMAIN, TAG, '纠正 alive 标志失败：%{public}s', JSON.stringify(err));
    }
  }

  /**
   * 把快照推给所有运行中的卡片（带封面 fd，避免 formImages 缺失丢封面）。
   * fd 在每张卡的 updateForm await 之后由 closeCoverFd 关闭是安全时序；
   * 这里为简化在整批复送完后统一关（IPC 序列化时 fd 已被系统复制）。
   */
  private pushSnapshotToCards(snap: NowPlayingSnapshot): void {
    // 与 Index.syncCard / SuenFormAbility 一致：只有快照声明封面就绪才开 fd，
    // 否则 payload 说无封面却塞旧 formImages，既浪费也存在新旧不一致的边角。
    const coverFd = snap.coverReady ? openCoverFd(this.context) : -1;
    formProvider.getPublishedRunningFormInfos()
      .then(async (infos: Array<formInfo.RunningFormInfo>) => {
        for (const info of infos) {
          const dimension = info.dimension === formInfo.FormDimension.Dimension_2_4 ? '3' : '2';
          const obj = buildFormBindingObject(snap, dimension, coverFd);
          try {
            await formProvider.updateForm(info.formId, formBindingData.createFormBindingData(obj));
          } catch (err) {
            hilog.error(DOMAIN, TAG, '刷卡片失败 formId=%{public}s：%{public}s',
              info.formId, JSON.stringify(err));
          }
        }
        closeCoverFd(coverFd);
      })
      .catch((err: BusinessError) => {
        closeCoverFd(coverFd);
        hilog.error(DOMAIN, TAG, '读取卡片列表失败：%{public}s', JSON.stringify(err));
      });
  }

  /** 从 want.parameters 里取 control 指令（router 前台拉起的参数通道） */
  private dispatchControlFromWant(want: Want): void {
    try {
      const params = want.parameters;
      if (!params) {
        return;
      }
      const control = params['control'];
      if (typeof control === 'string' && control.length > 0) {
        hilog.info(DOMAIN, TAG, 'want 参数携带控制指令：%{public}s', control);
        dispatchCardControl(control);
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, '解析 want 控制参数失败：%{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
    // 进程收尾：快照里的 playing / alive 状态已经不真实了（播放器已死）。
    // 不重置的话卡片会一直显示"播放中"的陈旧按钮态、按钮继续走 call 死路，
    // 直到下一次切歌/进应用。
    this.resetSnapshotOnDestroy();
  }

  /**
   * onDestroy 里的收尾：快照 playing=false + alive=false 落盘 + 主动刷一遍
   * 卡片。全部走同步 API（writeSnapshotSync）—— onDestroy 之后进程随时可能
   * 被收走，异步路径等于没写。
   */
  private resetSnapshotOnDestroy(): void {
    try {
      const snap: NowPlayingSnapshot = readSnapshotSync(this.context);
      if (!snap.playing && !snap.alive) {
        return;
      }
      snap.playing = false;
      snap.alive = false;
      snap.updatedAt = new Date().getTime();
      writeSnapshotSync(this.context, snap);
      this.pushSnapshotToCards(snap);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'onDestroy 重置快照失败：%{public}s', JSON.stringify(err));
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    this.justColdStarted = false;

    try {
      const mainWindow = windowStage.getMainWindowSync();

      // 设置沉浸式全屏布局
      mainWindow.setWindowLayoutFullScreen(true);

      // 获取顶部状态栏避让区与底部导航栏避让区高度 (px)
      const topAvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const bottomAvoidArea = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);

      AppStorage.setOrCreate('topAvoidHeight', topAvoidArea.topRect.height);
      AppStorage.setOrCreate('bottomAvoidHeight', bottomAvoidArea.bottomRect.height);

      // 监听窗口避让区域变化（如软键盘弹出或横竖屏旋转）
      mainWindow.on('avoidAreaChange', (data) => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
          AppStorage.setOrCreate('topAvoidHeight', data.area.topRect.height);
        } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          AppStorage.setOrCreate('bottomAvoidHeight', data.area.bottomRect.height);
        }
      });

      // 设置系统状态栏图标颜色风格
      mainWindow.setWindowSystemBarProperties({
        statusBarContentColor: '#1E293B',
        navigationBarContentColor: '#1E293B'
      });
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to configure window: %{public}s', JSON.stringify(err));
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onNewWant');
    this.dispatchControlFromWant(want);
  }
}
