import Foundation
import Combine
import Network

/// Direct USB transport. Windows iproxy forwards its loopback port to this
/// listener through Apple's USBMux connection; no Wi-Fi or LAN is involved.
final class UsbStreamListener: ObservableObject {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var videoWidth: Int = 0
    @Published private(set) var videoHeight: Int = 0

    var onVideoFramePacket: ((Data) -> Void)?

    private let queue = DispatchQueue(label: "ScreenMirrorApp.USB", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var aspectRatio = 4.0 / 3.0
    private var displayMode = "fit"
    private var deviceName = "iPad"
    private var manuallyClosed = false

    private let kindJSON: UInt8 = 0x01
    private let kindVideo: UInt8 = 0x02
    private let maximumFrameSize = 64 * 1024 * 1024

    func start(port: UInt16, aspectRatio: Double, displayMode: String, deviceName: String) {
        stop()
        self.aspectRatio = aspectRatio
        self.displayMode = displayMode
        self.deviceName = deviceName
        manuallyClosed = false
        publishState(.connecting)

        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                publishState(.disconnected)
                return
            }
            let newListener = try NWListener(using: .tcp, on: nwPort)
            listener = newListener
            newListener.newConnectionHandler = { [weak self] in self?.accept($0) }
            newListener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    print("[USB] listener failed: \(error)")
                    self?.publishState(.disconnected)
                }
            }
            newListener.start(queue: queue)
        } catch {
            print("[USB] listener creation failed: \(error)")
            publishState(.disconnected)
        }
    }

    func stop() {
        manuallyClosed = true
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        publishState(.disconnected)
    }

    private func accept(_ newConnection: NWConnection) {
        connection?.cancel()
        connection = newConnection
        receiveBuffer.removeAll(keepingCapacity: true)
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            switch state {
            case .ready:
                self.sendHandshake(on: newConnection)
                self.receive(on: newConnection)
            case .failed(let error):
                print("[USB] connection failed: \(error)")
                self.connectionEnded(newConnection)
            case .cancelled:
                self.connectionEnded(newConnection)
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func connectionEnded(_ ended: NWConnection) {
        guard connection === ended else { return }
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        if !manuallyClosed { publishState(.connecting) }
    }

    private func receive(on activeConnection: NWConnection) {
        activeConnection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) {
            [weak self, weak activeConnection] data, _, isComplete, error in
            guard let self, let activeConnection else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.consumeFrames()
            }
            if isComplete || error != nil {
                self.connectionEnded(activeConnection)
                return
            }
            self.receive(on: activeConnection)
        }
    }

    private func consumeFrames() {
        while receiveBuffer.count >= 5 {
            let bytes = [UInt8](receiveBuffer.prefix(5))
            let length = Int(bytes[0]) << 24 |
                         Int(bytes[1]) << 16 |
                         Int(bytes[2]) << 8 |
                         Int(bytes[3])
            guard length >= 1, length <= maximumFrameSize else {
                connection?.cancel()
                return
            }
            guard receiveBuffer.count >= 4 + length else { return }
            let frame = receiveBuffer.prefix(4 + length)
            let kind = bytes[4]
            let payload = Data(frame.dropFirst(5))
            receiveBuffer = Data(receiveBuffer.dropFirst(4 + length))

            if kind == kindVideo {
                publishState(.connected)
                onVideoFramePacket?(payload)
            } else if kind == kindJSON {
                handleJSON(payload)
            }
        }
    }

    private func handleJSON(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        if type == "video_info" {
            let width = object["width"] as? Int ?? 0
            let height = object["height"] as? Int ?? 0
            DispatchQueue.main.async {
                self.videoWidth = width
                self.videoHeight = height
                self.connectionState = .connected
            }
        } else if type == "ping", let timestamp = object["t"] {
            sendJSON(["type": "pong", "t": timestamp])
        }
    }

    private func sendHandshake(on _: NWConnection) {
        sendJSON([
            "type": "handshake", "device": deviceName,
            "aspect_ratio": aspectRatio, "display_mode": displayMode,
            "max_fps": 60,
        ])
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

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(kind: kindJSON, payload: data)
    }

    private func send(kind: UInt8, payload: Data) {
        guard let connection else { return }
        let length = UInt32(payload.count + 1)
        var frame = Data([
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff), kind,
        ])
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error { print("[USB] send failed: \(error)") }
        })
    }

    private func publishState(_ state: ConnectionState) {
        DispatchQueue.main.async { self.connectionState = state }
    }
}
