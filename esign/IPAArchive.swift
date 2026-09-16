//
//  IPAArchive.swift
//  esign
//

import Foundation

enum IPAArchiveError: LocalizedError {
    case unzipFailed(ShellResult)
    case zipFailed(ShellResult)
    case applicationNotFound

    var errorDescription: String? {
        switch self {
        case .unzipFailed(let result):
            "解压 IPA 失败（退出码 \(result.exitCode)）\n\(result.combined)"
        case .zipFailed(let result):
            "重新打包 IPA 失败（退出码 \(result.exitCode)）\n\(result.combined)"
        case .applicationNotFound:
            "IPA 文件无效：解压后未在 Payload 目录中找到 .app"
        }
    }
}

/// IPA 本质上是含 `Payload/xxx.app` 的 zip，签名和安装都需要先解压取出这个 .app。
nonisolated enum IPAArchive {
    private nonisolated static var unzipPath: String { "/usr/bin/unzip" }
    private nonisolated static var zipPath: String { "/usr/bin/zip" }

    /// 解压 IPA 到指定目录，返回其中的 .app。
    nonisolated static func extract(_ ipaURL: URL, to directory: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let result = try Shell.run(unzipPath, ["-q", "-o", ipaURL.path, "-d", directory.path])
        guard result.succeeded else {
            throw IPAArchiveError.unzipFailed(result)
        }

        let payloadDirectory = directory.appendingPathComponent("Payload", isDirectory: true)
        guard let application = firstApplication(in: payloadDirectory) else {
            throw IPAArchiveError.applicationNotFound
        }
        return application
    }

    nonisolated static func firstApplication(in payloadDirectory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: payloadDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.first { $0.pathExtension.lowercased() == "app" }
    }

    /// 把解压目录重新打包成 IPA。`-y` 保留符号链接（framework 内部大量使用），
    /// `-X` 避免写入 __MACOSX 之类的额外属性。
    nonisolated static func archive(extractedDirectory: URL, to outputURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        let result = try Shell.run(
            zipPath,
            ["-q", "-r", "-y", "-X", outputURL.path, "Payload"],
            currentDirectory: extractedDirectory
        )
        guard result.succeeded else {
            throw IPAArchiveError.zipFailed(result)
        }
    }

    nonisolated static func signedOutputURL(for ipaURL: URL) -> URL {
        let base = ipaURL.deletingPathExtension().lastPathComponent
        return ipaURL.deletingLastPathComponent().appendingPathComponent("\(base)_signed.ipa")
    }
}
