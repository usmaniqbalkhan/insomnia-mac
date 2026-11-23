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
let activityLogFile = NSString(string: "~/Library/Logs/Insomnia/activity.log").expandingTildeInPath

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
    private let stopItem = NSMenuItem(title: "Stop and Go Back to Normal", action: #selector(stopAll), keyEquivalent: "")
    private let securePanel = SecurePanel()
    private let mainWindow = MainWindow()
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
        statusItem.button?.toolTip = "Insomnia: keep this Mac running"

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        endLine.isEnabled = false
        endLine.isHidden = true
        menu.addItem(statusLine)
        menu.addItem(endLine)
        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Insomnia…", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let keepMenu = NSMenu()
        let choices: [(String, String)] = [
            ("1 Hour", "1h"), ("2 Hours", "2h"), ("4 Hours", "4h"), ("6 Hours", "6h"),
            ("8 Hours", "8h"), ("12 Hours", "12h"), ("Until I Stop It", "forever"),
        ]
        for (title, arg) in choices {
            let item = NSMenuItem(title: title, action: #selector(keepFor(_:)), keyEquivalent: "")
            item.representedObject = arg
            item.target = self
            keepMenu.addItem(item)
        }
        let keepItem = NSMenuItem(title: "Keep My Mac Running For (Locks the Screen)", action: nil, keyEquivalent: "")
        keepItem.submenu = keepMenu
        menu.addItem(keepItem)
        stopItem.target = self
        menu.addItem(stopItem)
        let lockNowItem = NSMenuItem(title: "Lock Screen Now", action: #selector(lockNow), keyEquivalent: "l")
        lockNowItem.target = self
        menu.addItem(lockNowItem)
        menu.addItem(.separator())

        // Everything technical lives one level down.
        let more = NSMenu()
        toggleItem.target = self
        more.addItem(toggleItem)
        lockOnLidItem.target = self
        more.addItem(lockOnLidItem)
        more.addItem(.separator())
        let detailsItem = NSMenuItem(title: "Details…", action: #selector(openSecurePanel), keyEquivalent: "")
        detailsItem.target = self
        more.addItem(detailsItem)
        let logItem = NSMenuItem(title: "Open Technical Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        more.addItem(logItem)
        let moreItem = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        moreItem.submenu = more
        menu.addItem(moreItem)
        let quitItem = NSMenuItem(title: "Quit Insomnia", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        mainWindow.onDetails = { [weak self] in self?.securePanel.show() }
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
            self, selector: #selector(openMainWindow),
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
        let keep = KeepState.read()
        stopItem.isHidden = !keep.running
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
        statusLine.title = keep.headline
        if keep.running, let until = keep.until {
            endLine.title = "Ends \(formatter.string(from: until))"
            endLine.isHidden = false
        } else {
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

    @objc func keepFor(_ sender: NSMenuItem) {
        guard let arg = sender.representedObject as? String else { return }
        runCLI(["keep", arg])
    }

    @objc func stopAll() {
        runCLI(["restore"])
    }

    @objc func openMainWindow() {
        mainWindow.show()
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


// MARK: - What is running right now (read straight from the state files)

/// The few facts the simple window and the menu need. Reading two small files
/// is cheap enough to do every few seconds.
struct KeepState {
    var secure = false          // Secure Background Mode is on
    var session = false         // the lid-closed keep-awake session is on
    var until: Date?            // when it ends by itself, if it has an end
    var hold = false            // stays on until stopped (or until `until`)
    var auto = false            // started by the automatic guard
    var restore = false         // normal sleep comes back at the end

    var running: Bool { secure || session }

    static func read() -> KeepState {
        var state = KeepState()
        if let text = try? String(contentsOfFile: secureFile, encoding: .utf8) {
            state.secure = true
            var kv: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                kv[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
            if let t = TimeInterval(kv["until"] ?? ""), t > 0 { state.until = Date(timeIntervalSince1970: t) }
            state.hold = kv["hold"] == "1"
            state.auto = kv["auto"] == "1"
            state.restore = kv["restore"] == "1" || kv["owns_session"] == "1"
        }
        if FileManager.default.fileExists(atPath: stateFile) {
            state.session = true
            if !state.secure {
                state.until = sessionEnd()
                state.restore = true
            }
        }
        return state
    }

    /// "5 h 42 min left", "42 min left", "less than a minute left"
    static func remaining(until: Date) -> String {
        let seconds = Int(until.timeIntervalSinceNow)
        if seconds < 60 { return "less than a minute left" }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min left" : "\(hours) h left" }
        return "\(minutes) min left"
    }

    /// One short line for the menu and the window title row.
    var headline: String {
        if !running { return "Normal: your Mac sleeps as usual" }
        if let until = until { return "Staying awake · " + KeepState.remaining(until: until) }
        if secure && auto { return "Staying awake while automation runs" }
        if secure && !hold { return "Staying awake until your automation finishes" }
        return "Staying awake until you stop it"
    }
}

// MARK: - The simple window

/// One window, two faces. Idle: pick a duration and press Start. Running:
/// only the status line and the activity log. All technical detail lives in
/// the separate Details window.
final class MainWindow: NSObject, NSWindowDelegate {
    var onDetails: (() -> Void)?

    private var window: NSWindow?
    private var dataTimer: Timer?
    private var state = KeepState()
    private var wantsLog = false          // the user opened the log while nothing is running
    private var lastLogText = ""
    private var busy = false

    private let idleView = NSStackView()
    private let logPane = NSStackView()
    private let durationPopup = NSPopUpButton()
    private let lockCheck = NSButton(checkboxWithTitle: "Lock the screen now (your password is needed to get back in)", target: nil, action: nil)
    private let restoreCheck = NSButton(checkboxWithTitle: "Go back to normal sleep when the time is up", target: nil, action: nil)
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let powerNote = NSTextField(labelWithString: "")
    private let statusDot = NSTextField(labelWithString: "●")
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let stopButton = NSButton(title: "Stop and Go Back to Normal", target: nil, action: nil)
    private let lockButton = NSButton(title: "Lock Screen", target: nil, action: nil)
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let logView = NSTextView()

    private static let durations: [(title: String, arg: String)] = [
        ("30 minutes", "30m"), ("1 hour", "1h"), ("2 hours", "2h"), ("4 hours", "4h"),
        ("6 hours", "6h"), ("8 hours", "8h"), ("12 hours", "12h"), ("24 hours", "24h"),
        ("Until I stop it", "forever"),
    ]

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refresh()
        dataTimer?.invalidate()
        dataTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        dataTimer?.invalidate()
        dataTimer = nil
        wantsLog = false
    }

    private func pushButton(_ b: NSButton, _ action: Selector) {
        b.target = self
        b.action = action
        b.bezelStyle = .rounded
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Insomnia"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.minSize = NSSize(width: 480, height: 460)

        // ----- idle face -----
        let icon = NSImageView()
        if let image = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil) {
            icon.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 40, weight: .regular))
        }
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: "Keep my Mac running")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        let blurb = NSTextField(wrappingLabelWithString:
            "Your Mac stays fully awake and keeps working: browser automation, video rendering, uploads, everything. "
            + "Nothing is paused or closed. Only the screen is locked, for privacy.")
        blurb.textColor = .secondaryLabelColor
        blurb.alignment = .center

        let howLong = NSTextField(labelWithString: "For how long?")
        howLong.font = .systemFont(ofSize: 14, weight: .medium)
        durationPopup.addItems(withTitles: Self.durations.map { $0.title })
        let saved = UserDefaults.standard.string(forKey: "keepDuration") ?? "6h"
        durationPopup.selectItem(at: Self.durations.firstIndex { $0.arg == saved } ?? 4)
        durationPopup.target = self
        durationPopup.action = #selector(durationChanged)
        durationPopup.font = .systemFont(ofSize: 14)
        let durationRow = NSStackView(views: [howLong, durationPopup])
        durationRow.spacing = 10

        lockCheck.state = UserDefaults.standard.object(forKey: "keepLock") == nil || UserDefaults.standard.bool(forKey: "keepLock") ? .on : .off
        restoreCheck.state = UserDefaults.standard.object(forKey: "keepRestore") == nil || UserDefaults.standard.bool(forKey: "keepRestore") ? .on : .off
        let options = NSStackView(views: [lockCheck, restoreCheck])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 8

        pushButton(startButton, #selector(start))
        startButton.controlSize = .large
        startButton.font = .systemFont(ofSize: 16, weight: .semibold)
        startButton.bezelColor = .controlAccentColor
        startButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        powerNote.textColor = .secondaryLabelColor
        powerNote.font = .systemFont(ofSize: 12)

        let logLink = NSButton(title: "Activity Log", target: self, action: #selector(showLog))
        logLink.bezelStyle = .rounded
        let detailsLink = NSButton(title: "Details…", target: self, action: #selector(details))
        detailsLink.bezelStyle = .rounded
        let links = NSStackView(views: [logLink, detailsLink])
        links.spacing = 10

        let spacer1 = NSView(), spacer2 = NSView()
        for v in [icon, title, blurb, durationRow, options, startButton, powerNote, spacer1, links] { idleView.addArrangedSubview(v) }
        idleView.orientation = .vertical
        idleView.alignment = .centerX
        idleView.spacing = 14
        idleView.setCustomSpacing(6, after: icon)
        idleView.setCustomSpacing(22, after: blurb)
        idleView.setCustomSpacing(18, after: durationRow)
        idleView.setCustomSpacing(24, after: options)
        idleView.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 20, right: 32)
        _ = spacer2

        // ----- running face: status line + log, nothing else -----
        statusDot.font = .systemFont(ofSize: 16)
        statusTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        statusTitle.lineBreakMode = .byTruncatingTail
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.font = .systemFont(ofSize: 12)
        let titleRow = NSStackView(views: [statusDot, statusTitle])
        titleRow.spacing = 6
        pushButton(stopButton, #selector(stop))
        pushButton(lockButton, #selector(lockNow))
        pushButton(backButton, #selector(hideLog))
        let buttons = NSStackView(views: [stopButton, lockButton, backButton])
        buttons.spacing = 10

        logView.isEditable = false
        logView.font = .systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 78)]
        paragraph.headIndent = 78
        paragraph.paragraphSpacing = 3
        logView.defaultParagraphStyle = paragraph
        logView.textContainerInset = NSSize(width: 8, height: 8)
        logView.autoresizingMask = [.width]
        logView.isVerticallyResizable = true
        let scroll = NSScrollView()
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for v in [titleRow, statusDetail, buttons, scroll] as [NSView] { logPane.addArrangedSubview(v) }
        logPane.orientation = .vertical
        logPane.alignment = .leading
        logPane.spacing = 10
        logPane.setCustomSpacing(4, after: titleRow)
        logPane.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        let content = NSView()
        for pane in [idleView, logPane] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: content.topAnchor),
                pane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            blurb.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            scroll.widthAnchor.constraint(equalTo: logPane.widthAnchor, constant: -36),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            statusDetail.widthAnchor.constraint(lessThanOrEqualTo: logPane.widthAnchor, constant: -36),
        ])
        w.contentView = content
        w.center()
        window = w
    }

    // ----- data -----

    private func batteryLine() -> (text: String, warn: Bool) {
        let out = run("/usr/bin/pmset", ["-g", "batt"]).output
        var percent = ""
        if let r = out.range(of: #"\d{1,3}%"#, options: .regularExpression) { percent = String(out[r]) }
        if out.contains("'AC Power'") { return ("On the charger, battery \(percent). Good for a long run.", false) }
        return ("On battery (\(percent)). Plug in the charger for a long run: it stops by itself at 10%.", true)
    }

    private func logText() -> String {
        guard let text = try? String(contentsOfFile: activityLogFile, encoding: .utf8), !text.isEmpty else {
            return "Nothing has happened yet. When you press Start, each step shows up here."
        }
        let dayIn = DateFormatter(); dayIn.dateFormat = "yyyy-MM-dd"
        let timeIn = DateFormatter(); timeIn.dateFormat = "HH:mm"
        let timeOut = DateFormatter(); timeOut.dateFormat = "h:mm a"
        let dayOut = DateFormatter(); dayOut.dateFormat = "EEEE d MMMM"
        var lines: [String] = []
        var lastDay = ""
        for raw in text.split(separator: "\n").suffix(400) {
            let line = String(raw)
            guard line.count > 20, line[line.index(line.startIndex, offsetBy: 4)] == "-" else { continue }
            let day = String(line.prefix(10))
            var time = String(line.dropFirst(11).prefix(5))
            if let t = timeIn.date(from: time) { time = timeOut.string(from: t) }
            let message = String(line.dropFirst(20))
            if day != lastDay {
                if let d = dayIn.date(from: day) { lines.append((lines.isEmpty ? "" : "\n") + dayOut.string(from: d)) }
                lastDay = day
            }
            lines.append("\(time)\t\(message)")
        }
        return lines.joined(separator: "\n")
    }

    @objc func refresh() {
        if busy { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let state = KeepState.read()
            let battery = self.batteryLine()
            let log = self.logText()
            DispatchQueue.main.async {
                self.busy = false
                self.state = state
                self.apply(battery: battery, log: log)
            }
        }
    }

    private func apply(battery: (text: String, warn: Bool), log: String) {
        let showLogPane = state.running || wantsLog
        idleView.isHidden = showLogPane
        logPane.isHidden = !showLogPane

        powerNote.stringValue = battery.text
        powerNote.textColor = battery.warn ? .systemOrange : .secondaryLabelColor
        restoreCheck.isEnabled = Self.durations[max(0, durationPopup.indexOfSelectedItem)].arg != "forever"

        if state.running {
            statusDot.textColor = .systemGreen
            statusTitle.stringValue = state.headline
            var parts: [String] = []
            if let until = state.until {
                let f = DateFormatter()
                f.dateFormat = Calendar.current.isDateInToday(until) ? "'today at' h:mm a" : "EEE 'at' h:mm a"
                parts.append("Ends \(f.string(from: until)).")
                parts.append(state.restore ? "Normal sleep comes back by itself." : "The lid-closed keep-awake stays on afterwards.")
            } else if state.secure && state.auto {
                parts.append("Started by itself because a script is driving Chrome. It stops 2 minutes after the script finishes.")
            } else if state.secure && !state.hold {
                parts.append("It stops 2 minutes after your automation finishes.")
            } else {
                parts.append("It stays on until you press Stop.")
            }
            parts.append(battery.warn ? battery.text : "Everything keeps working, also with the screen locked.")
            statusDetail.stringValue = parts.joined(separator: " ")
            statusDetail.textColor = battery.warn ? .systemOrange : .secondaryLabelColor
            stopButton.isHidden = false
            lockButton.isHidden = false
            backButton.isHidden = true
        } else {
            statusDot.textColor = .tertiaryLabelColor
            statusTitle.stringValue = "Nothing is running"
            statusDetail.stringValue = "Your Mac sleeps as usual. This is what happened earlier."
            statusDetail.textColor = .secondaryLabelColor
            stopButton.isHidden = true
            lockButton.isHidden = true
            backButton.isHidden = false
        }

        if log != lastLogText {
            lastLogText = log
            logView.string = log
            logView.scrollToEndOfDocument(nil)
        }
    }

    // ----- actions -----

    private func command(_ arguments: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run(cli, arguments)
            DispatchQueue.main.async {
                self.refresh()
                if result.status != 0 {
                    let alert = NSAlert()
                    alert.messageText = "That did not fully work"
                    alert.informativeText = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    @objc func durationChanged() {
        let choice = Self.durations[max(0, durationPopup.indexOfSelectedItem)].arg
        UserDefaults.standard.set(choice, forKey: "keepDuration")
        restoreCheck.isEnabled = choice != "forever"
    }

    @objc func start() {
        let choice = Self.durations[max(0, durationPopup.indexOfSelectedItem)].arg
        UserDefaults.standard.set(choice, forKey: "keepDuration")
        UserDefaults.standard.set(lockCheck.state == .on, forKey: "keepLock")
        UserDefaults.standard.set(restoreCheck.state == .on, forKey: "keepRestore")
        var arguments = ["keep", choice]
        if lockCheck.state != .on { arguments.append("--no-lock") }
        if restoreCheck.state != .on { arguments.append("--no-restore") }
        command(arguments)
    }

    @objc func stop() { wantsLog = false; command(["restore"]) }
    @objc func lockNow() { command(["display-off"]) }
    @objc func showLog() { wantsLog = true; refresh() }
    @objc func hideLog() { wantsLog = false; refresh() }
    @objc func details() { onDetails?() }
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
        w.title = "Insomnia Details"
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
