//
//  SignerViewModel.swift
//  esign
//

import AppKit
import Combine
import Foundation

@MainActor
final class SignerViewModel: ObservableObject {
    @Published var ipaURL: URL?
    @Published var bundleIdentifier: String = ""

    @Published var certificateMode: CertificateMode = .keychain
    @Published var identities: [SigningIdentity] = []
    @Published var selectedIdentityHash: String?
    @Published var isLoadingIdentities = false
    @Published var identityLoadError: String?

    @Published var p12URL: URL?
    @Published var p12Password: String = ""

    @Published var profileURL: URL?
    @Published var profileInfo: String?

    @Published var logText: String = ""
    @Published var isSigning = false
    @Published var errorMessage: String?
    @Published var alertIsPresented = false
    @Published var outputURL: URL?

    var canSign: Bool {
        guard ipaURL != nil, profileURL != nil, !isSigning else { return false }
        switch certificateMode {
        case .keychain:
            return selectedIdentityHash != nil
        case .p12:
            return p12URL != nil && !p12Password.isEmpty
        }
    }

    // MARK: 文件选择

    func setIPA(_ url: URL) {
        ipaURL = url
        outputURL = nil
        appendLog("已选择 IPA：\(url.path)")
    }

    func setProfile(_ url: URL) {
        profileURL = url
        profileInfo = nil
        appendLog("已选择描述文件：\(url.lastPathComponent)")
        Task {
            let summary = await Task.detached {
                try? IPASigner.profileSummary(for: url)
            }.value
            guard profileURL == url else { return }
            profileInfo = summary
        }
    }

    // MARK: 证书

    func loadIdentities() {
        isLoadingIdentities = true
        identityLoadError = nil
        Task {
            let result = await Task.detached { () -> Result<[SigningIdentity], Error> in
                do {
                    return .success(try IPASigner.availableIdentities())
                } catch {
                    return .failure(error)
                }
            }.value
            isLoadingIdentities = false
            switch result {
            case .success(let identities):
                self.identities = identities
                if selectedIdentityHash == nil || !identities.contains(where: { $0.hash == selectedIdentityHash }) {
                    selectedIdentityHash = identities.first?.hash
                }
                if identities.isEmpty {
                    identityLoadError = "钥匙串中没有可用于代码签名的证书"
                }
            case .failure(let error):
                identities = []
                identityLoadError = error.localizedDescription
            }
        }
    }

    // MARK: 签名

    func sign() {
        guard let ipaURL, let profileURL else { return }

        let certificate: CertificateSource
        switch certificateMode {
        case .keychain:
            guard let hash = selectedIdentityHash else { return }
            certificate = .keychain(identityHash: hash)
        case .p12:
            guard let p12URL else { return }
            certificate = .p12(url: p12URL, password: p12Password)
        }

        let request = SigningRequest(
            ipaURL: ipaURL,
            bundleIdentifier: bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
            certificate: certificate,
            provisioningProfileURL: profileURL
        )

        isSigning = true
        outputURL = nil
        logText = ""

        Task {
            let logger: IPASigner.Logger = { line in
                Task { @MainActor in self.appendLog(line) }
            }
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try IPASigner.sign(request: request, log: logger)
                }.value
                outputURL = output
            } catch {
                errorMessage = error.localizedDescription
                alertIsPresented = true
                appendLog("❌ \(error.localizedDescription)")
            }
            isSigning = false
        }
    }

    func revealOutput() {
        guard let outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    func appendLog(_ line: String) {
        logText += line + "\n"
    }
}
