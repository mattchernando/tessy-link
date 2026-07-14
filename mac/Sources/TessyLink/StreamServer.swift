import Foundation
import Network
import CommonCrypto

/// A tiny, dependency-free HTTP server built on Network.framework.
/// Serves three things:
///   GET  /         -> the receiver web page (index.html)
///   GET  /stream   -> an MJPEG (multipart/x-mixed-replace) video stream
///   GET  /ws       -> a WebSocket carrying JSON input/control events
final class StreamServer {

    private let port: UInt16
    private let html: Data
    private let queue = DispatchQueue(label: "com.tessylink.server")
    private var listener: NWListener?

    private let boundary = "tessylinkframe"
    private var mjpegClients: [ObjectIdentifier: NWConnection] = [:]

    /// Called (on the server queue) with each decoded input event JSON object.
    var onInput: (([String: Any]) -> Void)?

    init(port: UInt16, html: Data) {
        self.port = port
        self.html = html
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "TessyLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad port"])
        }
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state { NSLog("[TessyLink] listener failed: \(err)") }
        }
        listener.start(queue: queue)
        self.listener = listener
        NSLog("[TessyLink] HTTP server listening on \(port).")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, c) in mjpegClients { c.cancel() }
        mjpegClients.removeAll()
    }

    /// Push a JPEG frame to every connected MJPEG client.
    func broadcast(jpeg: Data) {
        queue.async {
            guard !self.mjpegClients.isEmpty else { return }
            var part = Data()
            part.append("--\(self.boundary)\r\n".data(using: .utf8)!)
            part.append("Content-Type: image/jpeg\r\n".data(using: .utf8)!)
            part.append("Content-Length: \(jpeg.count)\r\n\r\n".data(using: .utf8)!)
            part.append(jpeg)
            part.append("\r\n".data(using: .utf8)!)
            for (id, conn) in self.mjpegClients {
                conn.send(content: part, completion: .contentProcessed { error in
                    if error != nil {
                        self.queue.async { self.mjpegClients[id] = nil }
                    }
                })
            }
        }
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveHeader(conn, buffer: Data())
    }

    private func receiveHeader(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error = error { NSLog("[TessyLink] recv error: \(error)"); conn.cancel(); return }
            var buffer = buffer
            if let data = data { buffer.append(data) }

            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                let header = String(decoding: headerData, as: UTF8.self)
                self.route(conn, header: header)
                return
            }
            if isComplete || buffer.count > 1_000_000 { conn.cancel(); return }
            self.receiveHeader(conn, buffer: buffer)
        }
    }

    private func route(_ conn: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { conn.cancel(); return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let path = parts[1]

        let lower = header.lowercased()
        let isWebSocket = lower.contains("upgrade: websocket")

        if isWebSocket {
            self.upgradeWebSocket(conn, header: header)
        } else if path == "/stream" {
            self.startMJPEG(conn)
        } else if path == "/" || path.hasPrefix("/index") {
            self.sendHTML(conn)
        } else {
            self.sendSimple(conn, status: "404 Not Found", body: Data("not found".utf8), close: true)
        }
    }

    private func sendHTML(_ conn: NWConnection) {
        var response = Data()
        response.append("HTTP/1.1 200 OK\r\n".data(using: .utf8)!)
        response.append("Content-Type: text/html; charset=utf-8\r\n".data(using: .utf8)!)
        response.append("Content-Length: \(html.count)\r\n".data(using: .utf8)!)
        response.append("Cache-Control: no-store\r\n\r\n".data(using: .utf8)!)
        response.append(html)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendSimple(_ conn: NWConnection, status: String, body: Data, close: Bool) {
        var response = Data()
        response.append("HTTP/1.1 \(status)\r\n".data(using: .utf8)!)
        response.append("Content-Type: text/plain; charset=utf-8\r\n".data(using: .utf8)!)
        response.append("Content-Length: \(body.count)\r\n\r\n".data(using: .utf8)!)
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in if close { conn.cancel() } })
    }

    private func startMJPEG(_ conn: NWConnection) {
        var head = Data()
        head.append("HTTP/1.1 200 OK\r\n".data(using: .utf8)!)
        head.append("Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n".data(using: .utf8)!)
        head.append("Cache-Control: no-store, no-cache\r\n".data(using: .utf8)!)
        head.append("Connection: close\r\n\r\n".data(using: .utf8)!)
        conn.send(content: head, completion: .contentProcessed { _ in })

        let id = ObjectIdentifier(conn)
        mjpegClients[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.mjpegClients[id] = nil }
            default: break
            }
        }
        NSLog("[TessyLink] MJPEG client connected (\(mjpegClients.count) total).")
    }

    // MARK: - WebSocket

    private func upgradeWebSocket(_ conn: NWConnection, header: String) {
        guard let key = value(of: "sec-websocket-key", in: header) else { conn.cancel(); return }
        let accept = base64(sha1(Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
        var response = Data()
        response.append("HTTP/1.1 101 Switching Protocols\r\n".data(using: .utf8)!)
        response.append("Upgrade: websocket\r\n".data(using: .utf8)!)
        response.append("Connection: Upgrade\r\n".data(using: .utf8)!)
        response.append("Sec-WebSocket-Accept: \(accept)\r\n\r\n".data(using: .utf8)!)
        conn.send(content: response, completion: .contentProcessed { [weak self] err in
            if err == nil { self?.readWebSocket(conn, buffer: Data()) }
            else { conn.cancel() }
        })
        NSLog("[TessyLink] WebSocket client connected.")
    }

    private func readWebSocket(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil { conn.cancel(); return }
            var buffer = buffer
            if let data = data { buffer.append(data) }

            while let (opcode, payload, consumed) = self.decodeFrame(buffer) {
                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + consumed))
                switch opcode {
                case 0x1: // text
                    if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                        self.onInput?(obj)
                    }
                case 0x8: // close
                    conn.cancel(); return
                case 0x9: // ping -> pong
                    conn.send(content: self.encodeFrame(opcode: 0xA, payload: payload), completion: .idempotent)
                default:
                    break
                }
            }

            if isComplete { conn.cancel(); return }
            self.readWebSocket(conn, buffer: buffer)
        }
    }

    /// Decodes one masked client frame. Returns (opcode, payload, bytesConsumed) or nil if incomplete.
    private func decodeFrame(_ data: Data) -> (UInt8, Data, Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        let masked = (bytes[1] & 0x80) != 0
        var len = Int(bytes[1] & 0x7F)
        var offset = 2
        if len == 126 {
            guard bytes.count >= 4 else { return nil }
            len = (Int(bytes[2]) << 8) | Int(bytes[3]); offset = 4
        } else if len == 127 {
            guard bytes.count >= 10 else { return nil }
            len = 0
            for i in 2..<10 { len = (len << 8) | Int(bytes[i]) }
            offset = 10
        }
        var maskKey = [UInt8](repeating: 0, count: 4)
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            maskKey = Array(bytes[offset..<offset + 4]); offset += 4
        }
        guard bytes.count >= offset + len else { return nil }
        var payload = [UInt8](bytes[offset..<offset + len])
        if masked { for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] } }
        return (opcode, Data(payload), offset + len)
    }

    private func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((count >> 8) & 0xFF))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(127)
            for i in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((count >> i) & 0xFF)) }
        }
        frame.append(payload)
        return frame
    }

    // MARK: - Helpers

    private func value(of headerName: String, in header: String) -> String? {
        for line in header.components(separatedBy: "\r\n") {
            let idx = line.firstIndex(of: ":")
            guard let idx else { continue }
            let name = line[line.startIndex..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            if name == headerName {
                return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func sha1(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }

    private func base64(_ data: Data) -> String { data.base64EncodedString() }
}
