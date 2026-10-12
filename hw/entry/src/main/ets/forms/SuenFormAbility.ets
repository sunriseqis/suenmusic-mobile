/**
 * 服务卡片的生命周期。
 *
 * ⚠️ 这个 Extension 跑在**独立进程**里，而且 SDK 在
 * `@ohos.app.form.FormExtensionAbility` 的文件头明确写着：以下模块
 * **禁止**在这里引用，引用会导致进程异常退出：
 *   - @ohos.multimedia.media / multimedia.audio
 *   - @ohos.resourceschedule.backgroundTaskManager
 * 也就是说卡片进程既碰不到 WebView（播放器在那儿），也碰不到 AVSession。
 * 所以它只负责两件事：把快照读出来、把快照推给卡片。
 *
 * 封面与主应用共享沙箱：主进程把封面字节写到 cacheDir/card_cover.img，
 * 这里开 fd 经 formImages 传给卡片（卡片 Image 加载不了网络 URL，
 * 'memory://key' + formImages 是官方唯一通路）。
 *
 * 卡片按钮的交互不走这里：按钮用 postCardAction 的 call 事件直达
 * EntryAbility 的 callee（见 common/PlayerControlHub.ets）。
 */
import { Want } from '@kit.AbilityKit';
import { FormExtensionAbility, formBindingData, formProvider, formInfo } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { readSnapshotSync, buildFormBindingObject } from '../common/NowPlaying';

const TAG = 'SuenMusic_Form';
const DOMAIN = 0x0000;

/** 与主进程约定同一份封面文件（同一沙箱） */
const CARD_COVER_PATH = '/card_cover.img';

export default class SuenFormAbility extends FormExtensionAbility {
  /** want 里取卡片规格（'2'=2*2，'3'=2*4），取不到按 2*2 兜底 */
  private dimensionFromWant(want: Want): string {
    try {
      const params = want.parameters;
      if (params) {
        const dim = params[formInfo.FormParam.DIMENSION_KEY];
        if (typeof dim === 'number' && dim === formInfo.FormDimension.Dimension_2_4) {
          return '3';
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'dimensionFromWant 失败: %{public}s', JSON.stringify(err));
    }
    return '2';
  }

  /** 打开封面 fd（-1 = 无封面文件，按占位块降级） */
  private openCoverFd(): number {
    try {
      const file = fileIo.openSync(this.context.cacheDir + CARD_COVER_PATH, fileIo.OpenMode.READ_ONLY);
      return file.fd;
    } catch (err) {
      return -1;
    }
  }

  /**
   * 用户把卡片添加到桌面。
   *
   * ⚠️ onAddForm 必须同步返回，且返回值随后才参与 IPC 序列化 ——
   * fd 在序列化完成前不能关（关了卡片拿到的是失效 fd）。
   * 泄漏的这一个 fd 随 Extension 进程（空闲 10 秒即回收）一起释放。
   */
  onAddForm(want: Want): formBindingData.FormBindingData {
    const dimension = this.dimensionFromWant(want);
    const snap = readSnapshotSync(this.context);
    const coverFd = snap.coverReady ? this.openCoverFd() : -1;
    hilog.info(DOMAIN, TAG, '卡片被添加，规格=%{public}s，封面 fd=%{public}d', dimension, coverFd);
    return formBindingData.createFormBindingData(
      buildFormBindingObject(snap, dimension, coverFd));
  }

  /**
   * 系统定时刷新（updateDuration 到点）或 App 主动 updateForm 之外的兜底。
   * 走到这里时把快照 + 封面 fd 一并补推；fd 在 await 之后关闭是安全的
   * （IPC 过程中系统已复制 fd）。
   */
  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    // 规格要从运行中的卡片信息里查（想拿全必须异步），查到后再推
    formProvider
      .getPublishedRunningFormInfos()
      .then((infos: Array<formInfo.RunningFormInfo>) => {
        let dimension = '2';
        for (const info of infos) {
          if (info.formId === formId) {
            dimension = info.dimension === formInfo.FormDimension.Dimension_2_4 ? '3' : '2';
            break;
          }
        }
        const snap = readSnapshotSync(this.context);
        const coverFd = snap.coverReady ? this.openCoverFd() : -1;
        return formProvider.updateForm(
          formId,
          formBindingData.createFormBindingData(
            buildFormBindingObject(snap, dimension, coverFd))
        ).then(() => {
          if (coverFd >= 0) {
            try {
              fileIo.closeSync(coverFd);
            } catch (err) {
              // ignore
            }
          }
        });
      })
      .catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'updateForm 失败: %{public}s', JSON.stringify(err));
      });
  }

  /**
   * 卡片上的 message 事件（postCardAction action='message'）。
   * 控制按钮走 call 事件（EntryAbility callee），不经过这里。
   */
  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN, TAG, '收到卡片事件 formId=%{public}s message=%{public}s', formId, message);
  }

  /** 用户把卡片从桌面移除 */
  onRemoveForm(formId: string): void {
    hilog.info(DOMAIN, TAG, '卡片被移除 formId=%{public}s', formId);
  }
}
