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
 */
import { Want } from '@kit.AbilityKit';
import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { readSnapshotSync, toCardPayload, CardPayload } from '../common/NowPlaying';

const TAG = 'SuenMusic_Form';
const DOMAIN = 0x0000;

export default class SuenFormAbility extends FormExtensionAbility {
  /** 读快照并整形成卡片要的扁平结构（转换规则与 App 侧共用同一个函数）。 */
  private buildPayload(): CardPayload {
    return toCardPayload(readSnapshotSync(this.context));
  }

  /** 用户把卡片添加到桌面 */
  onAddForm(want: Want): formBindingData.FormBindingData {
    hilog.info(DOMAIN, TAG, '卡片被添加');
    return formBindingData.createFormBindingData(this.buildPayload());
  }

  /** 系统定时刷新（updateDuration 到点）或 App 主动 updateForm */
  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    formProvider
      .updateForm(formId, formBindingData.createFormBindingData(this.buildPayload()))
      .catch((err: Error) => {
        hilog.error(DOMAIN, TAG, 'updateForm 失败: %{public}s', JSON.stringify(err));
      });
  }

  /**
   * 卡片上的点击事件。
   *
   * 这里**到不了播放器**：播放器是 App 进程 WebView 里的 HTMLAudioElement，
   * 这个独立进程拿不到 webviewController。所以这条回调目前只留日志，
   * 等确认了事件通路再接。
   */
  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN, TAG, '收到卡片事件 formId=%{public}s message=%{public}s', formId, message);
  }

  /** 用户把卡片从桌面移除 */
  onRemoveForm(formId: string): void {
    hilog.info(DOMAIN, TAG, '卡片被移除 formId=%{public}s', formId);
  }
}
