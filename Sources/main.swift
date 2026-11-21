// Clampless — 외부 모니터 없이 덮개를 닫아도 잠들지 않게 해주는 메뉴바 앱.
// 내부적으로 `pmset -a disablesleep 1|0` 을 토글한다.
//
// 좌클릭: 켜기/끄기 토글
// 우클릭(또는 control+클릭): 메뉴

import AppKit
import IOKit.ps
import ServiceManagement

// MARK: - 시스템 제어

enum Power {
    static let sudoersPath = "/etc/sudoers.d/clampless"

    /// `pmset -g` 출력에서 SleepDisabled 값을 읽는다. (꺼져 있으면 해당 줄 자체가 없음)
    static func isSleepDisabled() -> Bool {
        let out = run("/usr/bin/pmset", ["-g"]).output
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" {
                return parts[1] == "1"
            }
        }
        return false
    }

    static var isHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    /// sudoers 규칙이 있으면 비밀번호 없이 실행, 없으면 실패.
    static func setSleepDisabledWithoutPrompt(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]).status == 0
    }

    /// 관리자 비밀번호를 한 번 받아 sudoers 규칙을 설치하고, 동시에 원하는 상태로 설정한다.
    static func installHelperAndSet(_ on: Bool) -> Bool {
        let user = NSUserName()
        // 사용자 이름이 셸/sudoers 문법에 안전한지 확인
        guard !user.isEmpty,
              user.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) })
        else { return false }

        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let script = [
            "f=$(/usr/bin/mktemp)",
            "/usr/bin/printf '%s\\n' '\(rule)' > \"$f\"",
            "/usr/sbin/visudo -cf \"$f\" >/dev/null",
            "/usr/bin/install -m 0440 -o root -g wheel \"$f\" \(sudoersPath)",
            "/bin/rm -f \"$f\"",
            "/usr/bin/pmset -a disablesleep \(on ? "1" : "0")",
        ].joined(separator: " && ")
        return runAsAdmin(script, prompt: "Clampless가 잠자기 설정(pmset)을 변경할 수 있도록 권한을 설정합니다. 이후에는 비밀번호를 묻지 않습니다.")
    }

    static func uninstallHelper() -> Bool {
        runAsAdmin("/bin/rm -f \(sudoersPath) && /usr/bin/pmset -a disablesleep 0",
                   prompt: "Clampless 권한 설정을 제거하고 잠자기 방지를 해제합니다.")
    }

    /// 현재 배터리로 동작 중인지
    static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    // MARK: helpers

    private static func runAsAdmin(_ shell: String, prompt: String) -> Bool {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let apple = "do shell script \"\(esc(shell))\" with prompt \"\(esc(prompt))\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", apple]).status == 0
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var isOn = false
    private var busy = false
    private var powerSource: CFRunLoopSource?
    private var pollTimer: Timer?

    private let defaults = UserDefaults.standard
    private let kAutoOffOnBattery = "autoOffOnBattery"
    private let kRestoreOnQuit = "restoreOnQuit"
    private let kAutoUpdate = "autoUpdate"

    private let updater = Updater()
    private var updateTimer: Timer?
    private var updateBusy = false
    private var availableTag: String?
    /// 업데이트로 재시작하는 중이면 종료 시 잠자기 방지를 해제하지 않는다 (원격 접속 유지)
    private var relaunchingForUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [kAutoOffOnBattery: true, kRestoreOnQuit: true, kAutoUpdate: true])

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self

        refreshState()
        observePowerSource()
        // 터미널 등 외부에서 pmset을 바꾼 경우도 반영
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshState()
        }

        // 업데이트 확인: 시작 직후 한 번, 이후 1시간마다 (github.com 리다이렉트 방식이라 API 한도와 무관)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.checkForUpdate(manual: false) }
        updateTimer = Timer.scheduledTimer(withTimeInterval: Updater.checkInterval, repeats: true) { [weak self] _ in
            self?.checkForUpdate(manual: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isOn && defaults.bool(forKey: kRestoreOnQuit) && !relaunchingForUpdate {
            _ = Power.setSleepDisabledWithoutPrompt(false)
        }
    }

    // MARK: 클릭

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        let wantsMenu = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if wantsMenu {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil // 다음 좌클릭이 다시 토글로 동작하도록
        } else {
            toggle()
        }
    }

    @objc private func toggle() {
        setOn(!isOn)
    }

    private func setOn(_ on: Bool) {
        guard !busy else { return }
        busy = true
        updateIcon()
        DispatchQueue.global(qos: .userInitiated).async {
            if !Power.setSleepDisabledWithoutPrompt(on) {
                _ = Power.installHelperAndSet(on)
            }
            DispatchQueue.main.async {
                self.busy = false
                self.refreshState()
            }
        }
    }

    private func refreshState() {
        isOn = Power.isSleepDisabled()
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol = isOn ? "sun.max.fill" : "moon.zzz"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Clampless")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = busy
        button.toolTip = isOn
            ? "Clampless: 켜짐 — 덮개를 닫아도 잠들지 않음 (클릭하여 끄기)"
            : "Clampless: 꺼짐 — 일반 잠자기 (클릭하여 켜기)"
    }

    // MARK: 배터리 감지

    private func observePowerSource() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            me.powerSourceChanged()
        }, ctx)?.takeRetainedValue() else { return }
        powerSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    private func powerSourceChanged() {
        guard defaults.bool(forKey: kAutoOffOnBattery), isOn, Power.isOnBattery() else { return }
        // 배터리 상태에서 비밀번호 창을 띄우지 않도록 프롬프트 없는 경로만 사용
        _ = Power.setSleepDisabledWithoutPrompt(false)
        refreshState()
    }

    // MARK: 메뉴

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshState()
        menu.removeAllItems()

        let status = NSMenuItem(title: isOn ? "상태: 켜짐 (덮개 닫아도 깨어 있음)" : "상태: 꺼짐 (일반 잠자기)",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if Power.isOnBattery() {
            let warn = NSMenuItem(title: "⚠︎ 배터리 사용 중", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }

        menu.addItem(.separator())
        menu.addItem(item(isOn ? "끄기" : "켜기", #selector(toggle)))
        menu.addItem(.separator())

        let autoOff = item("배터리로 전환되면 자동으로 끄기", #selector(toggleAutoOff))
        autoOff.state = defaults.bool(forKey: kAutoOffOnBattery) ? .on : .off
        menu.addItem(autoOff)

        let restore = item("종료 시 끄기", #selector(toggleRestoreOnQuit))
        restore.state = defaults.bool(forKey: kRestoreOnQuit) ? .on : .off
        menu.addItem(restore)

        if #available(macOS 13.0, *) {
            let login = item("로그인 시 실행", #selector(toggleLaunchAtLogin))
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }

        if Power.isHelperInstalled {
            menu.addItem(.separator())
            menu.addItem(item("권한 설정 제거…", #selector(uninstallHelper)))
        }

        menu.addItem(.separator())
        let version = NSMenuItem(title: "버전 \(updater.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        if let tag = availableTag {
            menu.addItem(item("\(tag) 업데이트 설치", #selector(installAvailableUpdate)))
        }
        let check = item(updateBusy ? "업데이트 확인 중…" : "업데이트 확인…", #selector(manualCheckForUpdate))
        check.isEnabled = !updateBusy
        menu.addItem(check)
        let auto = item("자동 업데이트", #selector(toggleAutoUpdate))
        auto.state = defaults.bool(forKey: kAutoUpdate) ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())
        menu.addItem(item("Clampless 종료", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleAutoOff() {
        defaults.set(!defaults.bool(forKey: kAutoOffOnBattery), forKey: kAutoOffOnBattery)
    }

    @objc private func toggleRestoreOnQuit() {
        defaults.set(!defaults.bool(forKey: kRestoreOnQuit), forKey: kRestoreOnQuit)
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "로그인 항목 설정 실패"
            alert.informativeText = "\(error.localizedDescription)\n\n앱을 /Applications 로 옮긴 뒤 다시 시도해 보세요."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func uninstallHelper() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Power.uninstallHelper()
            DispatchQueue.main.async { self.refreshState() }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: 업데이트

    @objc private func toggleAutoUpdate() {
        defaults.set(!defaults.bool(forKey: kAutoUpdate), forKey: kAutoUpdate)
    }

    @objc private func manualCheckForUpdate() {
        checkForUpdate(manual: true)
    }

    @objc private func installAvailableUpdate() {
        guard let tag = availableTag else { return }
        install(tag: tag, manual: true)
    }

    /// manual == false: 자동 업데이트가 켜져 있고 설치 가능하면 조용히 설치
    /// manual == true : 결과를 알림창으로 보여 주고, 새 버전이면 설치 여부를 묻는다
    private func checkForUpdate(manual: Bool) {
        guard !updateBusy else { return }
        if !manual && Updater.parseVersion(updater.currentVersion) == nil { return } // 개발 빌드
        updateBusy = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try self.updater.checkForUpdate() }
            DispatchQueue.main.async {
                self.updateBusy = false
                switch result {
                case .failure(let error):
                    if manual { self.alert("업데이트 확인 실패", error.localizedDescription) }
                case .success(nil):
                    self.availableTag = nil
                    if manual { self.alert("최신 버전입니다", "현재 버전 \(self.updater.currentVersion)") }
                case .success(let tag?):
                    self.availableTag = tag
                    if manual {
                        if self.confirm("새 버전 \(tag) 이(가) 있습니다", "지금 설치하고 다시 시작할까요?\n(잠자기 방지 상태는 유지됩니다)") {
                            self.install(tag: tag, manual: true)
                        }
                    } else if self.defaults.bool(forKey: self.kAutoUpdate), self.updater.installBlocker() == nil {
                        self.install(tag: tag, manual: false)
                    }
                }
            }
        }
    }

    private func install(tag: String, manual: Bool) {
        if let why = updater.installBlocker() {
            if manual, confirm("자동으로 설치할 수 없습니다", "\(why)\n\n릴리즈 페이지를 열까요?") {
                NSWorkspace.shared.open(updater.releasesPageURL)
            }
            return
        }
        guard !updateBusy else { return }
        updateBusy = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try self.updater.downloadAndStage(tag: tag) }
            DispatchQueue.main.async {
                self.updateBusy = false
                do {
                    let newApp = try result.get()
                    try self.updater.launchInstaller(newApp: newApp)
                    self.relaunchingForUpdate = true
                    NSApp.terminate(nil)
                } catch {
                    if manual { self.alert("업데이트 실패", error.localizedDescription) }
                }
            }
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func confirm(_ title: String, _ text: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "확인")
        a.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Dock 아이콘 없이 메뉴바에만 표시
app.run()
