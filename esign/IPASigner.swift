//
//  IPASigner.swift
//  esign
//

import Foundation

// MARK: - 数据模型

nonisolated struct SigningIdentity: Identifiable, Hashable {
    let hash: String
    let name: String

    var id: String { hash }
}

nonisolated enum CertificateMode: String, CaseIterable, Identifiable {
    case keychain
    case p12

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keychain: "钥匙串"
        case .p12: "P12 文件"
        }
    }
}

nonisolated enum CertificateSource {
    case keychain(identityHash: String)
    case p12(url: URL, password: String)
}

nonisolated struct SigningRequest {
    let ipaURL: URL
    let bundleIdentifier: String
    let certificate: CertificateSource
    let provisioningProfileURL: URL
}

nonisolated struct ProvisioningProfile {
    let name: String
    let entitlements: [String: Any]
    let applicationIdentifier: String?
    let expirationDate: Date?

    var teamIdentifier: String? {
        if let identifier = applicationIdentifier, let team = identifier.split(separator: ".").first {
            return String(team)
        }
        return entitlements["com.apple.developer.team-identifier"] as? String
    }

    var isWildcard: Bool {
        applicationIdentifier?.hasSuffix(".*") ?? false
    }

    var appIdentifierWithoutTeam: String? {
        guard let identifier = applicationIdentifier, let dot = identifier.firstIndex(of: ".") else {
            return nil
        }
        return String(identifier[identifier.index(after: dot)...])
    }
}

enum IPASigningError: LocalizedError {
    case invalidIPA(String)
    case toolFailed(name: String, result: ShellResult)
    case noIdentity(String)
    case invalidProfile(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidIPA(let reason):
            "IPA 文件无效：\(reason)"
        case .toolFailed(let name, let result):
            "\(name) 执行失败（退出码 \(result.exitCode)）\n\(result.combined)"
        case .noIdentity(let reason):
            "未找到可用签名证书：\(reason)"
        case .invalidProfile(let reason):
            "描述文件无效：\(reason)"
        case .message(let reason):
            reason
        }
    }
}

// MARK: - 签名引擎

enum IPASigner {
    typealias Logger = @Sendable (String) -> Void

    private nonisolated static var codesignPath: String { "/usr/bin/codesign" }
    private nonisolated static var securityPath: String { "/usr/bin/security" }

    // MARK: 入口

    nonisolated static func sign(request: SigningRequest, log: Logger) throws -> URL {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("esign-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        // 1. 解压 IPA
        log("解压 IPA…")
        let extractDirectory = workspace.appendingPathComponent("extract", isDirectory: true)
        let appURL = try IPAArchive.extract(request.ipaURL, to: extractDirectory)
        log("定位到应用：\(appURL.lastPathComponent)")

        // 2. 准备签名证书
        var temporaryKeychainPath: String?
        defer {
            if let path = temporaryKeychainPath {
                log("清理临时钥匙串…")
                _ = try? Shell.run(securityPath, ["delete-keychain", path])
            }
        }
        let identity = try resolveIdentity(
            for: request.certificate,
            workspace: workspace,
            log: log,
            temporaryKeychainPath: &temporaryKeychainPath
        )

        // 3. 读取描述文件
        let profile = try readProfile(request.provisioningProfileURL)
        log("描述文件：\(profile.name)")
        if let expiration = profile.expirationDate, expiration < Date() {
            log("⚠️ 描述文件已于 \(formatDate(expiration)) 过期")
        }
        validateBundleIdentifier(request.bundleIdentifier, against: profile, log: log)

        // 4. 替换 embedded.mobileprovision
        log("写入 embedded.mobileprovision…")
        try installProfile(request.provisioningProfileURL, into: appURL)

        // 5. 修改 Bundle Identifier（含嵌套扩展）
        if !request.bundleIdentifier.isEmpty {
            try updateBundleIdentifiers(in: appURL, to: request.bundleIdentifier, log: log)
        }

        // 6. 逐层签名（由内到外）
        let nestedItems = nestedCodeItems(in: appURL)
        for item in nestedItems {
            let isNestedBundle = ["appex", "app"].contains(item.pathExtension.lowercased())
            var entitlementsURL: URL?

            if isNestedBundle {
                try installProfile(request.provisioningProfileURL, into: item)
                var entitlements = profile.entitlements
                if let team = profile.teamIdentifier,
                   let bundleID = bundleIdentifier(of: item) {
                    entitlements["application-identifier"] = "\(team).\(bundleID)"
                    if entitlements["keychain-access-groups"] != nil {
                        entitlements["keychain-access-groups"] = ["\(team).\(bundleID)"]
                    }
                }
                entitlementsURL = try writeEntitlements(entitlements, to: workspace, name: item.lastPathComponent)
            }

            log("签名：\(relativePath(of: item, in: appURL))")
            try signBundle(item, identity: identity, entitlementsURL: entitlementsURL)
        }

        // 7. 签名主应用
        let appEntitlementsURL = try writeEntitlements(
            profile.entitlements,
            to: workspace,
            name: appURL.lastPathComponent
        )
        log("签名主应用：\(appURL.lastPathComponent)")
        try signBundle(appURL, identity: identity, entitlementsURL: appEntitlementsURL)

        if let output = try? Shell.run(codesignPath, ["--verify", "--verbose=2", appURL.path]),
           !output.succeeded {
            log("⚠️ 校验提示：\(output.combined)")
        }

        // 8. 重新打包
        let outputURL = IPAArchive.signedOutputURL(for: request.ipaURL)
        log("重新打包为 \(outputURL.lastPathComponent)…")
        try IPAArchive.archive(extractedDirectory: extractDirectory, to: outputURL)

        log("签名完成：\(outputURL.path)")
        return outputURL
    }

    // MARK: 证书

    nonisolated static func availableIdentities(keychainPath: String? = nil, validOnly: Bool = true) throws -> [SigningIdentity] {
        var arguments = ["find-identity"]
        if validOnly {
            arguments.append("-v")
        }
        arguments += ["-p", "codesigning"]
        if let keychainPath {
            arguments.append(keychainPath)
        }
        let result = try Shell.run(securityPath, arguments)
        return parseIdentities(result.combined)
    }

    nonisolated static func parseIdentities(_ output: String) -> [SigningIdentity] {
        var identities: [SigningIdentity] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let closeParen = line.firstIndex(of: ")") else { continue }
            let remainder = line[line.index(after: closeParen)...].trimmingCharacters(in: .whitespaces)
            let parts = remainder.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let hash = String(parts[0])
            guard hash.count == 40, hash.allSatisfy(\.isHexDigit) else { continue }
            // 名称在引号中；未通过信任校验时后面还会跟 (CSSMERR_...)，需按引号截取。
            let quoted = parts[1]
            guard let openQuote = quoted.firstIndex(of: "\""),
                  let closeQuote = quoted.lastIndex(of: "\""),
                  openQuote < closeQuote else { continue }
            let name = String(quoted[quoted.index(after: openQuote)..<closeQuote])
            identities.append(SigningIdentity(hash: hash, name: name))
        }
        return identities
    }

    private nonisolated static func resolveIdentity(
        for source: CertificateSource,
        workspace: URL,
        log: Logger,
        temporaryKeychainPath: inout String?
    ) throws -> (hash: String, keychainPath: String?) {
        switch source {
        case .keychain(let hash):
            let name = (try? availableIdentities())?.first(where: { $0.hash == hash })?.name ?? hash
            log("使用钥匙串证书：\(name)")
            return (hash, nil)

        case .p12(let url, let password):
            let keychainPath = workspace.appendingPathComponent("esign.keychain-db").path
            let keychainPassword = UUID().uuidString

            log("创建临时钥匙串…")
            try run(securityPath, ["create-keychain", "-p", keychainPassword, keychainPath], name: "security create-keychain")
            temporaryKeychainPath = keychainPath
            try run(securityPath, ["set-keychain-settings", keychainPath], name: "security set-keychain-settings")
            try run(securityPath, ["unlock-keychain", "-p", keychainPassword, keychainPath], name: "security unlock-keychain")

            log("导入 P12 证书…")
            try run(
                securityPath,
                [
                    "import", url.path,
                    "-k", keychainPath,
                    "-P", password,
                    "-T", codesignPath,
                    "-T", securityPath,
                    "-A"
                ],
                name: "security import"
            )
            // 允许 codesign 无需弹窗访问私钥。
            _ = try? Shell.run(
                securityPath,
                ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", keychainPassword, keychainPath]
            )

            var identities = try availableIdentities(keychainPath: keychainPath)
            if identities.isEmpty {
                // 证书链缺少中间证书等情况下信任校验会失败，但仍可尝试签名。
                identities = try availableIdentities(keychainPath: keychainPath, validOnly: false)
                if !identities.isEmpty {
                    log("⚠️ 证书链未通过系统信任校验，仍尝试使用")
                }
            }
            guard let identity = identities.first else {
                throw IPASigningError.noIdentity("P12 中未找到可用于代码签名的证书，请检查密码是否正确")
            }
            log("使用 P12 证书：\(identity.name)")
            return (identity.hash, keychainPath)
        }
    }

    private nonisolated static func signBundle(
        _ url: URL,
        identity: (hash: String, keychainPath: String?),
        entitlementsURL: URL?
    ) throws {
        var arguments = ["--force", "--sign", identity.hash, "--timestamp=none"]
        if let keychainPath = identity.keychainPath {
            arguments += ["--keychain", keychainPath]
        }
        if let entitlementsURL {
            arguments += ["--entitlements", entitlementsURL.path]
        }
        arguments.append(url.path)
        try run(codesignPath, arguments, name: "codesign")
    }

    // MARK: 描述文件

    nonisolated static func readProfile(_ url: URL) throws -> ProvisioningProfile {
        let result = try Shell.run(securityPath, ["cms", "-D", "-i", url.path])
        guard result.succeeded, let data = result.stdout.data(using: .utf8), !data.isEmpty else {
            throw IPASigningError.invalidProfile(result.combined.isEmpty ? "无法解析该文件" : result.combined)
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw IPASigningError.invalidProfile("无法解析描述文件内容")
        }
        guard let entitlements = plist["Entitlements"] as? [String: Any] else {
            throw IPASigningError.invalidProfile("描述文件中缺少 Entitlements")
        }
        return ProvisioningProfile(
            name: plist["Name"] as? String ?? url.lastPathComponent,
            entitlements: entitlements,
            applicationIdentifier: entitlements["application-identifier"] as? String,
            expirationDate: plist["ExpirationDate"] as? Date
        )
    }

    nonisolated static func profileSummary(for url: URL) throws -> String {
        let profile = try readProfile(url)
        var parts = ["名称：\(profile.name)"]
        if let team = profile.teamIdentifier {
            parts.append("团队：\(team)")
        }
        if let appID = profile.applicationIdentifier {
            parts.append("App ID：\(appID)")
        }
        if let expiration = profile.expirationDate {
            parts.append("到期：\(formatDate(expiration))")
        }
        return parts.joined(separator: "  ·  ")
    }

    private nonisolated static func installProfile(_ profileURL: URL, into bundleURL: URL) throws {
        let destination = bundleURL.appendingPathComponent("embedded.mobileprovision")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: profileURL, to: destination)
    }

    private nonisolated static func writeEntitlements(
        _ entitlements: [String: Any],
        to workspace: URL,
        name: String
    ) throws -> URL {
        let url = workspace.appendingPathComponent("\(name)-entitlements.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    // MARK: Bundle Identifier

    private nonisolated static func updateBundleIdentifiers(in appURL: URL, to newIdentifier: String, log: Logger) throws {
        let oldIdentifier = bundleIdentifier(of: appURL)
        try updateBundleIdentifier(of: appURL, to: newIdentifier, log: log)

        guard let oldIdentifier, oldIdentifier != newIdentifier else { return }
        for item in nestedCodeItems(in: appURL) where ["appex", "app"].contains(item.pathExtension.lowercased()) {
            guard let nested = bundleIdentifier(of: item), nested.hasPrefix(oldIdentifier + ".") else { continue }
            let suffix = String(nested.dropFirst(oldIdentifier.count))
            try updateBundleIdentifier(of: item, to: newIdentifier + suffix, log: log)
        }
    }

    private nonisolated static func updateBundleIdentifier(of bundleURL: URL, to newIdentifier: String, log: Logger) throws {
        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw IPASigningError.invalidIPA("\(bundleURL.lastPathComponent) 缺少 Info.plist")
        }
        let data = try Data(contentsOf: plistURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            throw IPASigningError.invalidIPA("无法解析 \(bundleURL.lastPathComponent)/Info.plist")
        }
        let previous = plist["CFBundleIdentifier"] as? String
        guard previous != newIdentifier else { return }
        plist["CFBundleIdentifier"] = newIdentifier
        let updated = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
        try updated.write(to: plistURL)
        log("Bundle Identifier：\(previous ?? "无") → \(newIdentifier)")
    }

    private nonisolated static func bundleIdentifier(of bundleURL: URL) -> String? {
        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }

    private nonisolated static func validateBundleIdentifier(_ identifier: String, against profile: ProvisioningProfile, log: Logger) {
        guard !identifier.isEmpty, !profile.isWildcard else { return }
        if let allowed = profile.appIdentifierWithoutTeam, allowed != identifier {
            log("⚠️ 新的 Bundle Identifier 与描述文件的 App ID（\(allowed)）不一致，可能无法安装")
        }
    }

    // MARK: 嵌套代码

    /// 收集需要单独签名的嵌套代码（framework / dylib / appex / 嵌套 app），并按层级由深到浅排序。
    private nonisolated static func nestedCodeItems(in appURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: nil
        ) else { return [] }

        var items: [URL] = []
        for case let url as URL in enumerator {
            switch url.pathExtension.lowercased() {
            case "framework":
                items.append(url)
                enumerator.skipDescendants()
            case "appex", "app", "dylib":
                items.append(url)
            default:
                break
            }
        }
        return items.sorted { $0.pathComponents.count > $1.pathComponents.count }
    }

    // MARK: 工具

    private nonisolated static func relativePath(of url: URL, in appURL: URL) -> String {
        guard url.path.hasPrefix(appURL.path) else { return url.lastPathComponent }
        let relative = url.path.dropFirst(appURL.path.count).drop { $0 == "/" }
        return relative.isEmpty ? url.lastPathComponent : String(relative)
    }

    @discardableResult
    private nonisolated static func run(
        _ executable: String,
        _ arguments: [String],
        name: String,
        currentDirectory: URL? = nil,
        allowFailure: Bool = false
    ) throws -> ShellResult {
        let result = try Shell.run(executable, arguments, currentDirectory: currentDirectory)
        if !result.succeeded && !allowFailure {
            throw IPASigningError.toolFailed(name: name, result: result)
        }
        return result
    }

    private nonisolated static func formatDate(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }
}
