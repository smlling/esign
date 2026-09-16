//
//  Shell.swift
//  esign
//

import Foundation

nonisolated struct ShellResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }

    var combined: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

nonisolated final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// 把管道里到达的字节按换行切成整行再回调，避免日志里出现半行。
/// `\r` 也当作换行，因为进度指示器是靠回车刷新同一行的。
nonisolated final class LineEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let handler: @Sendable (String) -> Void

    init(handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }

    func consume(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        buffer.append(data)
        while let terminator = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<terminator]
            buffer.removeSubrange(buffer.startIndex...terminator)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        lock.unlock()
        emit(lines)
    }

    func flush() {
        lock.lock()
        let remaining = buffer
        buffer.removeAll()
        lock.unlock()
        emit(remaining.isEmpty ? [] : [String(decoding: remaining, as: UTF8.self)])
    }

    private func emit(_ lines: [String]) {
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            handler(line)
        }
    }
}

enum Shell {
    @discardableResult
    nonisolated static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> ShellResult {
        let process = makeProcess(executable, arguments, currentDirectory: currentDirectory)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // 必须并发读取两个管道，否则任一管道写满缓冲区时子进程会阻塞。
        let stdoutCollector = OutputCollector()
        let stderrCollector = OutputCollector()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutCollector.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrCollector.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        group.wait()
        process.waitUntilExit()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutCollector.data, as: UTF8.self),
            stderr: String(decoding: stderrCollector.data, as: UTF8.self)
        )
    }

    /// 与 `run` 相同，但把子进程输出按行实时回调，用于耗时较长的命令。
    @discardableResult
    nonisolated static func runStreaming(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        lineHandler: @escaping @Sendable (String) -> Void
    ) throws -> ShellResult {
        let process = makeProcess(executable, arguments, currentDirectory: currentDirectory)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = OutputCollector()
        let stderrCollector = OutputCollector()
        let stdoutEmitter = LineEmitter(handler: lineHandler)
        let stderrEmitter = LineEmitter(handler: lineHandler)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stdoutCollector.append(chunk)
            stdoutEmitter.consume(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrCollector.append(chunk)
            stderrEmitter.consume(chunk)
        }

        try process.run()
        process.waitUntilExit()

        // 收尾：摘掉回调后把管道里剩余字节读干净，避免丢掉最后几行。
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        stdoutCollector.append(stdoutTail)
        stderrCollector.append(stderrTail)
        stdoutEmitter.consume(stdoutTail)
        stderrEmitter.consume(stderrTail)
        stdoutEmitter.flush()
        stderrEmitter.flush()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutCollector.data, as: UTF8.self),
            stderr: String(decoding: stderrCollector.data, as: UTF8.self)
        )
    }

    // MARK: 进程构造

    private nonisolated static func makeProcess(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL?
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.environment = environmentWithUTF8Locale()
        return process
    }

    /// GUI 启动的 app 不继承终端的 locale，子进程会退回 ASCII，
    /// 把 devicectl 输出里的 `•` 之类字符换成 `?`。这里补一个 UTF-8 locale。
    private nonisolated static func environmentWithUTF8Locale() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let effective = (environment["LC_ALL"]
            ?? environment["LC_CTYPE"]
            ?? environment["LANG"]
            ?? "").lowercased()
        if !(effective.contains("utf-8") || effective.contains("utf8")) {
            environment["LC_ALL"] = "en_US.UTF-8"
        }
        return environment
    }
}
