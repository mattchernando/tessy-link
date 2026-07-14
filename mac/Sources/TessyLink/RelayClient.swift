import Foundation

/// Connects the Mac to the relay as "host": registers a pairing code, streams
/// binary frames out, receives input events back, and negotiates the video
/// format with viewers (H.264 when supported, else MJPEG).
final class RelayClient: NSObject, URLSessionWebSocketDelegate {

    private let urlString: String
    private let code: String
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var stopped = false
    private var connected = false
    private var inFlight = false

    private static let inputTypes: Set<String> = ["down", "move", "up", "click", "scroll"]

    var onInput: (([String: Any]) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Called when a viewer joins, with whether it supports H.264/WebCodecs.
    var onViewerJoined: ((Bool) -> Void)?

    init(urlString: String, code: String) {
        self.urlString = urlString
        self.code = code
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func start() {
        guard let url = URL(string: urlString), url.scheme == "ws" || url.scheme == "wss" else {
            onStatus?("Invalid relay URL (need ws:// or wss://)"); return
        }
        stopped = false
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        let hello: [String: Any] = ["role": "host", "code": code]
        if let data = try? JSONSerialization.data(withJSONObject: hello),
           let text = String(data: data, encoding: .utf8) {
            task.send(.string(text)) { _ in }
        }
        receiveLoop()
    }

    func stop() {
        stopped = true
        connected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func sendText(_ text: String) { task?.send(.string(text)) { _ in } }

    func send(frame: Data) {
        guard connected, !inFlight, let task = task else { return }
        inFlight = true
        task.send(.data(frame)) { [weak self] _ in self?.inFlight = false }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.connected = false
                if !self.stopped {
                    self.onStatus?("Relay disconnected — retrying…")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, !self.stopped else { return }
                        self.start()
                    }
                }
            case .success(let message):
                if case let .string(text) = message,
                   let data = text.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = obj["type"] as? String {
                    if RelayClient.inputTypes.contains(type) {
                        self.onInput?(obj)
                    } else {
                        self.handleControl(type, obj)
                    }
                }
                self.receiveLoop()
            }
        }
    }

    private func handleControl(_ type: String, _ obj: [String: Any]) {
        switch type {
        case "ready":
            connected = true
            onStatus?("Connected to relay — waiting for Tesla")
        case "viewer-joined":
            let h264 = obj["h264"] as? Bool ?? false
            onStatus?("Tesla connected (\(h264 ? "H.264" : "MJPEG"))")
            onViewerJoined?(h264)
        case "viewer-left":
            onStatus?("Tesla disconnected")
        case "downgrade":
            onStatus?("Tesla needs MJPEG")
            onViewerJoined?(false)
        case "error":
            onStatus?("Relay rejected the code (already in use?)")
        default:
            break
        }
    }
}
