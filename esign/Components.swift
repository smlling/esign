//
//  Components.swift
//  esign
//

import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var ipaFile: UTType { UTType(filenameExtension: "ipa") ?? .data }
    static var mobileProvisionFile: UTType { UTType(filenameExtension: "mobileprovision") ?? .data }
    static var p12File: UTType { UTType(filenameExtension: "p12") ?? .data }
}

/// 可点击选择、也可拖入文件的区域。
struct FileDropZone: View {
    let emptyTitle: String
    let selectedURL: URL?
    /// 接受的文件扩展名（小写，不含点）。
    let fileExtension: String
    let onPick: () -> Void
    let onDrop: (URL) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: selectedURL == nil ? "square.and.arrow.down" : "doc.zipper")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(selectedURL?.lastPathComponent ?? emptyTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if let selectedURL {
                Text(selectedURL.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onPick)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == fileExtension }) else {
                return false
            }
            onDrop(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

struct LogPanel: View {
    let text: String
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("日志")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? emptyText : text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id(Self.bottomID)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
                .frame(minHeight: 180)
                .onChange(of: text) { _, _ in
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
    }

    private static let bottomID = "log-bottom"
}

struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
                .padding(.top, 4)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
