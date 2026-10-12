/**
 * 桌面卡片：显示"正在听什么"。
 *
 * ⚠️ 卡片页（form application）的 API 面被编译器严格限制：JSDoc 里没有
 * `@form` 标签的声明一律报 11706006 "can't support form application"。
 * **已实测不可用**：`this.getUIContext()`、`hilog`、`router` / `router.getParams()`。
 * 判定逻辑在 ets-loader/lib/fast_build/system_api/api_check_define.js；
 * 全 SDK 带 `@form` 的声明只有 36 个（postCardAction / vp2px / animateTo 等）。
 */
import { NowPlayingSnapshot } from '../common/NowPlaying';

@Entry
@Component
struct SuenFormCard {
  /**
   * 数据靠 LocalStorage 绑定进来，而不是在代码里"拉"。
   *
   * 卡片页不能用 AppStorage / router / getUIContext（编译器报 11706006），
   * 但 `@LocalStorageProp` 在白名单里 —— 配合 form_config 的数据代理声明，
   * 由系统把 createFormBindingData 的数据注入同名 key。
   */
  @LocalStorageProp('suen_title') title: string = '还没在听';
  @LocalStorageProp('suen_artist') artist: string = '打开 SuenMusic 放首歌';
  @LocalStorageProp('suen_cover') coverUrl: string = '';
  @LocalStorageProp('suen_playing') playing: boolean = false;

  build() {
    Column() {
      Row() {
        if (this.coverUrl.length > 0) {
          Image(this.coverUrl)
            .width(64)
            .height(64)
            .borderRadius(10)
            .objectFit(ImageFit.Cover)
        } else {
          Column() {
            Text('♪').fontSize(26).fontColor('#94A3B8')
          }
          .width(64)
          .height(64)
          .borderRadius(10)
          .backgroundColor('#E2E8F0')
          .justifyContent(FlexAlign.Center)
        }

        Column() {
          Text(this.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1E293B')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(this.artist)
            .fontSize(13)
            .fontColor('#64748B')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 4 })

          Text(this.playing ? '播放中' : '已暂停')
            .fontSize(11)
            .fontColor(this.playing ? '#E0783C' : '#94A3B8')
            .margin({ top: 6 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#FFFFFF')
    .borderRadius(16)
  }
}
