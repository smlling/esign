//
//  ContentView.swift
//  esign
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            SigningView()
                .tabItem { Label("签名", systemImage: "signature") }
            InstallView()
                .tabItem { Label("安装", systemImage: "square.and.arrow.down") }
        }
        .frame(minWidth: 680, minHeight: 720)
    }
}

#Preview {
    ContentView()
}
