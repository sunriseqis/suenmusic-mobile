# suenmusic-mobile 文档

本仓库是 SuenMusic 的**移动端原生工程**（Android + iOS）。前端与后端在同级的
**suenmusic-server** 仓库里。

> ⚠️ **两个仓库必须检出在同一级目录**：
> ```
> <parent>/
> ├── suenmusic-server/            # web/ + server/ + 服务端文档
> └── suenmusic-mobile/     # android/ + ios/ + 本处文档
> ```
> 因为 `suenmusic-server/web/capacitor.config.ts` 里写着 `../../suenmusic-mobile/android`，
> 而本仓库 `scripts/build-ios.mjs` 里写着 `../suenmusic-server/web` —— 这两条相对路径
> 互为两面，布局一错构建就断。

## 目录

| 文件 | 内容 |
|---|---|
| [`architecture/ios-plan.md`](architecture/ios-plan.md) | iOS 端实施方案：原生播放桥（AVQueuePlayer）、回环代理式离线缓存、按平台分流的更新通道、免费签名路线、构建脚本，以及**改代码前必读的硬约束** |
| [`guides/ios-自签安装指南.md`](guides/ios-自签安装指南.md) | 不付费自用的 iOS 安装与 7 天续签全流程（SideStore），含排错与命令速查 |
| [`memory/README.md`](memory/README.md) | **移动端开发记忆**：长期不动摇的约束（`MEMORY.md`）＋ 按天的移动端摘录 |

## 构建

```bash
# iOS：web 构建 → cap sync → vendor 还原 → xcodebuild → 打包未签名 IPA
npm run ios:ipa:unsigned      # 产物：app/unsigned/SuenMusic-v<版本>-release.ipa
npm run ios:sync              # 只做同步，进 Xcode 前跑

# 安卓：在 suenmusic-server 仓库里构建前端并同步，再回本仓库 gradle
cd ../suenmusic-server/web && npm ci && npm run build && npx cap sync android
cd ../suenmusic-mobile/android && ./gradlew assembleRelease
```

产物统一归口到 `app/`：

```
app/SuenMusic-v<版本>-release.apk     # 安卓正式包（仓库内 keystore 签名）
app/SuenMusic-v<版本>-release.ipa     # iOS 未签名包（交给 SideStore 重签）
```

## 文档在哪

**日常开发记忆（`memory/`）、路线图、服务端与 Web 的设计/报告**都在
[suenmusic-server 仓库的 `docs/`](https://github.com/sunriseqis/suenmusic-server/tree/main/docs)。

按平台彻底拆分 `memory/` 里那些**按天记录**的条目会打断上下文（同一天里几个端的事
是交织写的），所以那部分没有搬过来 —— 需要移动端的历史结论时请回 suenmusic-server 仓库查，
或看 `architecture/ios-plan.md` 里已经沉淀下来的硬约束。
