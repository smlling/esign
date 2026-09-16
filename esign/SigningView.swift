//
//  SigningView.swift
//  esign
//

import SwiftUI
import UniformTypeIdentifiers

struct SigningView: View {
    @StateObject private var model = SignerViewModel()
    @State private var showIPAImporter = false
    @State private var showProfileImporter = false
    @State private var showP12Importer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FileDropZone(
                emptyTitle: "拖入 IPA 文件，或点击选择",
                selectedURL: model.ipaURL,
                fileExtension: "ipa",
                onPick: { showIPAImporter = true },
                onDrop: { model.setIPA($0) }
            )

            formSection
            actionRow
            LogPanel(text: model.logText, emptyText: "等待操作…")
        }
        .padding(20)
        .task { model.loadIdentities() }
        .fileImporter(isPresented: $showIPAImporter, allowedContentTypes: [.ipaFile]) { result in
            if case .success(let url) = result { model.setIPA(url) }
        }
        .fileImporter(isPresented: $showProfileImporter, allowedContentTypes: [.mobileProvisionFile]) { result in
            if case .success(let url) = result { model.setProfile(url) }
        }
        .fileImporter(isPresented: $showP12Importer, allowedContentTypes: [.p12File]) { result in
            if case .success(let url) = result { model.p12URL = url }
        }
        .alert("签名失败", isPresented: $model.alertIsPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledRow(title: "Bundle Identifier") {
                TextField("com.example.app（留空则保留原值）", text: $model.bundleIdentifier)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Divider()

            LabeledRow(title: "签名证书") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $model.certificateMode) {
                        ForEach(CertificateMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch model.certificateMode {
                    case .keychain:
                        keychainPicker
                    case .p12:
                        p12Picker
                    }
                }
            }

            Divider()

            LabeledRow(title: "描述文件") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button("选择 .mobileprovision …") { showProfileImporter = true }
                        Text(model.profileURL?.lastPathComponent ?? "未选择")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let info = model.profileInfo {
                        Text(info)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var keychainPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("", selection: $model.selectedIdentityHash) {
                    ForEach(model.identities) { identity in
                        Text(identity.name).tag(Optional(identity.hash))
                    }
                }
                .labelsHidden()
                .disabled(model.identities.isEmpty)

                Button {
                    model.loadIdentities()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新读取钥匙串")
            }
            if let error = model.identityLoadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var p12Picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("选择 .p12 …") { showP12Importer = true }
                Text(model.p12URL?.lastPathComponent ?? "未选择")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Text("密码")
                    .foregroundStyle(.secondary)
                SecureField("P12 密码", text: $model.p12Password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            if model.isSigning {
                ProgressView()
                    .controlSize(.small)
            }
            if let output = model.outputURL {
                Text("已生成 \(output.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("打开输出目录") { model.revealOutput() }
                .disabled(model.outputURL == nil)
            Button("开始签名") { model.sign() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSign)
        }
    }
}

#Preview {
    SigningView()
}
