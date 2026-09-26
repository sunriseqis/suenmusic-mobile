import Capacitor
import UIKit

/**
 * SuenUpdate —— iOS 侧的应用更新桥。
 *
 * 与安卓的同名插件**共享 jsName 与 JS 契约**（`getAppVersion` / `openUpdate`），
 * 但能力边界完全不同 —— 这是 iOS 的硬约束，不是"还没做完"：
 *
 *   - 沙箱不允许应用安装/替换自己，没有安卓 `PackageInstaller` +
 *     `REQUEST_INSTALL_PACKAGES` 的等价物；
 *   - 免费开发者签名下也没有可用的 OTA 通道：`itms-services://` 只认企业证书
 *     或付费账号的 ad-hoc 描述文件，而免费账号的 development profile 7 天就失效。
 *
 * 所以这里只做一件事：**把安装包地址交给应用外部**。
 *   1. 优先唤起重签工具（AltStore / SideStore）—— 它们用自己的证书重新签名并安装，
 *      这是免费签名下体验最好的一条路（一键装）；
 *   2. 都没装则交给系统用 Safari 打开，用户下载后经「文件」App / 重签工具安装。
 *
 * 两条路都**发不出 Authorization 头**，所以地址里带的是服务端签发的短期下载令牌
 * （见 server 的 `utils/update-token.ts`）—— 客户端只管把 check 返回的地址拼好。
 */
@objc(SuenUpdatePlugin)
public class SuenUpdatePlugin: CAPPlugin, CAPBridgedPlugin {

    public let identifier = "SuenUpdatePlugin"
    public let jsName = "SuenUpdate"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getAppVersion", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openUpdate", returnType: CAPPluginReturnPromise),
    ]

    /**
     * 支持"唤起即装包"的重签工具，顺序即优先级。
     *
     * `install?url=` 是 AltStore / SideStore 通用的安装入口：它们会自己去拉这个
     * 地址的 IPA，再用本机证书重签安装 —— 我们不需要（也无法）在应用内下载。
     */
    private static let installerSchemes = ["altstore", "sidestore"]

    /// 当前应用版本。
    /// `versionCode` 取 `CFBundleVersion`（Xcode 里的 CURRENT_PROJECT_VERSION），
    /// 与安卓的 versionCode 语义对齐；发新版时两者都要递增。
    @objc func getAppVersion(_ call: CAPPluginCall) {
        let info = Bundle.main.infoDictionary ?? [:]
        let versionName = (info["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let versionCode = Int((info["CFBundleVersion"] as? String) ?? "") ?? 0
        call.resolve([
            "versionName": versionName,
            "versionCode": versionCode,
        ])
    }

    /**
     * 把安装包地址交给应用外部。
     *
     * 返回值语义（与 Web 端 store 的文案一一对应）：
     *   - `opened`   已唤起重签工具，安装由它在应用外完成
     *   - `external` 已交给系统（Safari）—— **这不是失败**，是免费签名下的正常路径
     */
    @objc func openUpdate(_ call: CAPPluginCall) {
        guard let raw = call.getString("url"),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            call.reject("更新地址无效")
            return
        }

        // 与 SuenAudio 同一条铁律：所有回调都切回主线程。
        // UIApplication.open 与 call.resolve 都必须在主线程上收尾。
        SuenUpdatePlugin.onMain { [weak self] in
            guard let self = self else { return }
            self.openInInstaller(url) { opened in
                if opened {
                    call.resolve(["status": "opened"])
                    return
                }
                UIApplication.shared.open(url, options: [:]) { success in
                    if success {
                        call.resolve(["status": "external"])
                    } else {
                        call.reject("无法打开安装包地址")
                    }
                }
            }
        }
    }

    // MARK: 私有

    /// 逐个试重签工具的 scheme。地址里带 `&` 等查询字符，必须整段百分号编码后再嵌进 `url=`。
    private func openInInstaller(_ ipaURL: URL, completion: @escaping (Bool) -> Void) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = ipaURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? ipaURL.absoluteString
        tryNextInstaller(0, encoded: encoded, completion: completion)
    }

    private func tryNextInstaller(_ index: Int, encoded: String,
                                  completion: @escaping (Bool) -> Void) {
        guard index < SuenUpdatePlugin.installerSchemes.count else {
            completion(false)
            return
        }
        let scheme = SuenUpdatePlugin.installerSchemes[index]
        guard let candidate = URL(string: "\(scheme)://install?url=\(encoded)") else {
            tryNextInstaller(index + 1, encoded: encoded, completion: completion)
            return
        }
        // `canOpenURL` 依赖 Info.plist 的 LSApplicationQueriesSchemes 白名单；
        // 没装该工具时返回 false —— 继续试下一个，不是错误。
        guard UIApplication.shared.canOpenURL(candidate) else {
            tryNextInstaller(index + 1, encoded: encoded, completion: completion)
            return
        }
        UIApplication.shared.open(candidate, options: [:]) { success in
            if success {
                completion(true)
            } else {
                self.tryNextInstaller(index + 1, encoded: encoded, completion: completion)
            }
        }
    }

    private static func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
