//
//  InstallViewModel.swift
//  esign
//

import AppKit
import Combine
import Foundation

@MainActor
final class InstallViewModel: ObservableObject {
    @Published var ipaURL: URL?
    @Published var devices: [ConnectedDevice] = []
    @Published var selectedDeviceID: String?
    @Published var isLoadingDevices = false
    @Published var deviceListError: String?

    @Published var logText: String = ""
    @Published var isInstalling = false
    @Published var errorMessage: String?
    @Published var alertIsPresented = false

    var selectedDevice: ConnectedDevice? {
        devices.first { $0.identifier == selectedDeviceID }
    }

    var canInstall: Bool {
        ipaURL != nil && selectedDevice != nil && !isInstalling
    }

    // MARK: 文件选择

    func setIPA(_ url: URL) {
        ipaURL = url
        appendLog("已选择 IPA：\(url.path)")
    }

    // MARK: 设备列表

    func loadDevices() {
        isLoadingDevices = true
        deviceListError = nil
        Task {
            let result = await Task.detached { () -> Result<[ConnectedDevice], Error> in
                do {
                    return .success(try DeviceInstaller.listDevices())
                } catch {
                    return .failure(error)
                }
            }.value
            isLoadingDevices = false

            switch result {
            case .success(let devices):
                self.devices = devices
                if selectedDeviceID == nil || !devices.contains(where: { $0.identifier == selectedDeviceID }) {
                    selectedDeviceID = devices.first?.identifier
                }
                if devices.isEmpty {
                    deviceListError = "没有检测到可安装的 iOS 设备，请用数据线连接并在设备上信任本机"
                }
            case .failure(let error):
                devices = []
                selectedDeviceID = nil
                deviceListError = error.localizedDescription
            }
        }
    }

    // MARK: 安装

    func install() {
        guard let ipaURL, let device = selectedDevice else { return }

        isInstalling = true
        logText = ""

        Task {
            let logger: DeviceInstaller.Logger = { line in
                Task { @MainActor in self.appendLog(line) }
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DeviceInstaller.install(ipaURL: ipaURL, device: device, log: logger)
                }.value
            } catch {
                errorMessage = error.localizedDescription
                alertIsPresented = true
                appendLog("❌ \(error.localizedDescription)")
            }
            isInstalling = false
            // 安装会改变设备的配对/连接状态，顺手刷新一次列表。
            loadDevices()
        }
    }

    func appendLog(_ line: String) {
        logText += line + "\n"
    }
}
