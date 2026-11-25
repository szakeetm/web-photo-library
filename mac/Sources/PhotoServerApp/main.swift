import AppKit
import ServiceManagement

/// Menu bar helper: runs the bundled PhotoServer (unless one is already listening), and opens
/// the web app — the Safari "Add to Dock" app if there is one for this server, otherwise Safari.
///
/// Layout inside PhotoServer.app:
///   Contents/MacOS/PhotoServerApp       this helper
///   Contents/Helpers/PhotoServer        the server, with its SwiftPM resource bundles beside it
///   Contents/Resources/web/             the built web app (WEB_ROOT)
/// The server keeps its data where it always does (~/Library/Application Support/PhotoServer),
/// so rebuilding or replacing the app never touches the library database or caches.

/// Fixed, because the browser's offline storage and the Dock web app belong to this address.
/// (PORT in the environment overrides it for testing; PHOTOSERVER_HOME is passed through too.)
let port = ProcessInfo.processInfo.environment["PORT"].flatMap(Int.init) ?? 8787
let baseURL = URL(string: "http://127.0.0.1:\(port)/")!
let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/PhotoServer.log")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    enum State: Equatable {
        case starting, running, external, stopped(String)
    }

    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private var server: Process?
    private var state: State = .starting { didSet { updateStatus() } }
    private var quitting = false
    private var recentCrashes: [Date] = []

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        let launchedAtLogin = Self.launchedAsLoginItem()
        Task {
            await start()
            // At login, just run the server quietly; when opened by hand, show the photos.
            if !launchedAtLogin, state == .running || state == .external { openPhotos() }
        }
    }

    /// Opening the app again while it runs (Finder, Spotlight, Dock) shows the photos.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openPhotos()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        guard let server, server.isRunning else { return .terminateNow }
        server.terminate()  // SIGTERM: graceful shutdown
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(5)
            while server.isRunning, Date() < deadline { usleep(50_000) }
            if server.isRunning { kill(server.processIdentifier, SIGKILL) }
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == AEEventID(kAEOpenApplication)
            && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    // MARK: Server

    private func start() async {
        state = .starting
        if await Self.healthy() {
            // Someone else (e.g. a dev build in Terminal) already serves this port: use it, don't own it.
            state = .external
            return
        }
        let bin = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PhotoServer")
        guard FileManager.default.isExecutableFile(atPath: bin.path),
              let web = Bundle.main.resourceURL?.appendingPathComponent("web") else {
            state = .stopped("Server missing from the app")
            return
        }
        let p = Process()
        p.executableURL = bin
        var env = ProcessInfo.processInfo.environment
        env["PORT"] = String(port)
        env["WEB_ROOT"] = web.path
        p.environment = env
        if let log = Self.openLog() {
            p.standardOutput = log
            p.standardError = log
        }
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in self.serverExited(status: status) }
        }
        do {
            try p.run()
        } catch {
            state = .stopped("Couldn't start: \(error.localizedDescription)")
            return
        }
        server = p
        for _ in 0..<150 {  // up to 30 s (first launch may migrate the database)
            if await Self.healthy() { state = .running; return }
            if !p.isRunning { return }  // serverExited reports it
            try? await Task.sleep(for: .milliseconds(200))
        }
        state = .stopped("Server didn't respond — see the log")
    }

    private func serverExited(status: Int32) {
        server = nil
        guard !quitting else { return }
        let now = Date()
        recentCrashes = recentCrashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if recentCrashes.count > 3 {
            state = .stopped("Server keeps stopping (exit \(status)) — see the log")
            return
        }
        state = .stopped("Server stopped (exit \(status)); restarting…")
        Task {
            try? await Task.sleep(for: .seconds(2))
            if !quitting, server == nil { await start() }
        }
    }

    private static func healthy() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/health"))
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private static func openLog() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 5_000_000 {
            try? fm.removeItem(at: logURL)
        }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: logURL)
        h?.seekToEndOfFile()
        return h
    }

    // MARK: Opening the photos

    /// A Safari web app (File → Add to Dock) whose start URL is this server, if installed.
    private static func webApp() -> URL? {
        let fm = FileManager.default
        let dirs = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")]
        for dir in dirs {
            guard let apps = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for app in apps where app.pathExtension == "app" {
                guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                      let manifest = info["Manifest"] as? [String: Any],
                      let start = (manifest["start_url"] as? String).flatMap(URL.init(string:)),
                      ["127.0.0.1", "localhost"].contains(start.host ?? ""), start.port == port
                else { continue }
                return app
            }
        }
        return nil
    }

    @objc private func openPhotos() {
        if let app = Self.webApp() {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        } else {
            openInSafari()
        }
    }

    @objc private func openInSafari() {
        let cfg = NSWorkspace.OpenConfiguration()
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.open([baseURL], withApplicationAt: safari, configuration: cfg)
        } else {
            NSWorkspace.shared.open(baseURL)
        }
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "Photo Server")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Photos", action: #selector(openPhotos), keyEquivalent: "o")
        menu.addItem(withTitle: "Open in Safari", action: #selector(openInSafari), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(withTitle: "Show Log", action: #selector(showLog), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Photo Server", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
        updateStatus()
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func updateStatus() {
        switch state {
        case .starting: statusLine.title = "Starting…"
        case .running: statusLine.title = "Running on port \(port)"
        case .external: statusLine.title = "Using the server already running on port \(port)"
        case .stopped(let why): statusLine.title = why
        }
        statusItem?.button?.appearsDisabled = !(state == .running || state == .external)
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't change Start at Login"
            alert.runModal()
        }
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(logURL)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
