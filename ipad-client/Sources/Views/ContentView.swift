import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = StreamViewModel()
    @State private var connectionMode: ConnectionMode = .usb
    @State private var host = ""
    @State private var portText = "8765"
    @State private var usbPortText = "27183"
    @State private var displayMode = "fit"
    @State private var didAttemptConnect = false

    var body: some View {
        GeometryReader { geo in
            if didAttemptConnect {
                RemoteScreenView(viewModel: viewModel)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            viewModel.disconnect()
                            didAttemptConnect = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white, .black.opacity(0.4))
                                .padding()
                        }
                    }
            } else {
                connectionForm(containerSize: geo.size)
            }
        }
        .ignoresSafeArea()
    }

    private func connectionForm(containerSize: CGSize) -> some View {
        VStack(spacing: 16) {
            Text("ScreenMirror Touch Display")
                .font(.largeTitle.bold())

            Form {
                Section("接続方式") {
                    Picker("接続方式", selection: $connectionMode) {
                        ForEach(ConnectionMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if connectionMode == .usb {
                    Section("USB直結") {
                        TextField("USBポート", text: $usbPortText)
                            .keyboardType(.numberPad)
                        Text("iPadをUSBで接続して信頼し、WindowsサーバーをUSBモードで起動してください。Wi-Fiは不要です。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("接続先 (Windows PC)") {
                        TextField("IPアドレス（例: 192.168.1.10）", text: $host)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        TextField("ポート", text: $portText)
                            .keyboardType(.numberPad)
                    }
                }

                Section("表示モード") {
                    Picker("表示モード", selection: $displayMode) {
                        Text("フィット（黒帯あり）").tag("fit")
                        Text("フィル（全面表示）").tag("fill")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .frame(maxHeight: 360)

            Button { connect(containerSize: containerSize) } label: {
                Text(connectionMode == .usb ? "USB接続を待ち受ける" : "接続する")
                    .frame(maxWidth: .infinity).padding()
            }
            .buttonStyle(.borderedProminent)
            .disabled(connectionMode == .wifi && host.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.horizontal)
        }
        .padding()
    }

    private func connect(containerSize: CGSize) {
        let aspectRatio = containerSize.height > 0
            ? Double(containerSize.width / containerSize.height) : 4.0 / 3.0
        viewModel.connect(
            mode: connectionMode,
            host: host.trimmingCharacters(in: .whitespaces),
            port: Int(portText) ?? 8765,
            usbPort: UInt16(usbPortText) ?? 27183,
            aspectRatio: aspectRatio,
            displayMode: displayMode
        )
        didAttemptConnect = true
    }
}
