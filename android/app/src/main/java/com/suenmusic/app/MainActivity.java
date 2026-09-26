package com.suenmusic.app;

import android.os.Bundle;
import android.webkit.WebView;
import androidx.activity.OnBackPressedCallback;
import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsControllerCompat;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {

  @Override
  public void onCreate(Bundle savedInstanceState) {
    registerPlugin(SuenAudioPlugin.class);
    registerPlugin(SuenUpdatePlugin.class);
    super.onCreate(savedInstanceState);
    WindowCompat.setDecorFitsSystemWindows(getWindow(), false);
    getWindow().setStatusBarColor(android.graphics.Color.TRANSPARENT);
    getWindow().setNavigationBarColor(android.graphics.Color.TRANSPARENT);
    injectSafeAreaInsets();
    installBackHandling();
    installThemeHandling();
    installBackupHandling();
    // 通知权限由用户开启“车机蓝牙歌词”功能时按需请求，不在启动时打扰用户。
  }

  /**
   * Android 13+ (API 33) 要求运行时请求 POST_NOTIFICATIONS 权限，
   * 否则系统会静默屏蔽通知栏 MediaSession 控制条与前台服务通知。
   */
  private void requestNotificationPermission() {
    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
      if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
          != android.content.pm.PackageManager.PERMISSION_GRANTED) {
        requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS}, 101);
      }
    }
  }

  /**
   * 返回手势（手势返回 / 返回键）：先问 Web 层，再谈历史与退出。
   *
   * 为什么必须自己接：Capacitor 核心**不接管**返回键 —— 那是 `@capacitor/app`
   * 插件的职责，没装它时返回事件直接落到 Activity 默认实现，也就是
   * **任何一次返回手势都立刻退出应用**。真机反馈："在收藏里搜了歌，结束搜索
   * 必须手动删关键词，按返回直接退出应用。"
   *
   * 顺序：
   *   1. Web 层（`window.__suenBack`）能消费就消费：退出筛选态 / 关浮层 / 关键盘；
   *   2. WebView 还有历史 → goBack()，前端路由的 popstate 会正常接管；
   *   3. 都没有 → moveTaskToBack()：**刻意不用 finish()** —— Activity 一销毁，
   *      WebView 里 SPA 的播放队列和 MediaSession 连接就全丢了，而音乐还在前台
   *      服务里放着，重进 App 会变成"音乐在响但播放条是空的"。
   *
   * evaluateJavascript 是异步的（回调回主线程），所以不能提前 return：先截住，
   * 由回调决定后续动作。代价是生效晚一两帧，可接受。
   */
  private void installBackHandling() {
    getOnBackPressedDispatcher()
      .addCallback(
        this,
        new OnBackPressedCallback(true) {
          @Override
          public void handleOnBackPressed() {
            WebView webView = getBridge() != null ? getBridge().getWebView() : null;
            if (webView == null) {
              moveTaskToBack(true);
              return;
            }
            // 表达式返回**布尔值**：返回字符串会被 JSON 引号包一层（"\"true\""），
            // 下面按 "true" 比较就永远判成"没消费"
            webView.evaluateJavascript(
              "(typeof window.__suenBack === 'function') && window.__suenBack() === true",
              handled -> {
                if ("true".equals(handled)) return; // Web 层已消费
                if (webView.canGoBack()) {
                  webView.goBack();
                  return;
                }
                moveTaskToBack(true);
              }
            );
          }
        }
      );
  }

  /**
   * 把窗口 insets 注入成 CSS 变量（`--inset-top` / `--inset-bottom`，单位 CSS px）。
   *
   * 为什么必须这么做：安卓 WebView 拿不到可靠的安全区 —— Capacitor 只在 iOS
   * 注入，`env(safe-area-inset-*)` 在安卓上通常是 0；而 Android 15 起强制
   * edge-to-edge，页面会画到**透明状态栏底下**。真机表现是"所有 tab 页顶部的
   * 按钮被状态栏遮挡"（模拟器/虚拟机因为状态栏不透明而无法复现）。
   *
   * 这里把 systemBars 的 insets 转成 CSS px 写进 documentElement，由 web 侧的
   * `--safe-top` / `--safe-bottom`（见 web/src/styles/tokens.css）消费。
   * 旋转屏幕或 insets 变化时会重新注入。
   */
  private void injectSafeAreaInsets() {
    if (getBridge() == null) return;
    final WebView webView = getBridge().getWebView();
    if (webView == null) return;

    // 挂在 decorView 上最稳：任何父容器 consume 掉 insets 都不影响这里
    ViewCompat.setOnApplyWindowInsetsListener(
        getWindow().getDecorView(),
        (view, windowInsets) -> {
          Insets bars = windowInsets.getInsets(WindowInsetsCompat.Type.systemBars());
          float density = getResources().getDisplayMetrics().density;
          if (density <= 0) density = 1f;
          final int topDp = Math.round(bars.top / density);
          final int bottomDp = Math.round(bars.bottom / density);

          webView.post(() -> {
            if (getBridge() == null) return;
            getBridge().eval(
                "document.documentElement.style.setProperty('--inset-top','" + topDp + "px');"
                    + "document.documentElement.style.setProperty('--inset-bottom','"
                    + bottomDp + "px');",
                null   // Capacitor 8 的第二参数是结果回调（旧版是 boolean）
            );
          });
          return windowInsets;
        }
    );
    ViewCompat.requestApplyInsets(getWindow().getDecorView());
  }

  /**
   * 系统状态栏与导航栏深浅色联动：
   *
   * Android 15 起强制 Edge-to-Edge，状态栏是透明沉浸的。
   * 当应用为浅色模式时，状态栏背景是浅色，状态栏图标和字体必须为深色（setAppearanceLightStatusBars(true)）；
   * 当应用为深色模式时，状态栏背景是深色，状态栏图标和字体必须为浅色（setAppearanceLightStatusBars(false)）。
   *
   * 通过给 WebView 注入 SuenNativeTheme 接口，由 Web 层在 applyTheme 时直接调用。
   */
  private void installThemeHandling() {
    if (getBridge() == null) return;
    final WebView webView = getBridge().getWebView();
    if (webView == null) return;

    boolean isNight = (getResources().getConfiguration().uiMode & android.content.res.Configuration.UI_MODE_NIGHT_MASK)
        == android.content.res.Configuration.UI_MODE_NIGHT_YES;
    runOnUiThread(() -> {
      WindowInsetsControllerCompat controller =
          WindowCompat.getInsetsController(getWindow(), getWindow().getDecorView());
      if (controller != null) {
        controller.setAppearanceLightStatusBars(!isNight);
        controller.setAppearanceLightNavigationBars(!isNight);
      }
    });

    webView.addJavascriptInterface(new Object() {
      @android.webkit.JavascriptInterface
      public void setDarkMode(boolean isDark) {
        runOnUiThread(() -> {
          WindowInsetsControllerCompat controller =
              WindowCompat.getInsetsController(getWindow(), getWindow().getDecorView());
          if (controller != null) {
            controller.setAppearanceLightStatusBars(!isDark);
            controller.setAppearanceLightNavigationBars(!isDark);
          }
        });
      }
    }, "SuenNativeTheme");
  }

  /**
   * 注入原生备份保存能力（SuenNativeBackup）。
   *
   * 用于在 Android 端将导出的 .sm 归档直接写入系统 Downloads/SuenMusic 目录，
   * 避开 Web 浏览器链接下载在某些 WebView 环境中的权限限制。
   */
  private void installBackupHandling() {
    if (getBridge() == null) return;
    final WebView webView = getBridge().getWebView();
    if (webView == null) return;

    webView.addJavascriptInterface(new Object() {
      @android.webkit.JavascriptInterface
      public boolean saveBackup(String base64Data, String fileName) {
        try {
          byte[] bytes = android.util.Base64.decode(base64Data, android.util.Base64.DEFAULT);
          if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            android.content.ContentValues values = new android.content.ContentValues();
            values.put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, fileName);
            values.put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "application/octet-stream");
            values.put(
              android.provider.MediaStore.MediaColumns.RELATIVE_PATH,
              android.os.Environment.DIRECTORY_DOWNLOADS + "/SuenMusic"
            );
            android.net.Uri uri = getContentResolver().insert(
              android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI,
              values
            );
            if (uri != null) {
              try (java.io.OutputStream os = getContentResolver().openOutputStream(uri)) {
                if (os != null) {
                  os.write(bytes);
                  os.flush();
                  return true;
                }
              }
            }
          } else {
            java.io.File dir = new java.io.File(
              android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS),
              "SuenMusic"
            );
            if (!dir.exists()) dir.mkdirs();
            java.io.File file = new java.io.File(dir, fileName);
            try (java.io.FileOutputStream fos = new java.io.FileOutputStream(file)) {
              fos.write(bytes);
              fos.flush();
              return true;
            }
          }
        } catch (Exception e) {
          android.util.Log.e("SuenNativeBackup", "Failed to save backup", e);
        }
        return false;
      }
    }, "SuenNativeBackup");
  }
}

