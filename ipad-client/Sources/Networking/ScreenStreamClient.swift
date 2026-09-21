//
//  ScreenStreamClient.swift
//  ScreenMirrorApp (iPad client)
//
//  README.md の接続シーケンス/データフォーマットに準拠したWebSocketクライアント。
//  - 接続直後に handshake を送信
//  - video_info / 映像バイナリフレーム / ping・pong を受信
//  - gesture / drag / scroll を送信
//  - 切断検知時は指数バックオフ(1s→2s→4s→最大10s)で自動再接続

import Foundation
import Combine

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
}

final class ScreenStreamClient: NSObject, ObservableObject {

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var videoWidth: Int = 0
    @Published private(set) var videoHeight: Int = 0

    /// デコード前の生バイナリフレームを渡す。呼び出し元(ViewModel)がH264Decoderへ橋渡しする。
    var onVideoFramePacket: ((Data) -> Void)?

    private var host: String = ""
    private var port: Int = 8765
    private var handshakeAspectRatio: Double = 4.0 / 3.0
    private var handshakeDisplayMode: String = "fit"
    private var handshakeDeviceName: String = "iPad"

    private var urlSession: URLSession!
    private var task: URLSessionWebSocketTask?

    private var reconnectAttempt = 0
    private let maxBackoffSeconds: TimeInterval = 10
    private var reconnectWorkItem: DispatchWorkItem?
    private var pingTimer: Timer?
    private var awaitingPongSince: Date?
    private var missedPongCount = 0
    private var manuallyClosed = false

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - 接続管理

    func connect(host: String, port: Int, aspectRatio: Double, displayMode: String, deviceName: String) {
        self.host = host
        self.port = port
        self.handshakeAspectRatio = aspectRatio
        self.handshakeDisplayMode = displayMode
        self.handshakeDeviceName = deviceName
        manuallyClosed = false
        reconnectAttempt = 0
        openSocket()
    }

    func disconnect() {
        manuallyClosed = true
        reconnectWorkItem?.cancel()
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectionState = .disconnected
    }

    private func openSocket() {
        guard !host.isEmpty else { return }
        connectionState = reconnectAttempt == 0 ? .connecting : .reconnecting(attempt: reconnectAttempt)

        guard let url = URL(string: "ws://\(host):\(port)/stream") else { return }
        let newTask = urlSession.webSocketTask(with: url)
        task = newTask
        newTask.resume()

        sendHandshake()
        listen()
        startPingTimer()
    }

    private func scheduleReconnect() {
        guard !manuallyClosed else { return }
        pingTimer?.invalidate()
        task = nil
        connectionState = .disconnected

        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), maxBackoffSeconds)

        let workItem = DispatchWorkItem { [weak self] in
            self?.openSocket()
        }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - 送信

    private func sendHandshake() {
        let payload: [String: Any] = [
            "type": "handshake",
            "device": handshakeDeviceName,
            "aspect_ratio": handshakeAspectRatio,
            "display_mode": handshakeDisplayMode,
            "max_fps": 60,
        ]
        sendJSON(payload)
    }

    func sendTap(x: Double, y: Double) {
        sendJSON(["type": "gesture", "gesture": "tap", "x": x, "y": y])
    }

    func sendRightTap(x: Double, y: Double) {
        sendJSON(["type": "gesture", "gesture": "right_tap", "x": x, "y": y])
    }

    func sendDrag(phase: String, x: Double, y: Double) {
        sendJSON(["type": "drag", "phase": phase, "x": x, "y": y])
    }

    func sendScroll(dx: Double, dy: Double, phase: String) {
        sendJSON(["type": "scroll", "dx": dx, "dy": dy, "phase": phase])
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard let task, connectionState == .connected || payload["type"] as? String == "handshake" else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if error != nil {
                self?.scheduleReconnect()
            }
        }
    }

    // MARK: - 受信

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.scheduleReconnect()
                return
            case .success(let message):
                self.handleMessage(message)
                self.listen() // 継続受信
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            // README 3.2: バイナリフレーム = 1バイトヘッダー + H.264 Annex-Bデータ
            DispatchQueue.main.async {
                if self.connectionState != .connected {
                    self.connectionState = .connected
                    self.reconnectAttempt = 0
                }
            }
            onVideoFramePacket?(data)
        case .string(let text):
            handleJSON(text)
        @unknown default:
            break
        }
    }

    private func handleJSON(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "video_info":
            let w = obj["width"] as? Int ?? 0
            let h = obj["height"] as? Int ?? 0
            DispatchQueue.main.async {
                self.videoWidth = w
                self.videoHeight = h
                self.connectionState = .connected
                self.reconnectAttempt = 0
            }
        case "pong":
            missedPongCount = 0
            awaitingPongSince = nil
        case "ping":
            if let t = obj["t"] {
                sendJSON(["type": "pong", "t": t])
            }
        default:
            break
        }
    }

    // MARK: - 死活監視 (README 3.1-f)

    private func startPingTimer() {
        pingTimer?.invalidate()
        missedPongCount = 0
        pingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sendPingAndCheckLiveness()
        }
    }

    private func sendPingAndCheckLiveness() {
        if awaitingPongSince != nil {
            missedPongCount += 1
            if missedPongCount >= 3 {
                // 3回連続で応答なし → ソケットを破棄し再接続シーケンスへ
                task?.cancel(with: .abnormalClosure, reason: nil)
                scheduleReconnect()
                return
            }
        }
        awaitingPongSince = Date()
        sendJSON(["type": "ping", "t": Int(Date().timeIntervalSince1970 * 1000)])
    }
}

extension ScreenStreamClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        scheduleReconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            scheduleReconnect()
        }
    }
}
