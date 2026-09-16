//
//  InstallView.swift
//  esign
//

import SwiftUI
import UniformTypeIdentifiers

struct InstallView: View {
    @StateObject private var model = InstallViewModel()
    @State private var showIPAImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FileDropZone(
                emptyTitle: "拖入 IPA 文件，或点击选择",
                selectedURL: model.ipaURL,
                fileExtension: "ipa",
                onPick: { showIPAImporter = true },
                onDrop: { model.setIPA($0) }
            )

            deviceSection
            actionRow
            LogPanel(text: model.logText, emptyText: "等待操作…")
        }
        .padding(20)
        .task { model.loadDevices() }
        .fileImporter(isPresented: $showIPAImporter, allowedContentTypes: [.ipaFile]) { result in
            if case .success(let url) = result { model.setIPA(url) }
        }
        .alert("安装失败", isPresented: $model.alertIsPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var deviceSection: some View {
        LabeledRow(title: "目标设备") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Picker("", selection: $model.selectedDeviceID) {
                        ForEach(model.devices) { device in
                            Text(device.displayName).tag(Optional(device.identifier))
                        }
                    }
                    .labelsHidden()
                    .disabled(model.devices.isEmpty)

                    Button {
                        model.loadDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("重新扫描设备")
                    .disabled(model.isLoadingDevices)
                }

                if model.isLoadingDevices {
                    Text("正在扫描设备…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let device = model.selectedDevice {
                    Text(device.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !device.isConnected {
                        Label(
                            "该设备当前未连接，请用数据线连接并在设备上信任本机",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                } else if let error = model.deviceListError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            if model.isInstalling {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button("开始安装") { model.install() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canInstall)
        }
    }
}

#Preview {
    InstallView()
}
