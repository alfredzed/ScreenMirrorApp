//
//  RemoteScreenView.swift
//  ScreenMirrorApp (iPad client)
//
//  GeometryReaderで得たコンテナサイズと、サーバーから通知された映像解像度(video_info)から
//  「黒帯を除いた実際の映像表示領域」(contentRect)を計算する。
//  この contentRect を映像描画とタッチ座標の正規化の両方で共通利用することで、
//  タッチ位置のズレを防ぐ（README.md 4章）。

import SwiftUI

struct RemoteScreenView: View {
    @ObservedObject var viewModel: StreamViewModel

    private var videoAspectRatio: Double {
        guard viewModel.videoWidth > 0, viewModel.videoHeight > 0 else { return 4.0 / 3.0 }
        return Double(viewModel.videoWidth) / Double(viewModel.videoHeight)
    }

    var body: some View {
        GeometryReader { geo in
            let containerSize = geo.size
            let contentRect = Self.computeContentRect(containerSize: containerSize, aspectRatio: videoAspectRatio)

            ZStack {
                Color.black.ignoresSafeArea()

                PixelBufferDisplayView(pixelBufferProvider: viewModel.pixelBufferProvider)
                    .frame(width: contentRect.width, height: contentRect.height)
                    .position(x: contentRect.midX, y: contentRect.midY)

                // ジェスチャー検出は黒帯を含むコンテナ全面で行い、
                // contentRect外のタッチはGestureRecognizerView内部で無視する。
                GestureRecognizerView(
                    contentRect: contentRect,
                    onTap: { x, y in viewModel.handleTap(x: Double(x), y: Double(y)) },
                    onRightTap: { x, y in viewModel.handleRightTap(x: Double(x), y: Double(y)) },
                    onDrag: { phase, x, y in viewModel.handleDrag(phase: phase, x: Double(x), y: Double(y)) },
                    onScroll: { dx, dy, phase in viewModel.handleScroll(dx: Double(dx), dy: Double(dy), phase: phase) }
                )
                .frame(width: containerSize.width, height: containerSize.height)

                if viewModel.connectionState != .connected {
                    connectionOverlay
                }
            }
        }
    }

    private var connectionOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text(statusText)
                .foregroundColor(.white)
                .font(.subheadline)
        }
        .padding(20)
        .background(.black.opacity(0.6))
        .cornerRadius(12)
    }

    private var statusText: String {
        switch viewModel.connectionState {
        case .disconnected: return "切断されています"
        case .connecting: return "接続中..."
        case .reconnecting(let attempt): return "再接続中... (\(attempt)回目)"
        case .connected: return "接続済み"
        }
    }

    /// コンテナ内で映像を "fit"（アスペクト比を維持して収める）表示したときの
    /// 実コンテンツ矩形（黒帯を除いた領域）を計算する。
    static func computeContentRect(containerSize: CGSize, aspectRatio: Double) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0, aspectRatio > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let containerAspect = containerSize.width / containerSize.height
        let contentWidth: CGFloat
        let contentHeight: CGFloat
        if containerAspect > CGFloat(aspectRatio) {
            contentHeight = containerSize.height
            contentWidth = contentHeight * CGFloat(aspectRatio)
        } else {
            contentWidth = containerSize.width
            contentHeight = contentWidth / CGFloat(aspectRatio)
        }
        let x = (containerSize.width - contentWidth) / 2
        let y = (containerSize.height - contentHeight) / 2
        return CGRect(x: x, y: y, width: contentWidth, height: contentHeight)
    }
}
