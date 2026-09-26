#!/usr/bin/env bash
#
# 恢复 iOS 工程的本地 vendor 依赖。
#
# 为什么需要这个脚本：
#   `npx cap sync ios` 会按 Capacitor CLI 的模板**重写**
#   `ios/App/CapApp-SPM/Package.swift`，把它从本地 path 依赖改回
#   `.package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", ...)`。
#   而那个远程包的二进制资产托管在 GitHub Releases 上，直连经常超时
#   （见 ios/Vendor/capacitor-swift-pm/README.md），所以本仓库把它 vendor 到
#   `ios/Vendor/capacitor-swift-pm/`（内含解压好的 xcframework，path 引用、离线可构建）。
#
#   每次 `cap sync ios` 之后跑一次本脚本即可恢复：
#       bash scripts/fix-ios-vendor.sh
#
# 如果 vendor 目录里缺 xcframework（.gitignore 排除了 *.xcframework，不会随仓库走），
# 脚本会尝试下载；需要代理时用 curl 认识的环境变量：
#       export https_proxy=http://<host>:<port>
#
set -euo pipefail

# xcframework 版本必须与 **suenmusic-server 仓库**（同级） web/package.json 里的
# @capacitor/* 版本一致。升级 Capacitor 时两个仓库要一起改。
CAP_VERSION="8.5.2"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/ios/App/CapApp-SPM/Package.swift"
VENDOR="$ROOT/ios/Vendor/capacitor-swift-pm"
LOCAL_LINE='        .package(path: "../../Vendor/capacitor-swift-pm")'

if [ ! -f "$PKG" ]; then
  echo "找不到 $PKG" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1) Package.swift：远程依赖 -> 本地 path 依赖（幂等）
# ---------------------------------------------------------------------------
before="$(grep -n 'capacitor-swift-pm' "$PKG" | grep -v '^\s*//' || true)"

# 用 perl 而不是 sed：BSD sed 的 -i 语义与 GNU 不同，且这里要跨行匹配。
# 只替换**未注释**的 .package(url: "…capacitor-swift-pm.git"…) 那一行。
perl -0pi -e '
  s{^[ \t]*\.package\(url:\s*"https://github\.com/ionic-team/capacitor-swift-pm\.git"[^)]*\)[ \t]*,?[ \t]*$}
   {        // 本地 vendored 依赖：path 引用、离线可构建。cap sync 会把它改回远程，
        // 重写后跑 scripts/fix-ios-vendor.sh 即可恢复本行。
        .package(path: "../../Vendor/capacitor-swift-pm")}mx;
' "$PKG"

if grep -q '\.package(path: "../../Vendor/capacitor-swift-pm")' "$PKG"; then
  echo "[fix-ios-vendor] Package.swift 已指向本地 vendor"
else
  echo "[fix-ios-vendor] Package.swift 里没找到可替换的远程依赖行，请手工检查：" >&2
  echo "    $PKG" >&2
  exit 1
fi
[ -n "$before" ] && echo "[fix-ios-vendor] 替换前: $before"

# ---------------------------------------------------------------------------
# 2) 二进制资产：缺失则下载（*.xcframework 被 .gitignore 排除，不随仓库分发）
# ---------------------------------------------------------------------------
missing=()
for name in Capacitor Cordova; do
  [ -d "$VENDOR/$name.xcframework" ] || missing+=("$name")
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "[fix-ios-vendor] 缺少: ${missing[*]} —— 从 GitHub Releases 下载 $CAP_VERSION"
  base="https://github.com/ionic-team/capacitor-swift-pm/releases/download/$CAP_VERSION"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  for name in "${missing[@]}"; do
    echo "[fix-ios-vendor] 下载 $name.xcframework.zip"
    # curl 自动识别 http_proxy / https_proxy 环境变量；失败时下面会明确指出。
    if ! curl -fL --retry 3 --retry-all-errors --connect-timeout 20 \
        -o "$tmp/$name.xcframework.zip" "$base/$name.xcframework.zip"; then
      echo "[fix-ios-vendor] 下载失败：$name.xcframework.zip" >&2
      echo "    需要代理时：export https_proxy=http://<host>:<port>" >&2
      exit 1
    fi
    unzip -oq "$tmp/$name.xcframework.zip" -d "$VENDOR"
  done
fi

for name in Capacitor Cordova; do
  [ -d "$VENDOR/$name.xcframework" ] || { echo "[fix-ios-vendor] 仍然缺少 $name.xcframework" >&2; exit 1; }
done

echo "[fix-ios-vendor] vendor 就绪：$VENDOR"
echo "[fix-ios-vendor] 提示：xcodebuild 会自动重新解析；只有在 Xcode 图形界面里遇到"
echo "[fix-ios-vendor]       'Missing package product' 时才需要 File > Packages > Reset Package Caches"
