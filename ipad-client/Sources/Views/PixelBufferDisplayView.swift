//
//  PixelBufferDisplayView.swift
//  ScreenMirrorApp (iPad client)
//
//  VTDecompressionSessionが出力したCVPixelBufferを、共有CIContext(Metalバックエンド)で
//  CGImageに変換し、CALayer.contentsへ直接設定する。SwiftUIの再描画コストを避けるため、
//  Viewの状態(@State/@Published)を経由せず、Coordinatorが直接レイヤーを更新する。

import SwiftUI
import CoreImage
import UIKit

final class PixelBufferLayerView: UIView {
    private static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])
    private let renderQueue = DispatchQueue(label: "ScreenMirrorApp.Display", qos: .userInteractive)
    private let stateLock = NSLock()
    private var pendingBuffer: CVPixelBuffer?
    private var rendering = false

    override class var layerClass: AnyClass { CALayer.self }

    func update(with pixelBuffer: CVPixelBuffer) {
        stateLock.lock()
        pendingBuffer = pixelBuffer
        let shouldStart = !rendering
        rendering = true
        stateLock.unlock()
        guard shouldStart else { return }

        renderQueue.async { [weak self] in
            while let self {
                self.stateLock.lock()
                guard let buffer = self.pendingBuffer else {
                    self.rendering = false
                    self.stateLock.unlock()
                    return
                }
                self.pendingBuffer = nil
                self.stateLock.unlock()

                let ciImage = CIImage(cvPixelBuffer: buffer)
                guard let cgImage = Self.sharedContext.createCGImage(ciImage, from: ciImage.extent) else {
                    continue
                }
                DispatchQueue.main.async { [weak self] in self?.layer.contents = cgImage }
            }
        }
    }
}

struct PixelBufferDisplayView: UIViewRepresentable {
    /// フレームが更新されるたびに新しい参照が渡ってくることを想定。
    let pixelBufferProvider: PixelBufferProvider

    func makeUIView(context: Context) -> PixelBufferLayerView {
        let view = PixelBufferLayerView()
        view.contentMode = .scaleToFill
        view.layer.contentsGravity = .resize
        pixelBufferProvider.onFrame = { [weak view] pixelBuffer in
            view?.update(with: pixelBuffer)
        }
        return view
    }

    func updateUIView(_ uiView: PixelBufferLayerView, context: Context) {
        // フレーム配信はクロージャ経由(pixelBufferProvider.onFrame)で行うため、
        // ここではSwiftUI側のレイアウト変更(サイズ変更)以外に特別な処理は不要。
    }
}

/// H264Decoderの出力(高頻度)をSwiftUIの状態管理から切り離して受け渡すための橋渡し役。
final class PixelBufferProvider {
    var onFrame: ((CVPixelBuffer) -> Void)?

    func publish(_ pixelBuffer: CVPixelBuffer) {
        onFrame?(pixelBuffer)
    }
}
