//
//  DeviceInstaller.swift
//  esign
//

import Foundation

// MARK: - 数据模型

nonisolated struct ConnectedDevice: Identifiable, Hashable {
    let identifier: String
    let udid: String
    let name: String
    let productType: String
    let platform: String
    let osVersion: String
    let connectionState: String
    let transportType: String

    var id: String { identifier }

    var displayName: String {
        name.isEmpty ? productType : name
    }

    var isConnected: Bool { connectionState == "connected" }
    var isWired: Bool { transportType == "wired" }

    var connectionDescription: String {
        guard isConnected else { return "未连接" }
        return isWired ? "USB 已连接" : "网络已连接"
    }

    var detail: String {
        var parts: [String] = []
        if !productType.isEmpty { parts.append(productType) }
        if !osVersion.isEmpty { parts.append("\(platform) \(osVersion)") }
        parts.append(connectionDescription)
        return parts.joined(separator: " · ")
    }
}

enum DeviceInstallError: LocalizedError {
    case devicectlUnavailable(String)
    case listFailed(ShellResult)
    case invalidDeviceList(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .devicectlUnavailable(let reason):
            reason
        case .listFailed(let result):
            "读取设备列表失败（退出码 \(result.exitCode)）\n\(result.combined)"
        case .invalidDeviceList(let reason):
            "无法解析设备列表：\(reason)"
        case .installFailed(let reason):
            "安装失败：\(reason)"
        }
    }
}

// MARK: - 安装引擎

nonisolated enum DeviceInstaller {
    typealias Logger = @Sendable (String) -> Void

    private nonisolated static var xcrunPath: String { "/usr/bin/xcrun" }
    /// 安装整体超时。设备未连接时 devicectl 会一直等待建立隧道，靠这个值兜底。
    private nonisolated static let installTimeoutSeconds = 300

    /// 手表等设备装不了 IPA，列表里过滤掉，避免干扰。
    private nonisolated static let unsupportedPlatforms: Set<String> = ["watchOS", "tvOS", "visionOS", "xrOS"]

    // MARK: 设备列表

    nonisolated static func listDevices() throws -> [ConnectedDevice] {
        try ensureDevicectlAvailable()

        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("esign-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let result = try Shell.run(xcrunPath, ["devicectl", "list", "devices", "--json-output", jsonURL.path])
        guard result.succeeded else {
            throw DeviceInstallError.listFailed(result)
        }
        guard let data = try? Data(contentsOf: jsonURL) else {
            throw DeviceInstallError.invalidDeviceList("devicectl 未输出 JSON")
        }
        return try parseDevices(data)
    }

    nonisolated static func parseDevices(_ data: Data) throws -> [ConnectedDevice] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let result = root["result"] as? [String: Any],
              let rawDevices = result["devices"] as? [[String: Any]] else {
            throw DeviceInstallError.invalidDeviceList("JSON 结构与预期不符")
        }

        let devices = rawDevices.compactMap { raw -> ConnectedDevice? in
            let properties = raw["properties"] as? [String: Any] ?? [:]
            let hardware = properties["hardware"] as? [String: Any] ?? [:]
            let connection = properties["connection"] as? [String: Any] ?? [:]
            let software = properties["software"] as? [String: Any] ?? [:]
            let state = properties["state"] as? [String: Any] ?? [:]

            let platform = hardware["platform"] as? String ?? ""
            guard !unsupportedPlatforms.contains(platform) else { return nil }
            guard let identifier = raw["identifier"] as? String else { return nil }

            // 新版本 devicectl 把名称放在 properties.state.name，
            // 旧版本只在已废弃的 deviceProperties 里，做一次兜底。
            let legacy = raw["deviceProperties"] as? [String: Any] ?? [:]
            let name = (state["name"] as? String) ?? (legacy["name"] as? String) ?? ""

            let osVersion = ((software["osVersionNumber"] as? [String: Any])?["stringValue"] as? String) ?? ""

            return ConnectedDevice(
                identifier: identifier,
                udid: hardware["udid"] as? String ?? "",
                name: name,
                productType: hardware["productType"] as? String ?? "",
                platform: platform,
                osVersion: osVersion,
                connectionState: connection["state"] as? String ?? "",
                transportType: connection["transportType"] as? String ?? ""
            )
        }

        return devices.sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    // MARK: 安装

    nonisolated static func install(ipaURL: URL, device: ConnectedDevice, log: @escaping Logger) throws {
        try ensureDevicectlAvailable()

        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("esign-install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        log("解压 IPA…")
        let appURL = try IPAArchive.extract(ipaURL, to: workspace.appendingPathComponent("extract", isDirectory: true))
        log("定位到应用：\(appURL.lastPathComponent)")

        log("安装到 \(device.displayName)（\(device.connectionDescription)），可能需要一分钟…")
        let jsonURL = workspace.appendingPathComponent("result.json")
        let result = try Shell.runStreaming(
            xcrunPath,
            [
                "devicectl", "device", "install", "app",
                "--device", device.identifier,
                "--timeout", "\(installTimeoutSeconds)",
                "--json-output", jsonURL.path,
                appURL.path
            ],
            lineHandler: { line in log(line) }
        )

        guard result.succeeded else {
            throw DeviceInstallError.installFailed(failureMessage(at: jsonURL) ?? result.combined)
        }
        log("安装完成。")
    }

    // MARK: 工具

    private nonisolated static func ensureDevicectlAvailable() throws {
        let result = try Shell.run(xcrunPath, ["--find", "devicectl"])
        guard result.succeeded else {
            throw DeviceInstallError.devicectlUnavailable(
                "未找到 devicectl 命令。安装功能需要完整安装的 Xcode（命令行工具不含该命令），"
                + "且需用 xcode-select 指向它。"
            )
        }
    }

    /// devicectl 失败时会把可读原因写进 --json-output 的 error.userInfo 里。
    private nonisolated static func failureMessage(at jsonURL: URL) -> String? {
        guard let data = try? Data(contentsOf: jsonURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let error = root["error"] as? [String: Any],
              let userInfo = error["userInfo"] as? [String: Any],
              let description = userInfo["NSLocalizedDescription"] as? [String: Any],
              let message = description["string"] as? String else {
            return nil
        }
        return message
    }
}
