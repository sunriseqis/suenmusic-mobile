/**
 * 桌面卡片 —— v4（2026-10-12 第三轮反馈）：
 * 「按 alive 分流的混合通道」+「方卡沉浸 / 宽卡封面块」+「歌词面整套切换」。
 *
 * ── 通道（为什么这么绕）──────────────────────────────────────────
 * 卡片按钮要在「应用活着时不惊动前台」和「应用死了也能冷启动」之间两全：
 *   alive=true  → postCardAction **call**：后台直达 WebView，不拉前台；
 *   alive=false → postCardAction **router**：用户点击豁免通道，完整拉起。
 * alive 由应用推卡时告知（每次必置 true，onDestroy 置 false）；进程被系统
 * 杀掉留下陈旧 true 时，call 冷启动路径会纠正它（EntryAbility.healStaleAliveFlag），
 * 用户第二次点击即走 router —— 第一次点击被丢弃是已知代价。
 *
 * ── 布局 ────────────────────────────────────────────────────────
 * 正面（两规格不同）：
 *   2*2 方卡 = 封面全铺沉浸 + 底部毛玻璃面板（backdropBlur）承载
 *              标题/歌手/控制排 —— 封面大幅完整、文字落在磨砂上可读；
 *              **不支持翻转**（尺寸不够完整显示歌词，用户拍板砍掉），
 *              点击卡片非按钮区 = 打开应用；
 *   2*4 宽卡 = 左封面块（36%）+ 右标题/歌手 + 控制排，主题底色，
 *              **正面不显示歌词**（歌词只属于翻转页）。
 * 翻转页（仅 2*4）：
 *   整套切换成「封面模糊沉浸」的**纯歌词页**（参考官方播放器歌词页）：
 *   封面全铺加 blur + 深色渐变，标题/歌手居中在上、歌词窗口 6 行
 *   居中铺满（当前行高亮）、**无控制排** —— 控制排会挡住下方歌词行
 *   （上版实测被用户投诉）。再点一次翻回正面。
 *
 * ── 两个实测踩过的坑（改版别丢）─────────────────────────────────
 * ① 卡片页（form application）的 API 面被编译器严格限制：只有 d.ts 里
 *   带 `@form` 标签的声明可用（约 36 个；blur / backdropBlur /
 *   linearGradient / shadow / animateTo 都在）。
 * ② @Builder 按值传参的 UI **不随状态刷新**（ArkUI 文档明示）——上一版
 *   把播放/红心图标当参数传进 ctrlBtn，首次构建后被固化 → 播放键永远
 *   显示 play。现在按钮的图标/颜色/尺寸全部在 builder 体内经
 *   this.xxx（@LocalStorageProp）计算。
 */
/**
 * 卡片数据入口（官方模板写法）：给 @Entry 传一个 LocalStorage 实例，
 * 卡片渲染服务把提供方推来的 createFormBindingData 数据写进它，
 * 页面再用 @LocalStorageProp 同名 key 接收。
 */
let cardStorage = new LocalStorage();

@Entry(cardStorage)
@Component
struct SuenFormCard {
  /**
   * 数据靠 LocalStorage 绑定进来，而不是在代码里"拉"。
   *
   * ⚠️ 官方文档明确：卡片接收数据时一律被转成 **string**。所以 playing /
   * favorite / alive 收到的是 'true' / 'false' 字符串，必须按 string 比较。
   *
   * key 与 NowPlaying.ets 的 CardPayload 一字不差。
   */
  @LocalStorageProp('suen_title') title: string = '还没在听';
  @LocalStorageProp('suen_artist') artist: string = '打开 SuenMusic 放首歌';
  /** 'memory://suen_cover_img'（有封面）或 ''（占位块） */
  @LocalStorageProp('suen_cover') coverUrl: string = '';
  @LocalStorageProp('suen_playing') playing: string = 'false';
  @LocalStorageProp('suen_favorite') favorite: string = 'false';
  /** 歌词窗口文本（'\n' 分行，当前行 ± 若干行） */
  @LocalStorageProp('suen_lyric') lyric: string = '';
  /** 当前行在窗口内的下标（'-1' = 无可高亮行） */
  @LocalStorageProp('suen_lyric_active') lyricActive: string = '-1';
  /** 应用进程是否活着：'true' → call 后台直达；'false' → router 冷启动 */
  @LocalStorageProp('suen_alive') alive: string = 'false';
  /** 卡片规格：'3'=2*4 宽卡，其余（'2'）=2*2 紧凑卡 */
  @LocalStorageProp('suen_dimension') dimension: string = '2';
  /** 卡片管理服务自动注入的本卡片 id */
  @LocalStorageProp('formId') formId: string = '';

  /** 翻转动画的当前角度（0 = 正面，动画途中到 90） */
  @State flipAngle: number = 0;
  /** 是否显示歌词面（整套布局切换） */
  @State showBack: boolean = false;

  // ---- 规格与状态 ----

  private isWide(): boolean {
    return this.dimension === '3';
  }

  private hasCover(): boolean {
    return this.coverUrl.length > 0;
  }

  private isPlaying(): boolean {
    return this.playing === 'true';
  }

  /**
   * 按钮与文字是否落在暗色遮罩上（决定用深色令牌还是主题令牌）：
   * 歌词面（封面模糊全铺 + 渐变）与 2*2 正面（封面全铺 + 毛玻璃面板）
   * 的承载面是暗的；2*4 正面控制排落在主题底色上。
   * 无封面时一律主题令牌（card_well 底色本身可读）。
   */
  private onDarkOverlay(): boolean {
    if (!this.hasCover()) {
      return false;
    }
    return this.showBack || !this.isWide();
  }

  // ---- 歌词窗口取数 ----

  private lyricWindowLines(): string[] {
    if (this.lyric.length === 0) {
      return [];
    }
    return this.lyric.split('\n');
  }

  private activeIndexInt(): number {
    const idx = parseInt(this.lyricActive);
    if (isNaN(idx)) {
      return -1;
    }
    return idx;
  }

  // ---- 调色板（onDarkOverlay ? 深色固定令牌 : 主题资源令牌） ----

  private textStrong(): ResourceColor {
    return this.onDarkOverlay() ? '#FFFFFF' : $r('app.color.card_t1');
  }

  private textDim(): ResourceColor {
    return this.onDarkOverlay() ? '#B8FFFFFF' : $r('app.color.card_t2');
  }

  private lyricActiveColor(): ResourceColor {
    return this.onDarkOverlay() ? '#FF8B4A' : $r('app.color.card_accent_text');
  }

  private lyricInactiveColor(): ResourceColor {
    return this.onDarkOverlay() ? '#8CFFFFFF' : $r('app.color.card_t2');
  }

  // ---- 控制按钮取值（在 @Builder 体内调用，保证状态变化能刷新 UI） ----

  private btnSize(btn: string): number {
    if (btn === 'toggle') {
      return this.isWide() ? 40 : 32;
    }
    return this.isWide() ? 28 : 24;
  }

  private btnIconSize(btn: string): number {
    if (btn === 'toggle') {
      return this.isWide() ? 20 : 16;
    }
    return this.isWide() ? 14 : 12;
  }

  private btnIcon(btn: string): Resource {
    if (btn === 'prev') {
      return $r('app.media.card_prev');
    }
    if (btn === 'next') {
      return $r('app.media.card_next');
    }
    if (btn === 'favorite') {
      return this.favorite === 'true'
        ? $r('app.media.card_heart_filled') : $r('app.media.card_heart');
    }
    return this.isPlaying() ? $r('app.media.card_pause') : $r('app.media.card_play');
  }

  private btnColor(btn: string): ResourceColor {
    const dark = this.onDarkOverlay();
    if (btn === 'toggle') {
      return dark ? '#2B1A0E' : $r('app.color.card_accent_on');
    }
    if (btn === 'favorite') {
      if (this.favorite === 'true') {
        return dark ? '#FF8B4A' : $r('app.color.card_accent_text');
      }
      return dark ? '#8CE9EDF4' : $r('app.color.card_t2');
    }
    return dark ? '#E9EDF4' : $r('app.color.card_t1');
  }

  private btnBgColor(btn: string): ResourceColor {
    const dark = this.onDarkOverlay();
    if (btn === 'toggle') {
      return dark ? '#FF8B4A' : $r('app.color.card_accent');
    }
    return dark ? '#2B313C' : $r('app.color.card_bg');
  }

  private shadowDarkColor(): ResourceColor {
    return this.onDarkOverlay() ? '#9E000000' : $r('app.color.card_sd');
  }

  private shadowLightColor(): ResourceColor {
    return this.onDarkOverlay() ? '#12FFFFFF' : $r('app.color.card_sl');
  }

  // ---- 交互 ----

  /**
   * 控制按钮 → 应用，按 alive 分流：
   *
   * alive（应用活着）→ **call**：后台直达 EntryAbility callee → Hub →
   *   WebView，全程不惊动前台 —— 后台播放控制的主路。
   * 死了 → **router**：用户点击卡片的豁免通道，冷启动也把应用完整拉起
   *   （onCreate → onWindowStageCreate → 页面加载），指令经
   *   want.parameters['control'] 交 Hub，网页没就绪先排队。
   *
   * 播放键发 'toggle' 而不是 play/pause：进程被杀后快照可能残留
   * 播放态，toggle 在"以为在播其实没播"和"确实在播"两种情况下都正确。
   */
  private sendControl(control: string): void {
    if (this.alive === 'true') {
      postCardAction(this, {
        action: 'call',
        abilityName: 'EntryAbility',
        params: {
          method: 'control',
          control: control,
          formId: this.formId
        }
      });
    } else {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: {
          control: control,
          formId: this.formId
        }
      });
    }
  }

  /**
   * 2*2 方卡（不支持翻转）点击非按钮区：router 打开应用，不带控制指令。
   */
  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        formId: this.formId
      }
    });
  }

  /**
   * 翻转（仅 2*4）：两段式「半翻转」。先转到 90°（正侧面，内容不可见），
   * 在侧面瞬间整套切换正面/背面布局，再转回 0°。
   * animateTo / Curve 都在卡片 API 白名单内。
   */
  private toggleFlip(): void {
    if (this.flipAngle !== 0) {
      return; // 动画进行中不叠加
    }
    animateTo({
      duration: 180,
      curve: Curve.EaseIn,
      onFinish: () => {
        this.showBack = !this.showBack;
        animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
          this.flipAngle = 0;
        });
      }
    }, () => {
      this.flipAngle = 90;
    });
  }

  // ---- 布局：正面/翻转页整套切换；2*2 不翻转、点击直接打开应用 ----

  build() {
    Stack() {
      if (this.showBack) {
        this.lyricLayout()
      } else {
        if (this.isWide()) {
          this.wideFront()
        } else {
          this.squareFront()
        }
      }
    }
    .width('100%')
    .height('100%')
    .rotate({ y: 1, angle: this.flipAngle, centerX: '50%', centerY: '50%' })
    .onClick(() => {
      if (this.isWide()) {
        this.toggleFlip()
      } else {
        this.openApp()
      }
    })
  }

  /** 2*2 方卡正面：封面全铺沉浸 + 底部毛玻璃面板（标题/歌手/控制排） */
  @Builder
  squareFront() {
    Stack() {
      if (this.hasCover()) {
        Image(this.coverUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.card_well'))
      }

      Column() {
        // 上部弹性区：无封面时放音符占位
        Column() {
          if (!this.hasCover()) {
            Image($r('app.media.card_note'))
              .width(30)
              .height(30)
              .fillColor($r('app.color.card_t2'))
              .opacity(0.4)
          }
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)

        // 底部毛玻璃面板：backdropBlur 磨砂封面保证文字可读
        Column() {
          Text(this.title)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textStrong())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(this.artist)
            .fontSize(10)
            .fontColor(this.textDim())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 1 })

          this.controlsRow()
        }
        .width('100%')
        .backgroundColor(this.hasCover() ? 'rgba(12,16,24,0.38)' : 'rgba(0,0,0,0)')
        .backdropBlur(this.hasCover() ? 25 : 0)
        .borderRadius(14)
        .padding(10)
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  /** 2*4 宽卡正面：左封面块（36%），右上标题/歌手（不显示歌词），右下控制排 */
  @Builder
  wideFront() {
    Row({ space: 12 }) {
      Stack() {
        this.coverBlock()
      }
      .width('36%')
      .height('100%')

      Column() {
        Column() {
          Text(this.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textStrong())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(this.artist)
            .fontSize(11)
            .fontColor(this.textDim())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 2 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        this.controlsRow()
      }
      .layoutWeight(1)
      .height('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
    .height('100%')
    .padding(12)
  }

  /**
   * 翻转页（仅 2*4）：封面模糊沉浸的**纯歌词页**（参考官方播放器歌词页）。
   * 封面全铺加 blur + 深色渐变；标题/歌手居中在上，歌词窗口 6 行居中
   * 铺满（当前行高亮）；**不放控制排** —— 它会压住下方歌词行
   * （上版实测：底部 2 行被挡）。再点一次翻回正面。
   */
  @Builder
  lyricLayout() {
    Stack() {
      if (this.hasCover()) {
        Image(this.coverUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(12)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.card_well'))
      }

      if (this.hasCover()) {
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [['rgba(8,12,18,0.25)', 0], ['rgba(8,12,18,0.85)', 1]]
          })
      }

      Column() {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.textStrong())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)

        Text(this.artist)
          .fontSize(11)
          .fontColor(this.textDim())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 1 })

        Column() {
          ForEach(this.lyricWindowLines(), (line: string, idx: number) => {
            Text(line)
              // 当前行放大 + 加粗 + 高亮，视觉焦点随播放滚动
              .fontSize(idx === this.activeIndexInt() ? 14 : 11)
              .fontWeight(idx === this.activeIndexInt() ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(idx === this.activeIndexInt()
                ? this.lyricActiveColor() : this.lyricInactiveColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: idx === 0 ? 0 : 4 })
          }, (line: string, idx: number) => `${idx}_${line}`)

          if (this.lyricWindowLines().length === 0) {
            Text('暂无歌词')
              .fontSize(11)
              .fontColor(this.textDim())
          }
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 6 })
      }
      .width('100%')
      .height('100%')
      .padding(14)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
  }

  /** 封面块（formImages → Image('memory://…')）；无封面画占位底 */
  @Builder
  coverBlock() {
    if (this.hasCover()) {
      Image(this.coverUrl)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .borderRadius(12)
    } else {
      Column() {
        Image($r('app.media.card_note'))
          .width(this.isWide() ? 36 : 30)
          .height(this.isWide() ? 36 : 30)
          .fillColor($r('app.color.card_t2'))
          .opacity(0.4)
      }
      .width('100%')
      .height('100%')
      .borderRadius(12)
      .backgroundColor($r('app.color.card_well'))
      .justifyContent(FlexAlign.Center)
    }
  }

  /** 控制排：prev / toggle / next / favorite */
  @Builder
  controlsRow() {
    Row({ space: this.isWide() ? 10 : 8 }) {
      this.ctrlBtn('prev')
      this.ctrlBtn('toggle')
      this.ctrlBtn('next')
      this.ctrlBtn('favorite')
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .margin({ top: 8 })
  }

  /**
   * 软拟物控制按钮：两个同底色圆各投一道单向阴影（一暗一亮），
   * 合成 neu.css 的双向浮起阴影；图标 SVG 用 fillColor 着色。
   * 图标/颜色/尺寸在体内按状态计算——按值传参会被固化不刷新（实测踩坑）。
   */
  @Builder
  ctrlBtn(btn: string) {
    Stack() {
      Column()
        .width(this.btnSize(btn))
        .height(this.btnSize(btn))
        .borderRadius(this.btnSize(btn) / 2)
        .backgroundColor(this.btnBgColor(btn))
        .shadow({
          radius: this.btnSize(btn) * 0.3,
          offsetX: 2,
          offsetY: 2,
          color: this.shadowDarkColor()
        })
      Column()
        .width(this.btnSize(btn))
        .height(this.btnSize(btn))
        .borderRadius(this.btnSize(btn) / 2)
        .backgroundColor(this.btnBgColor(btn))
        .shadow({
          radius: this.btnSize(btn) * 0.3,
          offsetX: -2,
          offsetY: -2,
          color: this.shadowLightColor()
        })
      Image(this.btnIcon(btn))
        .width(this.btnIconSize(btn))
        .height(this.btnIconSize(btn))
        .fillColor(this.btnColor(btn))
    }
    .width(this.btnSize(btn))
    .height(this.btnSize(btn))
    .onClick(() => this.sendControl(btn))
  }
}
