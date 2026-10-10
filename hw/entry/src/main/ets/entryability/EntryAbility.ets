import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const TAG = 'SuenMusic_EntryAbility';
const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');

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
}
