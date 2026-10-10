# hw/ —— HarmonyOS NEXT (鸿蒙纯血) 原生客户端工程

本目录是 **SuenMusic 鸿蒙 NEXT 客户端原生工程**（基于 HarmonyOS NEXT / OpenHarmony API 11/12+ Stage 模型，ArkTS / ArkUI 体系构建）。

## 这里放什么

DevEco Studio 维护的鸿蒙原生工程。构建与运行流水线：

```
suenmusic-server/web/（Vue 源码） → vite build → web/dist/ → npm run hw:sync → hw/.../rawfile/ → DevEco Studio / Hvigor → HAP
```

## 工程结构与关键文件

```
hw/
├── build-profile.json5         # 工程级构建配置（API 11/12 Stage 模型，compileSdkVersion: 26.0.0）
├── hvigorfile.ts               # Hvigor 构建系统入口
├── oh-package.json5            # 工程级依赖清单 (modelVersion: 5.0.0)
├── README.md                   # 本说明文件
├── AppScope/                   # 全局元数据（包名、图标、全局配置）
│   ├── app.json5               # bundleName: com.suenmusic.app，版本注入节点
│   └── resources/              # 全局多语言与应用母版图标
└── entry/                      # 主入口模块 (HAP)
    ├── build-profile.json5     # 模块构建配置
    ├── hvigorfile.ts           # 模块构建脚本
    ├── oh-package.json5        # 模块依赖清单
    └── src/main/
        ├── module.json5        # 模块配置（EntryAbility、网络权限 INTERNET、后台音频权限 KEEP_BACKGROUND_RUNNING、backgroundModes: audioPlayback）
        ├── resources/          # 鸿蒙资源目录
        │   ├── base/element/   # 字符常量 string.json、启动色 color.json
        │   ├── base/media/     # 应用母版图标 app_icon.png
        │   ├── base/profile/   # 页面路由清单 main_pages.json
        │   └── rawfile/        # Web 编译产物存放目录（通过 npm run hw:sync 同步，已被 .gitignore 忽略）
        └── ets/                # ArkTS 源码
            ├── entryability/
            │   └── EntryAbility.ets  # 应用生命周期、沉浸式全屏布局、状态栏样式、安全区高度计算
            └── pages/
                └── Index.ets         # 主页面：ArkWeb 容器、虚拟域名本地拦截、SPA 路由回退、媒体无手势连播、JSBridge 桥接
```

## 移植核心攻坚与踩坑解决方案（对齐 suenmoney 经验）

1. **ArkWeb 离线加载白屏与 CORS 阻断解决**：
   - **痛点**：若使用 `src: $rawfile('index.html')`，页面运行在 `resource://rawfile/` 协议下，ArkWeb 内核对 `<script type="module">` 会执行严格的 CORS 阻断，且绝对路径 `/assets/xxx.js` 会解析到系统根目录导致 404 资源丢失。
   - **方案**：将入口设为虚拟域名 `http://localhost/index.html`（与 Capacitor 标准对齐），在 `Index.ets` 的 `onInterceptRequest` 中拦截 `http://localhost/` 请求，直接从 `rawfile` 读取流并封装标准 `WebResourceResponse`（带完整 MIME 类型），同时引入 SPA 路由回退（无后缀请求统一返回 `index.html`）。

2. **音频连播与手势阻断**：
   - 配置 `mediaPlayGestureAccess(false)`，允许切歌和播放列表轮转时由脚本自动连播音频，避免每次换歌都需要触发物理手势。
   - 在 `module.json5` 声明 `ohos.permission.KEEP_BACKGROUND_RUNNING` 与 `backgroundModes: ["audioPlayback"]`，保障后台播放能力。

3. **沉浸式与安全区自适应**：
   - `EntryAbility.ets` 监听系统状态栏避让区与底部手势导航条避让区高度；
   - `Index.ets` 在 `onPageEnd` 时动态向前端注入 `--safe-top` 和 `--safe-bottom` CSS 变量，确保贴合打孔屏、折叠屏与刘海屏。

4. **Hvigor 6.26+ 与 API 26 Schema 合规**：
   - 补齐 `AppScope/app.json5` 避免 `app.json5 file not found`；
   - 顶层与各模块统一声明 `modelVersion: "5.0.0"`；
   - `build-profile.json5` 中收敛 `compileSdkVersion` 与 `compatibleSdkVersion` 至规范的字符串形式 `"26.0.0"`。

## 本地开发与构建指南

### 1. 同步 Web 最新构建产物
在 `suenmusic-mobile` 仓库根目录下执行：
```bash
npm run hw:sync
```
该命令会自动编译同级 `suenmusic-server/web`（若未构建）并将静态文件同步至 `hw/entry/src/main/resources/rawfile/`。

### 2. 使用 DevEco Studio 运行或打包
1. 打开 **DevEco Studio**（推荐 4.1 Release / 5.0 Release 或更高版本，兼容 HarmonyOS NEXT）；
2. 选择 **File → Open...**，选择本项目下的 `hw` 目录导入；
3. 连接 HarmonyOS NEXT 真机或启动模拟器，点击 **Run 'entry'** (Shift + F10) 即可运行；
4. 构建未签名 HAP：菜单选择 **Build → Build Hap(s)/APP(s) → Build Hap(s)** 即可产出安装包。
