//
//  GestureRecognizerView.swift
//  ScreenMirrorApp (iPad client)
//
//  要件:
//   - 1本指タップ → 左クリック
//   - 2本指タップ → 右クリック
//   - 1本指ドラッグ → マウス移動/ドラッグ (begin/move/end)
//   - 2本指スワイプ → スクロール
//
//  タップ/ドラッグ/スクロールの判定が競合しないよう、UIGestureRecognizerではなく
//  touchesBegan/Moved/Ended/Cancelled を直接オーバーライドして自前で判定する。
//  座標は「黒帯を除いた実映像表示領域」(contentRect, このView自身の座標系)を基準に
//  0.0〜1.0へ正規化してからコールバックへ渡す。

import SwiftUI
import UIKit

struct GestureRecognizerView: UIViewRepresentable {
    /// このView自身の座標系における「黒帯を除いた実映像表示領域」。
    var contentRect: CGRect

    var onTap: (CGFloat, CGFloat) -> Void
    var onRightTap: (CGFloat, CGFloat) -> Void
    var onDrag: (_ phase: String, _ x: CGFloat, _ y: CGFloat) -> Void
    var onScroll: (_ dx: CGFloat, _ dy: CGFloat, _ phase: String) -> Void

    func makeUIView(context: Context) -> TouchHandlingView {
        let view = TouchHandlingView()
        view.contentRect = contentRect
        view.onTap = onTap
        view.onRightTap = onRightTap
        view.onDrag = onDrag
        view.onScroll = onScroll
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: TouchHandlingView, context: Context) {
        uiView.contentRect = contentRect
        uiView.onTap = onTap
        uiView.onRightTap = onRightTap
        uiView.onDrag = onDrag
        uiView.onScroll = onScroll
    }

    final class TouchHandlingView: UIView {
        var contentRect: CGRect = .zero
        var onTap: ((CGFloat, CGFloat) -> Void)?
        var onRightTap: ((CGFloat, CGFloat) -> Void)?
        var onDrag: ((String, CGFloat, CGFloat) -> Void)?
        var onScroll: ((CGFloat, CGFloat, String) -> Void)?

        // タップ判定の閾値
        private let tapMoveTolerance: CGFloat = 8
        private let tapMaxDuration: TimeInterval = 0.35

        // 1本指ドラッグの状態
        private var singleTouch: UITouch?
        private var singleStartPoint: CGPoint = .zero
        private var singleStartTime: TimeInterval = 0
        private var isDragging = false

        // 2本指スクロール/右タップの状態
        private var twoFingerTouches: [UITouch] = []
        private var twoFingerStartCentroid: CGPoint = .zero
        private var twoFingerLastCentroid: CGPoint = .zero
        private var twoFingerMoved = false
        private var scrollActive = false

        // MARK: - 座標正規化

        /// contentRect基準で 0.0〜1.0 に正規化する。範囲外（黒帯上のタッチ）は nil を返す。
        private func normalize(_ point: CGPoint) -> (CGFloat, CGFloat)? {
            guard contentRect.width > 0, contentRect.height > 0 else { return nil }
            let nx = (point.x - contentRect.minX) / contentRect.width
            let ny = (point.y - contentRect.minY) / contentRect.height
            guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }
            return (nx, ny)
        }

        private func centroid(of touches: [UITouch]) -> CGPoint {
            let points = touches.map { $0.location(in: self) }
            let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
        }

        // MARK: - タッチイベント

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let event else { return }
            let allTouches = event.allTouches ?? touches

            if allTouches.count == 1, let touch = allTouches.first {
                singleTouch = touch
                singleStartPoint = touch.location(in: self)
                singleStartTime = touch.timestamp
                isDragging = false
            } else if allTouches.count == 2 {
                // 1本指の処理途中だった場合はドラッグ状態を打ち切る
                if isDragging, let (nx, ny) = normalize(singleTouch?.location(in: self) ?? singleStartPoint) {
                    onDrag?("end", nx, ny)
                }
                singleTouch = nil
                isDragging = false

                twoFingerTouches = Array(allTouches)
                twoFingerStartCentroid = centroid(of: twoFingerTouches)
                twoFingerLastCentroid = twoFingerStartCentroid
                twoFingerMoved = false
                scrollActive = false
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let event else { return }
            let allTouches = event.allTouches ?? touches

            if allTouches.count == 1, let touch = singleTouch {
                let point = touch.location(in: self)
                let distance = hypot(point.x - singleStartPoint.x, point.y - singleStartPoint.y)

                if !isDragging, distance > tapMoveTolerance {
                    isDragging = true
                    if let (nx, ny) = normalize(singleStartPoint) {
                        onDrag?("begin", nx, ny)
                    }
                }
                if isDragging, let (nx, ny) = normalize(point) {
                    onDrag?("move", nx, ny)
                }
            } else if allTouches.count == 2, !twoFingerTouches.isEmpty {
                let current = centroid(of: twoFingerTouches)
                let distance = hypot(current.x - twoFingerStartCentroid.x, current.y - twoFingerStartCentroid.y)
                if distance > tapMoveTolerance {
                    twoFingerMoved = true
                }

                guard contentRect.width > 0, contentRect.height > 0 else { return }
                let dx = (current.x - twoFingerLastCentroid.x) / contentRect.width
                let dy = (current.y - twoFingerLastCentroid.y) / contentRect.height
                twoFingerLastCentroid = current

                if twoFingerMoved {
                    let phase = scrollActive ? "changed" : "began"
                    scrollActive = true
                    onScroll?(dx, dy, phase)
                }
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            let remaining = (event?.allTouches ?? touches).filter { $0.phase != .ended && $0.phase != .cancelled }

            if let touch = singleTouch, touches.contains(touch) {
                let point = touch.location(in: self)
                let duration = touch.timestamp - singleStartTime
                if isDragging {
                    if let (nx, ny) = normalize(point) {
                        onDrag?("end", nx, ny)
                    }
                } else if duration <= tapMaxDuration, let (nx, ny) = normalize(point) {
                    onTap?(nx, ny)
                }
                singleTouch = nil
                isDragging = false
            }

            if !twoFingerTouches.isEmpty, remaining.count < 2 {
                if scrollActive {
                    onScroll?(0, 0, "ended")
                } else if !twoFingerMoved {
                    // 2本指タップ = 右クリック（中心点で送信）
                    if let (nx, ny) = normalize(twoFingerStartCentroid) {
                        onRightTap?(nx, ny)
                    }
                }
                twoFingerTouches = []
                scrollActive = false
                twoFingerMoved = false
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            if isDragging, let touch = singleTouch {
                if let (nx, ny) = normalize(touch.location(in: self)) {
                    onDrag?("end", nx, ny)
                }
            }
            if scrollActive {
                onScroll?(0, 0, "ended")
            }
            singleTouch = nil
            isDragging = false
            twoFingerTouches = []
            scrollActive = false
            twoFingerMoved = false
        }
    }
}
