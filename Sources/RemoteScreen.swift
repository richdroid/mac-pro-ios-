import CoreGraphics
import Foundation
import SwiftUI

// A native Screen Sharing client. The dashboard's bridge signs in to the Mac, so this side speaks plain RFB over
// a WebSocket with no login of its own. Raw encoding keeps it simple; only changed areas are sent after the first frame.
@MainActor
final class RemoteScreen: ObservableObject {
    enum Phase: Equatable { case idle, connecting, connected, needsLogin, failed(String) }
    @Published var phase = Phase.idle
    @Published var image: CGImage?
    @Published var size = CGSize.zero

    private var socket: URLSessionWebSocketTask?
    private var buffer = Data()
    private var frame = Data()
    private var width = 0, height = 0
    private var buttons: UInt8 = 0
    private var lastPublish = Date.distantPast
    private var running = false
    private enum Stage { case version, security, result, serverInit, messages }
    private var stage = Stage.version

    func connect(base: URL) {
        disconnect()
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.path = "/novnc/ws/vnc"
        guard let url = parts.url else { return }
        var request = URLRequest(url: url)
        request.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 32 << 20
        socket = task
        buffer = Data(); stage = .version; running = true; phase = .connecting
        task.resume()
        Task { await receiveLoop(task, base: base) }
    }

    func disconnect() {
        running = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        if phase != .needsLogin { phase = .idle }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, base: URL) async {
        while running, socket === task {
            do {
                switch try await task.receive() {
                case .data(let d): buffer.append(d)
                case .string(let s): buffer.append(Data(s.utf8))
                @unknown default: break
                }
                try parse()
            } catch {
                guard running, socket === task else { return }
                let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
                phase = code == 409 ? .needsLogin : .failed("The screen connection dropped.")
                running = false
                return
            }
        }
    }

    private func take(_ n: Int) -> Data? {
        guard buffer.count >= n else { return nil }
        let out = Data(buffer.prefix(n))
        buffer = Data(buffer.dropFirst(n))
        return out
    }
    private func send(_ bytes: [UInt8]) { socket?.send(.data(Data(bytes))) { _ in } }
    private func be16(_ d: Data, _ i: Int) -> Int { Int(d[d.startIndex + i]) << 8 | Int(d[d.startIndex + i + 1]) }
    private func be32(_ d: Data, _ i: Int) -> Int { be16(d, i) << 16 | be16(d, i + 2) }

    private func parse() throws {
        while true {
            switch stage {
            case .version:
                guard take(12) != nil else { return }
                socket?.send(.data(Data("RFB 003.008\n".utf8))) { _ in }
                stage = .security
            case .security:
                guard let head = buffer.first, buffer.count >= 1 + Int(head), take(1 + Int(head)) != nil else { return }
                send([1])
                stage = .result
            case .result:
                guard let r = take(4) else { return }
                if be32(r, 0) != 0 { phase = .failed("Screen Sharing refused the connection."); running = false; return }
                send([1])
                stage = .serverInit
            case .serverInit:
                guard buffer.count >= 24 else { return }
                let nameLength = be32(buffer, 20)
                guard let head = take(24 + nameLength) else { return }
                width = be16(head, 0); height = be16(head, 2)
                frame = Data(count: width * height * 4)
                size = CGSize(width: width, height: height)
                // 32-bit little-endian BGRA, then raw rectangles only.
                send([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
                send([2, 0, 0, 1, 0, 0, 0, 0])
                request(incremental: false)
                stage = .messages
                phase = .connected
            case .messages:
                guard let type = buffer.first else { return }
                switch type {
                case 0: if try !readUpdate() { return }
                case 1:
                    guard buffer.count >= 6 else { return }
                    let n = be16(buffer, 4)
                    guard take(6 + n * 6) != nil else { return }
                case 2: _ = take(1)
                case 3:
                    guard buffer.count >= 8 else { return }
                    guard take(8 + be32(buffer, 4)) != nil else { return }
                default: buffer = Data(); return
                }
            }
        }
    }

    private func readUpdate() throws -> Bool {
        guard buffer.count >= 4 else { return false }
        let count = be16(buffer, 2)
        var at = 4
        for _ in 0..<count {
            guard buffer.count >= at + 12 else { return false }
            let w = be16(buffer, at + 4), h = be16(buffer, at + 6)
            guard be32(buffer, at + 8) == 0 else { phase = .failed("Unexpected screen data."); running = false; return false }
            at += 12 + w * h * 4
            guard buffer.count >= at else { return false }
        }
        var read = 4
        for _ in 0..<count {
            let x = be16(buffer, read), y = be16(buffer, read + 2), w = be16(buffer, read + 4), h = be16(buffer, read + 6)
            read += 12
            let start = buffer.startIndex + read
            frame.withUnsafeMutableBytes { dst in
                buffer.withUnsafeBytes { src in
                    for row in 0..<h where y + row < height && x + w <= width {
                        memcpy(dst.baseAddress! + ((y + row) * width + x) * 4, src.baseAddress! + (start - buffer.startIndex) + row * w * 4, w * 4)
                    }
                }
            }
            read += w * h * 4
        }
        buffer = Data(buffer.dropFirst(read))
        publish()
        request(incremental: true)
        return true
    }

    private func publish() {
        guard Date().timeIntervalSince(lastPublish) > 0.08, let provider = CGDataProvider(data: frame as CFData) else { return }
        lastPublish = Date()
        image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func request(incremental: Bool) {
        send([3, incremental ? 1 : 0, 0, 0, 0, 0, UInt8(width >> 8), UInt8(width & 255), UInt8(height >> 8), UInt8(height & 255)])
    }

    // MARK: Input
    func pointer(x: Int, y: Int, buttons mask: UInt8) {
        buttons = mask
        send([5, mask, UInt8((x >> 8) & 255), UInt8(x & 255), UInt8((y >> 8) & 255), UInt8(y & 255)])
    }
    func click(x: Int, y: Int, right: Bool = false) {
        let mask: UInt8 = right ? 4 : 1
        pointer(x: x, y: y, buttons: 0); pointer(x: x, y: y, buttons: mask); pointer(x: x, y: y, buttons: 0)
    }
    func scroll(x: Int, y: Int, up: Bool) {
        let mask: UInt8 = up ? 8 : 16
        pointer(x: x, y: y, buttons: mask); pointer(x: x, y: y, buttons: 0)
    }
    func key(_ sym: UInt32) {
        for down: UInt8 in [1, 0] {
            send([4, down, 0, 0, UInt8((sym >> 24) & 255), UInt8((sym >> 16) & 255), UInt8((sym >> 8) & 255), UInt8(sym & 255)])
        }
    }
    func type(_ text: String) {
        for scalar in text.unicodeScalars { key(scalar.value < 256 ? scalar.value : 0x0100_0000 | scalar.value) }
    }
}

struct RemoteScreenView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var screen = RemoteScreen()
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var panBase = CGSize.zero
    @State private var rightClick = false
    @State private var typing = false
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color.black
                    if let image = screen.image {
                        let fit = min(geo.size.width / screen.size.width, geo.size.height / screen.size.height)
                        let drawn = CGSize(width: screen.size.width * fit, height: screen.size.height * fit)
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: drawn.width, height: drawn.height)
                            .contentShape(Rectangle())
                            .onTapGesture { p in
                                screen.click(x: Int(p.x / fit), y: Int(p.y / fit), right: rightClick)
                                rightClick = false
                            }
                            .scaleEffect(zoom)
                            .offset(pan)
                            .gesture(MagnificationGesture()
                                .onChanged { zoom = max(1, min(6, zoomBase * $0)) }
                                .onEnded { _ in zoomBase = zoom; if zoom == 1 { pan = .zero; panBase = .zero } })
                            .simultaneousGesture(DragGesture(minimumDistance: 12)
                                .onChanged { v in
                                    guard zoom > 1 else { return }
                                    pan = CGSize(width: panBase.width + v.translation.width, height: panBase.height + v.translation.height)
                                }
                                .onEnded { v in
                                    if zoom > 1 { panBase = pan }
                                    else if abs(v.translation.height) > 20 {
                                        screen.scroll(x: Int(v.startLocation.x / fit), y: Int(v.startLocation.y / fit), up: v.translation.height > 0)
                                    }
                                })
                    }
                    status
                }
                .clipped()
            }
            toolbar
        }
        .navigationTitle("Screen")
        .onAppear { screen.connect(base: model.api.base) }
        .onDisappear { screen.disconnect() }
        .alert("Type on Mac", isPresented: $typing) {
            TextField("Text", text: $text)
            Button("Send") { screen.type(text); text = "" }
            Button("Send + Return") { screen.type(text); screen.key(0xff0d); text = "" }
            Button("Cancel", role: .cancel) { text = "" }
        }
    }

    @ViewBuilder private var status: some View {
        switch screen.phase {
        case .connecting: ProgressView("Connecting…").tint(.white).foregroundStyle(.white)
        case .needsLogin: Text("Log in to this Mac on the Control tab first.").foregroundStyle(.white).padding()
        case .failed(let m):
            VStack(spacing: 10) {
                Text(m).foregroundStyle(.white)
                Button("Try Again") { screen.connect(base: model.api.base) }.buttonStyle(.borderedProminent)
            }.padding()
        default: EmptyView()
        }
    }

    private var toolbar: some View {
        HStack {
            Button { typing = true } label: { Label("Type", systemImage: "keyboard") }
            Spacer()
            Button { screen.key(0xff0d) } label: { Label("Return", systemImage: "return") }
            Spacer()
            Button { screen.key(0xff1b) } label: { Label("Esc", systemImage: "escape") }
            Spacer()
            Button { rightClick.toggle() } label: { Label("Right-click", systemImage: rightClick ? "cursorarrow.rays" : "cursorarrow") }
            Spacer()
            Button { zoom = 1; zoomBase = 1; pan = .zero; panBase = .zero } label: { Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left") }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 22).padding(.vertical, 12)
    }
}
