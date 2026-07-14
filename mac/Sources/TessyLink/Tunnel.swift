import Foundation

/// Optional Cloudflare quick-tunnel. Gives the local server a public HTTPS URL
/// so the Tesla browser (which cannot reach LAN/private IPs) can load it.
/// Requires `cloudflared` to be installed (`brew install cloudflared`).
final class Tunnel {

    private var process: Process?
    private var reported = false
    /// Called on a background thread the first time the public URL is discovered.
    var onURL: ((String) -> Void)?

    var isAvailable: Bool { Self.binaryPath != nil }

    private static var binaryPath: String? {
        ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(localPort: UInt16) {
        guard let path = Self.binaryPath else {
            NSLog("[TessyLink] cloudflared not installed; public tunnel unavailable.")
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["tunnel", "--url", "http://localhost:\(localPort)", "--no-autoupdate"]
        let pipe = Pipe()
        proc.standardError = pipe
        proc.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            if let url = Self.extractURL(str), self?.reported == false {
                self?.reported = true
                self?.onURL?(url)
            }
        }
        do {
            try proc.run()
            process = proc
            NSLog("[TessyLink] cloudflared tunnel starting…")
        } catch {
            NSLog("[TessyLink] tunnel launch failed: \(error)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        reported = false
    }

    private static func extractURL(_ s: String) -> String? {
        guard let range = s.range(of: #"https://[a-zA-Z0-9.-]+\.trycloudflare\.com"#,
                                  options: .regularExpression) else { return nil }
        return String(s[range])
    }
}
