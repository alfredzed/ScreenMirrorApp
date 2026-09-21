import Foundation
import Combine

enum ConnectionMode: String, CaseIterable, Identifiable {
    case usb
    case wifi
    var id: String { rawValue }
    var label: String { self == .usb ? "USB直結" : "Wi-Fi / LAN" }
}

final class StreamViewModel: ObservableObject {
    let client = ScreenStreamClient()
    let usbClient = UsbStreamListener()
    let pixelBufferProvider = PixelBufferProvider()
    private let decoder = H264Decoder()
    private var activeMode: ConnectionMode = .usb

    @Published var connectionState: ConnectionState = .disconnected
    @Published var videoWidth: Int = 0
    @Published var videoHeight: Int = 0

    private var cancellables = Set<AnyCancellable>()

    init() {
        decoder.onDecodedFrame = { [weak self] pixelBuffer, _ in
            self?.pixelBufferProvider.publish(pixelBuffer)
        }
        client.onVideoFramePacket = { [weak self] in self?.decoder.decode(packet: $0) }
        usbClient.onVideoFramePacket = { [weak self] in self?.decoder.decode(packet: $0) }

        client.$connectionState.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard self?.activeMode == .wifi else { return }
            self?.apply(state: state)
        }.store(in: &cancellables)
        usbClient.$connectionState.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard self?.activeMode == .usb else { return }
            self?.apply(state: state)
        }.store(in: &cancellables)

        client.$videoWidth.combineLatest(client.$videoHeight)
            .receive(on: DispatchQueue.main).sink { [weak self] width, height in
                guard self?.activeMode == .wifi else { return }
                self?.videoWidth = width; self?.videoHeight = height
            }.store(in: &cancellables)
        usbClient.$videoWidth.combineLatest(usbClient.$videoHeight)
            .receive(on: DispatchQueue.main).sink { [weak self] width, height in
                guard self?.activeMode == .usb else { return }
                self?.videoWidth = width; self?.videoHeight = height
            }.store(in: &cancellables)
    }

    private func apply(state: ConnectionState) {
        connectionState = state
        if state == .connecting || state == .disconnected { decoder.reset() }
    }

    func connect(mode: ConnectionMode, host: String, port: Int,
                 usbPort: UInt16, aspectRatio: Double, displayMode: String) {
        disconnect()
        activeMode = mode
        if mode == .usb {
            usbClient.start(port: usbPort, aspectRatio: aspectRatio,
                            displayMode: displayMode, deviceName: DeviceInfo.modelName)
        } else {
            client.connect(host: host, port: port, aspectRatio: aspectRatio,
                           displayMode: displayMode, deviceName: DeviceInfo.modelName)
        }
    }

    func disconnect() {
        client.disconnect()
        usbClient.stop()
        decoder.reset()
        connectionState = .disconnected
    }

    func handleTap(x: Double, y: Double) {
        if activeMode == .usb { usbClient.sendTap(x: x, y: y) }
        else { client.sendTap(x: x, y: y) }
    }
    func handleRightTap(x: Double, y: Double) {
        if activeMode == .usb { usbClient.sendRightTap(x: x, y: y) }
        else { client.sendRightTap(x: x, y: y) }
    }
    func handleDrag(phase: String, x: Double, y: Double) {
        if activeMode == .usb { usbClient.sendDrag(phase: phase, x: x, y: y) }
        else { client.sendDrag(phase: phase, x: x, y: y) }
    }
    func handleScroll(dx: Double, dy: Double, phase: String) {
        if activeMode == .usb { usbClient.sendScroll(dx: dx, dy: dy, phase: phase) }
        else { client.sendScroll(dx: dx, dy: dy, phase: phase) }
    }
}

enum DeviceInfo {
    static var modelName: String {
        #if canImport(UIKit)
        return UIDevice.current.name.isEmpty ? "iPad" : UIDevice.current.model
        #else
        return "iPad"
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
