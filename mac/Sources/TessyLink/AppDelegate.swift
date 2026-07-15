import AppKit
import CoreGraphics
import CVirtualDisplay

struct Preset { let name: String; let width: Int; let height: Int }
enum Mode: String { case relay; case local }

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let presets: [Preset] = [
        Preset(name: "Auto-fit to screen", width: 1600, height: 1000),
        Preset(name: "Tesla 3/Y · 1920×1200", width: 1920, height: 1200),
        Preset(name: "Tesla S/X (2021+) · 2200×1300", width: 2200, height: 1300),
        Preset(name: "16:9 · 1600×900", width: 1600, height: 900),
        Preset(name: "16:10 · 1280×800", width: 1280, height: 800)
    ]
    private var selectedPreset = 0
    private var autoFit = true
    private var hiDPI = false
    private var inputEnabled = true
    private var jpegQuality: CGFloat = 0.5
    private var fps: Double = 15
    private let port: UInt16 = 8090

    private var mode: Mode = .relay
    private var relayURLString = ""
    private var sessionCode = "00000000"
    private var lastVideoConfig: String?
    private var currentStreamW = 0
    private var currentStreamH = 0

    private var statusItem: NSStatusItem!
    private var virtualDisplay: TLVirtualDisplay?
    private let capturer = Capturer()
    private let input = InputInjector()
    private var server: StreamServer?
    private let tunnel = Tunnel()
    private var publicURL: String?
    private var relay: RelayClient?
    private var statusText = ""
    private var qrWindow: NSWindow?

    private var running: Bool { virtualDisplay != nil || relay != nil || server != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "mode"), let m = Mode(rawValue: saved) { mode = m }
        relayURLString = defaults.string(forKey: "relayURL") ?? "wss://tessylink.hernandomediallc.com/"
        sessionCode = Self.newCode()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "Tessy Link")
        }
        rebuildMenu()
        // Headless autostart for testing: --start <code>
        if let i = CommandLine.arguments.firstIndex(of: "--start"), CommandLine.arguments.count > i + 1 {
            sessionCode = CommandLine.arguments[i + 1]
            startSession()
        }
    }

    private static func newCode() -> String { String(format: "%08d", Int.random(in: 0...99_999_999)) }

    /// Fit an arbitrary width/height into a stream size (aspect preserved, even, capped).
    private func fittedSize(_ vw: Int, _ vh: Int) -> (Int, Int) {
        let maxSide = 1440.0
        let scale = min(1.0, maxSide / Double(max(vw, vh)))
        var w = Int((Double(vw) * scale).rounded())
        var h = Int((Double(vh) * scale).rounded())
        if w % 2 != 0 { w -= 1 }
        if h % 2 != 0 { h -= 1 }
        return (max(320, w), max(240, h))
    }

    // MARK: - Session lifecycle

    private func startSession() {
        if mode == .relay && relayURLString.isEmpty { alert("Set your relay URL first: Mode ▸ Set relay URL…"); return }
        input.enabled = inputEnabled
        capturer.jpegQuality = jpegQuality
        capturer.targetFPS = fps
        capturer.mode = .jpeg
        lastVideoConfig = nil

        switch mode {
        case .relay:
            let relay = RelayClient(urlString: relayURLString, code: sessionCode)
            relay.onInput = { [weak self] event in self?.input.handle(event) }
            relay.onStatus = { [weak self] text in DispatchQueue.main.async { self?.statusText = text; self?.rebuildMenu() } }
            relay.onViewerJoined = { [weak self] h264 in
                guard let self else { return }
                if h264 {
                    self.capturer.mode = .h264
                    if let cfg = self.lastVideoConfig { self.relay?.sendText(cfg) }
                    self.capturer.requestKeyframe()
                } else { self.capturer.mode = .jpeg }
            }
            relay.onViewport = { [weak self] w, h in DispatchQueue.main.async { self?.applyViewport(w, h) } }
            relay.start()
            self.relay = relay
            capturer.onVideoConfig = { [weak self] codec, w, h in
                guard let self else { return }
                let cfg = "{\"type\":\"video-config\",\"codec\":\"\(codec)\",\"w\":\(w),\"h\":\(h)}"
                self.lastVideoConfig = cfg
                self.relay?.sendText(cfg)
            }
            capturer.onFrame = { [weak relay] frame in relay?.send(frame: frame) }

        case .local:
            let server = StreamServer(port: port, html: loadHTML())
            server.onInput = { [weak self] event in self?.input.handle(event) }
            do { try server.start() } catch { alert("Server failed to start: \(error.localizedDescription)") }
            self.server = server
            capturer.onVideoConfig = nil
            capturer.onFrame = { [weak server] frame in
                if frame.first == 0x4A { server?.broadcast(jpeg: Data(frame.dropFirst())) }
            }
            tunnel.onURL = { [weak self] url in DispatchQueue.main.async { self?.publicURL = url; self?.rebuildMenu() } }
            tunnel.start(localPort: port)
        }

        let preset = presets[selectedPreset]
        let (sw, sh) = fittedSize(preset.width, preset.height)
        startDisplayAndCapture(width: sw, height: sh)
        rebuildMenu()
    }

    private func startDisplayAndCapture(width: Int, height: Int) {
        guard let vd = TLVirtualDisplay(width: UInt32(width), height: UInt32(height), hiDPI: hiDPI, name: "Tessy Link Display") else {
            alert("Couldn’t create the virtual display."); return
        }
        virtualDisplay = vd
        input.displayID = vd.displayID
        currentStreamW = width; currentStreamH = height
        capturer.start(displayID: vd.displayID, width: width, height: height)
        capturer.requestKeyframe()
        NSLog("[TessyLink] display+capture at \(width)x\(height) code=\(sessionCode)")
    }

    private func stopDisplayAndCapture() {
        capturer.stop()
        virtualDisplay = nil
        currentStreamW = 0; currentStreamH = 0
    }

    /// Resize the virtual display to match the viewer's screen shape (fill, no bars).
    private func applyViewport(_ vw: Int, _ vh: Int) {
        guard virtualDisplay != nil, mode == .relay, autoFit, vw > 100, vh > 100 else { return }
        let (w, h) = fittedSize(vw, vh)
        if currentStreamW > 0 {
            let cur = Double(currentStreamW) / Double(currentStreamH)
            let neu = Double(w) / Double(h)
            if abs(neu - cur) / cur < 0.03 && abs(w - currentStreamW) < 48 { return }
        }
        lastVideoConfig = nil
        stopDisplayAndCapture()
        startDisplayAndCapture(width: w, height: h)
        statusText = "Fitted \(w)×\(h)"
        rebuildMenu()
    }

    private func stopSession() {
        stopDisplayAndCapture()
        relay?.stop(); relay = nil
        server?.stop(); server = nil
        tunnel.stop()
        publicURL = nil
        statusText = ""
        lastVideoConfig = nil
        closeQRWindow()
        rebuildMenu()
    }

    private func restartIfRunning() { if running { stopSession(); startSession() } }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        let sizeStr = currentStreamW > 0 ? "\(currentStreamW)×\(currentStreamH)" : "\(presets[selectedPreset].width)×\(presets[selectedPreset].height)"
        let header = NSMenuItem(title: "Tessy Link — \(running ? "Streaming · \(sizeStr)" : "Stopped")", action: nil, keyEquivalent: "")
        header.isEnabled = false; menu.addItem(header)
        if running && !statusText.isEmpty {
            let s = NSMenuItem(title: "   \(statusText)", action: nil, keyEquivalent: ""); s.isEnabled = false; menu.addItem(s)
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: running ? "Stop" : "Start", action: #selector(toggleRunning), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle)

        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        let relayMode = NSMenuItem(title: "Shared relay (type code)", action: #selector(setRelayMode), keyEquivalent: "")
        relayMode.target = self; relayMode.state = (mode == .relay) ? .on : .off; modeMenu.addItem(relayMode)
        let localMode = NSMenuItem(title: "Local tunnel (this Mac)", action: #selector(setLocalMode), keyEquivalent: "")
        localMode.target = self; localMode.state = (mode == .local) ? .on : .off; modeMenu.addItem(localMode)
        modeMenu.addItem(.separator())
        let setURL = NSMenuItem(title: "Set relay URL…", action: #selector(setRelayURL), keyEquivalent: ""); setURL.target = self; modeMenu.addItem(setURL)
        modeItem.submenu = modeMenu; menu.addItem(modeItem)

        menu.addItem(.separator())

        if mode == .relay {
            let urlItem = NSMenuItem(title: relayURLString.isEmpty ? "Relay: (not set)" : "Relay: \(httpFromWS(relayURLString))", action: #selector(copyRelayURL), keyEquivalent: ""); urlItem.target = self; menu.addItem(urlItem)
            let codeItem = NSMenuItem(title: "Code: \(sessionCode)", action: #selector(copyCode), keyEquivalent: ""); codeItem.target = self; menu.addItem(codeItem)
            let newCode = NSMenuItem(title: "New code", action: #selector(regenerateCode), keyEquivalent: ""); newCode.target = self; menu.addItem(newCode)
            let qr = NSMenuItem(title: "Show QR code", action: #selector(showQR), keyEquivalent: ""); qr.target = self; qr.isEnabled = !relayURLString.isEmpty; menu.addItem(qr)
        } else {
            let local = NSMenuItem(title: "Local: http://localhost:\(port)", action: #selector(copyLocalURL), keyEquivalent: ""); local.target = self; menu.addItem(local)
            let publicTitle: String
            if let publicURL { publicTitle = "Public: \(publicURL)" }
            else if running { publicTitle = tunnel.isAvailable ? "Public: starting…" : "Public: install cloudflared" }
            else { publicTitle = "Public: (start to create tunnel)" }
            let publicItem = NSMenuItem(title: publicTitle, action: #selector(copyPublicURL), keyEquivalent: ""); publicItem.target = self; menu.addItem(publicItem)
            let qr = NSMenuItem(title: "Show QR code", action: #selector(showQR), keyEquivalent: ""); qr.target = self; qr.isEnabled = (publicURL != nil) || running; menu.addItem(qr)
        }

        menu.addItem(.separator())

        let fitItem = NSMenuItem(title: "Auto-fit to viewer's screen", action: #selector(toggleAutoFit), keyEquivalent: "")
        fitItem.target = self; fitItem.state = autoFit ? .on : .off; menu.addItem(fitItem)

        let resItem = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        let resMenu = NSMenu()
        for (i, preset) in presets.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self; item.tag = i; item.state = (i == selectedPreset) ? .on : .off; resMenu.addItem(item)
        }
        resItem.submenu = resMenu; menu.addItem(resItem)

        let touchItem = NSMenuItem(title: "Touch control (Tesla → Mac)", action: #selector(toggleInput), keyEquivalent: "")
        touchItem.target = self; touchItem.state = inputEnabled ? .on : .off; menu.addItem(touchItem)

        let qItem = NSMenuItem(title: "Quality", action: nil, keyEquivalent: "")
        let qMenu = NSMenu()
        for (label, value) in [("Low", CGFloat(0.35)), ("Medium", 0.5), ("High", 0.7)] {
            let item = NSMenuItem(title: label, action: #selector(selectQuality(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value; item.state = abs(value - jpegQuality) < 0.001 ? .on : .off; qMenu.addItem(item)
        }
        qItem.submenu = qMenu; menu.addItem(qItem)

        let fpsItem = NSMenuItem(title: "Frame rate", action: nil, keyEquivalent: "")
        let fpsMenu = NSMenu()
        for value in [10.0, 15.0, 24.0, 30.0] {
            let item = NSMenuItem(title: "\(Int(value)) fps", action: #selector(selectFPS(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value; item.state = abs(value - fps) < 0.001 ? .on : .off; fpsMenu.addItem(item)
        }
        fpsItem.submenu = fpsMenu; menu.addItem(fpsItem)

        menu.addItem(.separator())
        let screenPerm = NSMenuItem(title: "Open Screen Recording settings…", action: #selector(openScreenSettings), keyEquivalent: ""); screenPerm.target = self; menu.addItem(screenPerm)
        let axPerm = NSMenuItem(title: "Open Accessibility settings…", action: #selector(openAXSettings), keyEquivalent: ""); axPerm.target = self; menu.addItem(axPerm)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Tessy Link", action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleRunning() { running ? stopSession() : startSession() }
    @objc private func setRelayMode() { mode = .relay; UserDefaults.standard.set(mode.rawValue, forKey: "mode"); restartIfRunning(); rebuildMenu() }
    @objc private func setLocalMode() { mode = .local; UserDefaults.standard.set(mode.rawValue, forKey: "mode"); restartIfRunning(); rebuildMenu() }
    @objc private func toggleAutoFit() { autoFit.toggle(); rebuildMenu() }
    @objc private func setRelayURL() {
        let current = relayURLString.isEmpty ? "wss://" : relayURLString
        if let entered = promptForText(title: "Relay URL", message: "Enter your relay's WebSocket URL (wss://…)", value: current) {
            var v = entered.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.hasPrefix("https://") { v = "wss://" + v.dropFirst("https://".count) }
            if v.hasPrefix("http://") { v = "ws://" + v.dropFirst("http://".count) }
            relayURLString = v; UserDefaults.standard.set(v, forKey: "relayURL"); restartIfRunning(); rebuildMenu()
        }
    }
    @objc private func regenerateCode() { sessionCode = Self.newCode(); restartIfRunning(); rebuildMenu() }
    @objc private func selectPreset(_ sender: NSMenuItem) { selectedPreset = sender.tag; restartIfRunning(); rebuildMenu() }
    @objc private func toggleInput() { inputEnabled.toggle(); input.enabled = inputEnabled; rebuildMenu() }
    @objc private func selectQuality(_ sender: NSMenuItem) { if let v = sender.representedObject as? CGFloat { jpegQuality = v; capturer.jpegQuality = v }; rebuildMenu() }
    @objc private func selectFPS(_ sender: NSMenuItem) { if let v = sender.representedObject as? Double { fps = v; capturer.targetFPS = v }; rebuildMenu() }
    @objc private func copyLocalURL() { copy("http://localhost:\(port)") }
    @objc private func copyPublicURL() { if let publicURL { copy(publicURL) } }
    @objc private func copyRelayURL() { if !relayURLString.isEmpty { copy(httpFromWS(relayURLString)) } }
    @objc private func copyCode() { copy(sessionCode) }

    @objc private func showQR() {
        let urlString: String = (mode == .relay) ? httpFromWS(relayURLString) : (publicURL ?? "http://localhost:\(port)")
        guard !urlString.isEmpty, let image = QRCode.image(from: urlString) else { return }
        closeQRWindow()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = (mode == .relay) ? "Scan, then enter code \(sessionCode)" : "Scan in your Tesla browser"
        window.center()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        let imageView = NSImageView(frame: NSRect(x: 30, y: 110, width: 260, height: 260)); imageView.image = image; container.addSubview(imageView)
        let label = NSTextField(labelWithString: (mode == .relay) ? "\(urlString)\nCode: \(sessionCode)" : urlString)
        label.frame = NSRect(x: 10, y: 40, width: 300, height: 60); label.alignment = .center; label.maximumNumberOfLines = 3; container.addSubview(label)
        window.contentView = container; window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true); qrWindow = window
    }

    @objc private func openScreenSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
    @objc private func openAXSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc private func quit() { stopSession(); NSApp.terminate(nil) }

    private func httpFromWS(_ s: String) -> String {
        if s.hasPrefix("wss://") { return "https://" + s.dropFirst("wss://".count) }
        if s.hasPrefix("ws://") { return "http://" + s.dropFirst("ws://".count) }
        return s
    }
    private func closeQRWindow() { qrWindow?.close(); qrWindow = nil }
    private func copy(_ string: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string) }
    private func alert(_ message: String) { let a = NSAlert(); a.messageText = "Tessy Link"; a.informativeText = message; a.runModal() }
    private func promptForText(title: String, message: String, value: String) -> String? {
        let a = NSAlert(); a.messageText = title; a.informativeText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); field.stringValue = value; a.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    private func loadHTML() -> Data {
        if let url = Bundle.module.url(forResource: "index", withExtension: "html"), let data = try? Data(contentsOf: url) { return data }
        return Data("<html><body style='background:#000;color:#fff'>index.html missing</body></html>".utf8)
    }
}
