// Insomnia menu bar app: an eye icon that keeps this Mac awake with the lid
// closed. All privileged work goes through the `insomnia` command line tool,
// so this app itself never needs a password.
//
// It also watches the lid. With sleep disabled, closing the lid no longer
// locks the screen by itself, so when the lid closes this app locks the
// screen the same way Control-Command-Q does. Processes keep running; the
// next person to open the lid sees the password screen.
import AppKit
import Foundation
import IOKit
import IOKit.pwr_mgt

let cli = "/usr/local/bin/insomnia"
let bundleID = "com.usman.insomnia"
let stateFile = NSString(string: "~/Library/Application Support/Insomnia/session").expandingTildeInPath
let logFile = NSString(string: "~/Library/Logs/Insomnia/insomnia.log").expandingTildeInPath
let lockOnLidCloseKey = "lockOnLidClose"
let secureFile = NSString(string: "~/Library/Application Support/Insomnia/secure").expandingTildeInPath
let secureLogFile = NSString(string: "~/Library/Logs/Insomnia/secure.log").expandingTildeInPath

struct CommandResult {
    let status: Int32
    let output: String
}

func run(_ executable: String, _ arguments: [String]) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return CommandResult(status: 127, output: "could not run \(executable): \(error.localizedDescription)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

func appendLog(_ message: String) {
    let dir = (logFile as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(formatter.string(from: Date())) app: \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: logFile) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logFile, contents: data)
    }
}

func sleepDisabled() -> Bool {
    let result = run("/usr/bin/pmset", ["-g"])
    for line in result.output.split(separator: "\n") {
        // pmset separates the key and value with tabs, e.g. " SleepDisabled\t\t1"
        let parts = line.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
        if parts.count >= 2, parts[0] == "SleepDisabled" {
            return parts[1] == "1"
        }
    }
    return false
}

func sessionEnd() -> Date? {
    guard let text = try? String(contentsOfFile: stateFile, encoding: .utf8),
          let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

/// Locks the screen through the login framework, exactly what Control-Command-Q
/// and the Lock Screen menu item do. Nothing is put to sleep.
@discardableResult
func lockScreen() -> Bool {
    guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW),
          let symbol = dlsym(handle, "SACLockScreenImmediate") else {
        appendLog("lock failed: SACLockScreenImmediate not found")
        return false
    }
    typealias LockFunction = @convention(c) () -> Int32
    let lock = unsafeBitCast(symbol, to: LockFunction.self)
    let result = lock()
    appendLog("screen lock requested (result \(result))")
    return true
}

/// Lid open/close events. IOPMrootDomain posts kIOPMMessageClamshellStateChange
/// to its general-interest clients (not to IORegisterForSystemPower clients,
/// which only get sleep/wake messages). As a fallback the AppleClamshellState
/// property is also polled every two seconds, so a missed notification still
/// produces an event. Each transition fires exactly once.
final class LidWatcher {
    // Function-like C macros, which Swift cannot import; values checked
    // against the IOKit headers on macOS 15.
    static let clamshellChange: UInt32 = 0xE003_4100    // kIOPMMessageClamshellStateChange
    static let clamshellClosedBit: UInt = 0x1           // kClamshellStateBit

    var onLidClosed: (() -> Void)?
    var onLidOpened: (() -> Void)?
    private var rootDomain: io_service_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var pollTimer: Timer?
    private var lastClosed: Bool?

    /// Returns which of the two sources could be started.
    func start() -> (notifications: Bool, polling: Bool) {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return (false, false) }
        lastClosed = readClosed()

        var notifications = false
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            notifyPort = port
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let kr = IOServiceAddInterestNotification(port, rootDomain, "IOGeneralInterest", { refcon, _, messageType, argument in
                guard let refcon = refcon else { return }
                let watcher = Unmanaged<LidWatcher>.fromOpaque(refcon).takeUnretainedValue()
                watcher.handle(messageType: messageType, argument: argument)
            }, refcon, &notifier)
            if kr == KERN_SUCCESS {
                let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                notifications = true
            }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, let closed = self.readClosed() else { return }
            self.update(closed: closed, source: "poll")
        }
        return (notifications, pollTimer != nil)
    }

    private func readClosed() -> Bool? {
        guard rootDomain != 0,
              let unmanaged = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        let value = unmanaged.takeRetainedValue()
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        guard messageType == Self.clamshellChange else { return }
        let closed = (UInt(bitPattern: argument) & Self.clamshellClosedBit) != 0
        update(closed: closed, source: "notification")
    }

    private func update(closed: Bool, source: String) {
        guard closed != lastClosed else { return }
        lastClosed = closed
        appendLog("lid \(closed ? "closed" : "opened") (\(source))")
        if closed {
            onLidClosed?()
        } else {
            onLidOpened?()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let lidWatcher = LidWatcher()
    private let statusLine = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
    private let endLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Keep Awake With Lid Closed", action: #selector(toggle), keyEquivalent: "")
    private let lockOnLidItem = NSMenuItem(title: "Lock Screen When Lid Closes", action: #selector(toggleLockOnLidClose), keyEquivalent: "")
    private let secureToggleItem = NSMenuItem(title: "Start Secure Background Mode", action: #selector(toggleSecure), keyEquivalent: "")
    private let securePanel = SecurePanel()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM, HH:mm"
        return f
    }()

    private var lockOnLidClose: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: lockOnLidCloseKey) == nil { return true }
        return defaults.bool(forKey: lockOnLidCloseKey)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "Insomnia: keep this Mac awake with the lid closed"

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        endLine.isEnabled = false
        endLine.isHidden = true
        menu.addItem(statusLine)
        menu.addItem(endLine)
        menu.addItem(.separator())

        toggleItem.target = self
        menu.addItem(toggleItem)

        let timed = NSMenu()
        let choices: [(String, String)] = [
            ("1 Hour", "1h"), ("2 Hours", "2h"), ("4 Hours", "4h"),
            ("8 Hours", "8h"), ("12 Hours", "12h"), ("24 Hours", "24h"),
        ]
        for (title, arg) in choices {
            let item = NSMenuItem(title: title, action: #selector(startTimed(_:)), keyEquivalent: "")
            item.representedObject = arg
            item.target = self
            timed.addItem(item)
        }
        let timedItem = NSMenuItem(title: "Keep Awake For…", action: nil, keyEquivalent: "")
        timedItem.submenu = timed
        menu.addItem(timedItem)
        menu.addItem(.separator())

        lockOnLidItem.target = self
        menu.addItem(lockOnLidItem)
        let lockNowItem = NSMenuItem(title: "Lock Screen Now", action: #selector(lockNow), keyEquivalent: "l")
        lockNowItem.target = self
        menu.addItem(lockNowItem)
        menu.addItem(.separator())

        secureToggleItem.target = self
        menu.addItem(secureToggleItem)
        let securePanelItem = NSMenuItem(title: "Secure Background Mode…", action: #selector(openSecurePanel), keyEquivalent: "s")
        securePanelItem.target = self
        menu.addItem(securePanelItem)
        menu.addItem(.separator())

        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        let quitItem = NSMenuItem(title: "Quit Insomnia", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        lidWatcher.onLidClosed = { [weak self] in
            guard let self = self else { return }
            if self.lockOnLidClose {
                appendLog("locking screen")
                lockScreen()
            } else {
                appendLog("lock on lid close is off, not locking")
            }
        }
        // `insomnia panel` asks the running app to show the control panel.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(openSecurePanel),
            name: Notification.Name("com.usman.insomnia.showPanel"), object: nil)
        let sources = lidWatcher.start()
        appendLog("started, lid watcher: notifications \(sources.notifications ? "on" : "FAILED"), polling \(sources.polling ? "on" : "FAILED")")
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    @objc func refresh() {
        let on = sleepDisabled()
        let secure = FileManager.default.fileExists(atPath: secureFile)
        secureToggleItem.title = secure ? "Stop Secure Background Mode" : "Start Secure Background Mode (Locks Now)"
        let symbol = secure ? "lock.shield.fill" : (on ? "eye.fill" : "eye.slash")
        let description = secure ? "Insomnia: Secure Background Mode" : (on ? "Insomnia: awake with lid closed" : "Insomnia: normal sleep")
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = on ? "👁" : "zz"
        }
        toggleItem.state = on ? .on : .off
        lockOnLidItem.state = lockOnLidClose ? .on : .off
        if on {
            statusLine.title = "Awake: lid closed, Mac keeps running"
            if let end = sessionEnd() {
                endLine.title = "Ends \(formatter.string(from: end))"
            } else {
                endLine.title = "Ends when you turn it off"
            }
            endLine.isHidden = false
        } else {
            statusLine.title = "Normal: lid closed, Mac sleeps"
            endLine.isHidden = true
        }
    }

    private func runCLI(_ arguments: [String]) {
        statusLine.title = "Working…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(cli, arguments)
            DispatchQueue.main.async {
                self.refresh()
                if result.status != 0 {
                    self.showError(result.output)
                }
            }
        }
    }

    private func showError(_ output: String) {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = NSAlert()
        alert.messageText = "Insomnia could not change the sleep setting"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        let setupLine = text.split(separator: "\n").map(String.init).first { $0.contains("sudo install") }
        if setupLine != nil {
            alert.addButton(withTitle: "Copy Setup Command")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn, let line = setupLine {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(line.trimmingCharacters(in: .whitespaces), forType: .string)
        }
    }

    @objc func toggle() {
        runCLI(sleepDisabled() ? ["off"] : ["on"])
    }

    @objc func startTimed(_ sender: NSMenuItem) {
        guard let arg = sender.representedObject as? String else { return }
        runCLI(["on", arg])
    }

    @objc func toggleLockOnLidClose() {
        let newValue = !lockOnLidClose
        UserDefaults.standard.set(newValue, forKey: lockOnLidCloseKey)
        lockOnLidItem.state = newValue ? .on : .off
        appendLog("lock on lid close turned \(newValue ? "on" : "off")")
    }

    @objc func lockNow() {
        lockScreen()
    }

    @objc func toggleSecure() {
        runCLI(FileManager.default.fileExists(atPath: secureFile) ? ["secure", "off"] : ["secure", "on"])
    }

    @objc func openSecurePanel() {
        securePanel.show()
    }

    @objc func openLog() {
        let dir = (logFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile) {
            FileManager.default.createFile(atPath: logFile, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logFile))
    }

    @objc func quit() {
        guard sleepDisabled() else {
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "This Mac is set to stay awake with the lid closed"
        alert.informativeText = "Quitting closes the menu bar icon and stops lock-on-lid-close. The timer and battery floor keep working in the background. Do you want sleep back to normal before quitting?"
        alert.addButton(withTitle: "Restore Normal Sleep and Quit")
        alert.addButton(withTitle: "Keep Awake and Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let result = run(cli, ["off"])
            if result.status != 0 {
                showError(result.output)
                return
            }
            NSApp.terminate(nil)
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default:
            break
        }
    }
}


// MARK: - Secure Background Mode control panel

/// A small window with the six status indicators, the controls and the job
/// list. Everything it shows comes from `insomnia secure status --porcelain`,
/// and every button runs an `insomnia` command, so the panel and the command
/// line can never disagree.
final class SecurePanel: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    private var valueFields: [String: NSTextField] = [:]
    private let detailView = NSTextView()
    private let primaryButton = NSButton(title: "Enable Secure Background Mode", target: nil, action: nil)
    private let keepAwakeButton = NSButton(checkboxWithTitle: "Keep Mac Awake (also with the lid closed)", target: nil, action: nil)
    private let autoguardButton = NSButton(checkboxWithTitle: "Keep the Mac awake automatically whenever a script drives Chrome", target: nil, action: nil)
    private var autoguardOn = true
    private var secureActive = false
    private var sessionOn = false
    private var refreshing = false

    private static let rows: [(key: String, title: String)] = [
        ("secure", "Secure Mode"), ("lock", "Screen Lock"), ("display", "Display"),
        ("sleep", "System Sleep Prevention"), ("chrome", "Chrome Automation"),
        ("jobs", "Background Jobs"), ("power", "Power State"),
    ]

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Secure Background Mode"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 560, height: 520)

        let intro = NSTextField(wrappingLabelWithString:
            "Keeps the Mac awake, locks the screen and turns the display off while your jobs run. "
            + "Leave the lid open. Chrome and your jobs are never closed, and the lock is the normal macOS password screen.")
        intro.textColor = .secondaryLabelColor

        let grid = NSGridView()
        grid.columnSpacing = 16
        grid.rowSpacing = 8
        for row in Self.rows {
            let name = NSTextField(labelWithString: row.title)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            let value = NSTextField(labelWithString: "…")
            value.lineBreakMode = .byTruncatingTail
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            valueFields[row.key] = value
            grid.addRow(with: [name, value])
        }

        primaryButton.target = self
        primaryButton.action = #selector(togglePrimary)
        primaryButton.bezelStyle = .rounded
        primaryButton.toolTip = "Keeps the Mac awake, locks the screen and turns the display off, in that order"
        keepAwakeButton.target = self
        keepAwakeButton.action = #selector(toggleKeepAwake)
        keepAwakeButton.toolTip = "The lid-closed keep-awake session, without locking"

        let controls = NSStackView(views: [
            primaryButton,
            button("Lock Mac Screen", #selector(lockScreenNow)),
            button("Turn Display Off", #selector(displayOff)),
        ])
        controls.spacing = 10
        autoguardButton.target = self
        autoguardButton.action = #selector(toggleAutoguard)

        let detailTitle = NSTextField(labelWithString: "Active automation jobs and session log")
        detailTitle.font = .systemFont(ofSize: 13, weight: .medium)

        detailView.isEditable = false
        detailView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailView.textContainerInset = NSSize(width: 6, height: 6)
        detailView.autoresizingMask = [.width]
        detailView.isVerticallyResizable = true
        let scroll = NSScrollView()
        scroll.documentView = detailView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [
            button("Compatibility Check", #selector(runDoctor)),
            button("Forget Finished Jobs", #selector(clearJobs)),
            button("Open Session Log", #selector(openSessionLog)),
        ])
        footer.spacing = 10

        let stack = NSStackView(views: [intro, grid, controls, keepAwakeButton, autoguardButton, detailTitle, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            grid.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -36),
        ])
        w.contentView = content
        w.center()
        window = w
    }

    private func set(_ key: String, _ text: String, _ color: NSColor) {
        guard let field = valueFields[key] else { return }
        let s = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color])
        s.append(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.labelColor]))
        field.attributedStringValue = s
        field.toolTip = text
    }

    private func tail(_ path: String, _ count: Int) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }

    @objc func refresh() {
        if refreshing { return }
        refreshing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let status = run(cli, ["secure", "status", "--porcelain"])
            let jobs = run(cli, ["jobs"])
            let log = self.tail(secureLogFile, 12)
            var kv: [String: String] = [:]
            for line in status.output.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                kv[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
            DispatchQueue.main.async {
                self.refreshing = false
                self.apply(kv, jobs: jobs.output, log: log, failed: status.status != 0 ? status.output : nil)
            }
        }
    }

    private func apply(_ kv: [String: String], jobs: String, log: String, failed: String?) {
        if let failed = failed {
            detailView.string = "Could not read the status from \(cli):\n\(failed)\n\nRecovery: run ./install.sh in the insomnia-mac folder."
            return
        }
        let green = NSColor.systemGreen, gray = NSColor.tertiaryLabelColor
        let orange = NSColor.systemOrange, red = NSColor.systemRed

        secureActive = kv["secure"] == "active"
        sessionOn = kv["session"] == "1"
        if secureActive {
            var since = ""
            if let epoch = TimeInterval(kv["secure_since"] ?? "") {
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                since = " since " + f.string(from: Date(timeIntervalSince1970: epoch))
            }
            var monitor = kv["monitor"] == "1" ? "" : " (monitor restarting)"
            if kv["secure_auto"] == "1" { monitor += " (started automatically, not locked by it)" }
            set("secure", "Active\(since), ends \(kv["secure_ends"] ?? "when turned off")\(monitor)", kv["monitor"] == "1" ? green : orange)
        } else {
            set("secure", "Inactive", gray)
        }
        set("lock", kv["lock"] == "active" ? "Active" : "Inactive", kv["lock"] == "active" ? green : gray)
        set("display", kv["display"] == "off" ? "Off" : "On", kv["display"] == "off" ? green : gray)
        let sleepOn = kv["sleep_prevention"] == "active"
        set("sleep", "\(sleepOn ? "Active" : "Inactive") (\(kv["sleep_detail"] ?? ""))", sleepOn ? green : gray)
        let detail = kv["chrome_detail"] ?? ""
        switch kv["chrome"] ?? "" {
        case "running": set("chrome", "Running (\(detail))", green)
        case "paused": set("chrome", "Paused (\(detail))", orange)
        case "idle": set("chrome", "Idle (\(detail))", gray)
        default: set("chrome", "Not running", gray)
        }
        let running = Int(kv["jobs_running"] ?? "") ?? 0
        let completed = Int(kv["jobs_completed"] ?? "") ?? 0
        let failedJobs = Int(kv["jobs_failed"] ?? "") ?? 0
        set("jobs", "\(running) running, \(completed) completed, \(failedJobs) failed",
            failedJobs > 0 ? red : (running > 0 ? green : gray))
        let thermal = Int(kv["thermal"] ?? "") ?? 100
        let source = kv["power_source"] ?? "?"
        set("power", "battery \(kv["battery"] ?? "?")% (\(source)), CPU speed limit \(thermal)%, lid \(kv["lid"] ?? "?"), \(kv["displays"] ?? "?") display(s)",
            (thermal < 100 || source == "discharging") ? orange : green)

        primaryButton.title = secureActive ? "Disable Secure Background Mode" : "Enable Secure Background Mode"
        keepAwakeButton.state = sleepOn ? .on : .off
        autoguardOn = kv["autoguard"] != "off"
        autoguardButton.state = autoguardOn ? .on : .off

        let text = jobs.trimmingCharacters(in: .newlines) + "\n\nSession log\n" + (log.isEmpty ? "(empty)" : log)
        if detailView.string != text { detailView.string = text }
    }

    private func command(_ arguments: [String], showOutput: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(cli, arguments)
            DispatchQueue.main.async {
                self.refresh()
                if result.status != 0 || showOutput {
                    let alert = NSAlert()
                    alert.messageText = result.status == 0 ? "insomnia \(arguments.joined(separator: " "))" : "That did not fully work"
                    alert.informativeText = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    alert.alertStyle = result.status == 0 ? .informational : .warning
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    @objc func togglePrimary() { command(secureActive ? ["secure", "off"] : ["secure", "on"]) }
    @objc func lockScreenNow() { command(["lock"]) }
    @objc func displayOff() { command(["display-off"]) }
    @objc func toggleKeepAwake() { command(sessionOn ? ["off"] : ["on"]) }
    @objc func toggleAutoguard() { command(["autoguard", autoguardOn ? "off" : "on"]) }
    @objc func clearJobs() { command(["jobs", "clear"]) }
    @objc func runDoctor() { command(["doctor"], showOutput: true) }
    @objc func openSessionLog() {
        if !FileManager.default.fileExists(atPath: secureLogFile) {
            FileManager.default.createFile(atPath: secureLogFile, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: secureLogFile))
    }
}

// MARK: - helper mode
//
// `Insomnia --lock` and `Insomnia --state` let the insomnia command line tool
// lock the screen and read the lock, display and lid state without starting
// the menu bar app. Anything else falls through to the normal app.

func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
}

func lidIsClosed() -> Bool? {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return nil }
    defer { IOObjectRelease(root) }
    guard let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? NSNumber else { return nil }
    return value.boolValue
}

if CommandLine.arguments.count > 1 {
    switch CommandLine.arguments[1] {
    case "--lock":
        exit(lockScreen() ? 0 : 1)
    case "--show-panel":
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.usman.insomnia.showPanel"), object: nil, userInfo: nil, deliverImmediately: true)
        exit(0)
    case "--state":
        var displays: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displays)
        print("locked=\(screenIsLocked() ? 1 : 0)")
        print("display=\(CGDisplayIsAsleep(CGMainDisplayID()) != 0 ? "off" : "on")")
        if let closed = lidIsClosed() { print("lid=\(closed ? "closed" : "open")") }
        print("displays=\(displays)")
        exit(0)
    default:
        break
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
