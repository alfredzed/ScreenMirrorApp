//
//  ScreenMirrorApp.swift
//  ScreenMirrorApp (iPad client)
//
//  アプリのエントリーポイント。Xcodeプロジェクトの @main ファイルとして使用する。
//  無印iPad / iPad Air / iPad miniのいずれでも、ContentView内のGeometryReaderが
//  実機の画面サイズに応じてアスペクト比を動的に計算するため、機種別の分岐は不要。

import SwiftUI

@main
struct ScreenMirrorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
        }
    }
}
