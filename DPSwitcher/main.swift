import Cocoa
import CoreImage

let displayIndex = "1"
let dpInputValue = "15"
let usbcInputValue = "26"
let m1ddcPath = "/opt/homebrew/bin/m1ddc"
let switchingEnabled = true
let maxBlurRadius: CGFloat = 40
let animationDuration: CFTimeInterval = 0.65
let springEase = CAMediaTimingFunction(controlPoints: 0.93, 0.02, 0.74, 0.98)

let logPath = NSString(string: "~/DPSwitcher.log").expandingTildeInPath

func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    // Bound diagnostics even if an input keeps alternating for days.
    if let size = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size]) as? NSNumber,
       size.intValue >= 1024 * 1024 {
        let previous = logPath + ".previous"
        try? FileManager.default.removeItem(atPath: previous)
        try? FileManager.default.moveItem(atPath: logPath, toPath: previous)
    }
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
    }
}

func setInput(_ value: String) {
    log("setInput(\(value)) called, switchingEnabled=\(switchingEnabled)")
    guard switchingEnabled else { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: m1ddcPath)
    task.arguments = ["display", displayIndex, "set", "input", value]
    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe
    do {
        try task.run()
        task.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        log("m1ddc exit=\(task.terminationStatus) stdout=\(out.trimmingCharacters(in: .whitespacesAndNewlines)) stderr=\(err.trimmingCharacters(in: .whitespacesAndNewlines))")
    } catch {
        log("m1ddc failed to launch: \(error)")
    }
}

func switchToDP() { setInput(dpInputValue) }
func switchToUSBC() { setInput(usbcInputValue) }

/// `m1ddc get input` isn't in --help but works and reads the live VCP 0x60 value —
/// used to poll for the display actually being back on USB-C, since switching the
/// input source doesn't drop the physical USB-C link, so macOS never fires any
/// screen-reconfiguration notification for it.
func currentInputValue() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: m1ddcPath)
    task.arguments = ["display", displayIndex, "get", "input"]
    let outPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.terminationStatus == 0 else { return nil }
        return out
    } catch {
        return nil
    }
}

func setWithoutImplicitAnimation(_ apply: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    apply()
    CATransaction.commit()
}

func springLikeAnimation(keyPath: String, from: CGFloat, to: CGFloat, duration: CFTimeInterval) -> CABasicAnimation {
    let anim = CABasicAnimation(keyPath: keyPath)
    anim.fromValue = from
    anim.toValue = to
    anim.duration = duration
    anim.timingFunction = springEase
    anim.fillMode = .forwards
    anim.isRemovedOnCompletion = false
    return anim
}

struct Overlay {
    let window: NSWindow
    let containerView: NSView
    let blackLayer: CALayer
    let backdropLayer: CALayer?
    let blurObj: NSObject?
}

func buildOverlay(on screen: NSScreen) -> Overlay {
    let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.level = .screenSaver
    window.isOpaque = false
    window.backgroundColor = .clear
    window.ignoresMouseEvents = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.setFrame(screen.frame, display: true)

    let containerView = NSView(frame: screen.frame)
    containerView.wantsLayer = true

    // Live, cross-window backdrop blur: our own CABackdropLayer (windowServerAware),
    // not NSVisualEffectView's internal one — so we own the CAFilter and can animate
    // its radius directly, unlike the private layer inside NSVisualEffectView which
    // the system continuously resets.
    var blurObj: NSObject?
    var backdropLayer: CALayer?
    if let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
       let filterClass = NSClassFromString("CAFilter") as? NSObject.Type {
        let backdrop = backdropClass.init()
        backdrop.frame = containerView.bounds
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.setValue("dpswitcher_blur", forKey: "groupName")
        backdrop.setValue(1.0, forKey: "scale") // full-resolution sampling

        let sel = NSSelectorFromString("filterWithType:")
        if filterClass.responds(to: sel),
           let blur = filterClass.perform(sel, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject {
            blur.setValue(true, forKey: "inputNormalizeEdges")
            blur.setValue(0.0, forKey: "inputRadius")
            blurObj = blur
            backdrop.filters = [blur]
        }

        backdropLayer = backdrop
        containerView.layer?.addSublayer(backdrop)
    }

    // Plain black layer on top, faded in perfectly in sync with the blur, so it
    // reads as one continuous "darker and darker to black" transition.
    let blackLayer = CALayer()
    blackLayer.frame = containerView.bounds
    blackLayer.backgroundColor = NSColor.black.cgColor
    containerView.layer?.addSublayer(blackLayer)
    setWithoutImplicitAnimation { blackLayer.opacity = 0 }

    window.contentView = containerView

    return Overlay(window: window, containerView: containerView, blackLayer: blackLayer, backdropLayer: backdropLayer, blurObj: blurObj)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var rightClickMenu: NSMenu?
    var blackoutWindow: NSWindow?
    var pendingWork: [DispatchWorkItem] = []
    var pollTimer: Timer?
    var pollPolicy = InputPollPolicy()
    var pollGeneration = 0
    var lastLoggedInput: String?
    var pollInFlight = false
    var lastLeftClickTimestamp: TimeInterval?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "tv", accessibilityDescription: "Switch to DisplayPort")
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .light)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            .applying(.preferringMonochrome())
        let monoIcon = icon?.withSymbolConfiguration(config)
        monoIcon?.isTemplate = true
        statusItem.button?.image = monoIcon
        statusItem.button?.wantsLayer = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let menu = NSMenu()
        menu.addItem(withTitle: "Switch to DisplayPort", action: #selector(switchToDPClicked), keyEquivalent: "")
        menu.addItem(withTitle: "Switch to USB-C", action: #selector(switchBackClicked), keyEquivalent: "")
        rightClickMenu = menu
    }

    @objc func clicked() {
        guard let event = NSApp.currentEvent else {
            log("clicked() ignored: no current event")
            return
        }

        let mouseButton: StatusItemMouseButton
        switch event.type {
        case .leftMouseUp:
            mouseButton = .left
        case .rightMouseUp:
            mouseButton = .right
        default:
            log("clicked() ignored: eventType=\(event.type.rawValue)")
            return
        }

        // event.clickCount never reaches 2 here, so track click timing ourselves.
        var effectiveClickCount = event.clickCount
        if mouseButton == .left {
            let now = event.timestamp
            if let last = lastLeftClickTimestamp, now - last <= NSEvent.doubleClickInterval {
                effectiveClickCount = max(effectiveClickCount, 2)
                lastLeftClickTimestamp = nil
            } else {
                lastLeftClickTimestamp = now
            }
        }

        let action = StatusItemClickPolicy.action(for: mouseButton, clickCount: effectiveClickCount)
        log("clicked() eventType=\(event.type.rawValue) clickCount=\(effectiveClickCount) action=\(action)")

        switch action {
        case .ignore:
            return
        case .switchToDisplayPort:
            fadeToBlackThenSwitch()
        case .showMenu:
            guard let menu = rightClickMenu, let button = statusItem.button else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
        }
    }

    @objc func switchToDPClicked() {
        log("switchToDPClicked()")
        fadeToBlackThenSwitch()
    }

    @objc func switchBackClicked() {
        log("switchBackClicked()")
        revealFromBlackAfterSwitch()
    }

    @objc func resetAnimation() {
        log("resetAnimation() pendingWorkCount=\(pendingWork.count)")
        pendingWork.forEach { $0.cancel() }
        pendingWork.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
        pollGeneration += 1
        func removeAllAnimationsRecursively(_ layer: CALayer?) {
            guard let layer = layer else { return }
            layer.removeAllAnimations()
            layer.sublayers?.forEach { removeAllAnimationsRecursively($0) }
        }
        if let contentView = blackoutWindow?.contentView {
            removeAllAnimationsRecursively(contentView.layer)
        }
        blackoutWindow?.orderOut(nil)
        blackoutWindow = nil
    }

    /// Double-click → fade to black + blur, then switch to DisplayPort.
    func fadeToBlackThenSwitch() {
        log("fadeToBlackThenSwitch() start")
        resetAnimation()

        guard let screen = NSScreen.main else {
            log("fadeToBlackThenSwitch: no NSScreen.main, switching immediately")
            switchToDP()
            return
        }

        let overlay = buildOverlay(on: screen)
        let clickToReset = NSClickGestureRecognizer(target: self, action: #selector(resetAnimation))
        overlay.containerView.addGestureRecognizer(clickToReset)

        overlay.window.orderFrontRegardless()
        blackoutWindow = overlay.window

        if let backdropLayer = overlay.backdropLayer, let blurObj = overlay.blurObj {
            let blurAnim = springLikeAnimation(keyPath: "filters.gaussianBlur.inputRadius", from: 0, to: maxBlurRadius, duration: animationDuration)
            setWithoutImplicitAnimation { blurObj.setValue(maxBlurRadius, forKey: "inputRadius") }
            backdropLayer.add(blurAnim, forKey: "blurRadiusIn")
        }

        let blackAnim = springLikeAnimation(keyPath: "opacity", from: 0, to: 1, duration: animationDuration)
        setWithoutImplicitAnimation { overlay.blackLayer.opacity = 1 }
        overlay.blackLayer.add(blackAnim, forKey: "blackIn")

        let finish = DispatchWorkItem { [weak self] in
            log("fadeToBlackThenSwitch: animation finished, calling switchToDP()")
            switchToDP()
            // Stay black+blurred and wait — the monitor may come back to USB-C from
            // the PC's own tray app, not from anything this Mac app does, so we just
            // watch passively for the display to wake up again.
            log("fadeToBlackThenSwitch: staying covered, waiting for display to return")
            self?.waitForReconnectThenReveal(overlay: overlay)
        }
        pendingWork.append(finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration, execute: finish)
    }

    /// Menu action → immediately cover the screen (already fully black+blurred, since
    /// there's nothing to see while the Mac isn't the active input), switch to USB-C,
    /// then reveal (un-blur/un-black) once macOS notices the display come back to life.
    func revealFromBlackAfterSwitch() {
        log("revealFromBlackAfterSwitch() start")
        resetAnimation()

        guard let screen = NSScreen.main else {
            log("revealFromBlackAfterSwitch: no NSScreen.main, switching immediately")
            switchToUSBC()
            return
        }

        let overlay = buildOverlay(on: screen)

        if let blurObj = overlay.blurObj {
            setWithoutImplicitAnimation { blurObj.setValue(maxBlurRadius, forKey: "inputRadius") }
        }
        setWithoutImplicitAnimation { overlay.blackLayer.opacity = 1 }

        overlay.window.orderFrontRegardless()
        blackoutWindow = overlay.window
        log("revealFromBlackAfterSwitch: overlay shown (black+blur at max), calling switchToUSBC()")

        switchToUSBC()

        waitForReconnectThenReveal(overlay: overlay)
    }

    /// Polls the display's actual VCP 0x60 value (via `m1ddc get input`) and reveals
    /// once it reads back as USB-C — switching input doesn't drop the physical USB-C
    /// link, so macOS never fires a screen-reconfiguration notification we could
    /// listen for instead. Waits indefinitely (manual click still resets/dismisses).
    private func waitForReconnectThenReveal(overlay: Overlay) {
        log("waitForReconnectThenReveal: starting poll of current input value")
        pollTimer?.invalidate()
        pollGeneration += 1
        pollPolicy = InputPollPolicy()
        lastLoggedInput = nil
        // A fully black cover needs no live desktop sampling or blur rendering.
        overlay.backdropLayer?.removeAllAnimations()
        overlay.backdropLayer?.removeFromSuperlayer()
        overlay.blackLayer.removeAllAnimations()
        scheduleInputPoll(overlay: overlay, generation: pollGeneration, delay: 0.25)
    }

    private func scheduleInputPoll(overlay: Overlay, generation: Int, delay: TimeInterval) {
        guard generation == pollGeneration, blackoutWindow === overlay.window else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, generation == self.pollGeneration,
                  self.blackoutWindow === overlay.window else { return }
            self.pollTimer = nil
            // An old session's subprocess may still be finishing after reset.
            guard !self.pollInFlight else {
                self.scheduleInputPoll(overlay: overlay, generation: generation, delay: 0.25)
                return
            }
            self.pollInFlight = true
            DispatchQueue.global(qos: .utility).async {
                let value = currentInputValue()
                DispatchQueue.main.async {
                    self.pollInFlight = false
                    guard generation == self.pollGeneration,
                          self.blackoutWindow === overlay.window else { return }
                    let result = self.pollPolicy.record(value)
                    let state = self.pollPolicy.failures > 0 ? "unavailable" : (value ?? "unavailable")
                    if state != self.lastLoggedInput {
                        log("poll: input=\(state), nextCheck=\(result.delay)s")
                        self.lastLoggedInput = state
                    }
                    if result.reveal {
                        self.playReveal(overlay: overlay, source: "poll")
                    } else {
                        self.scheduleInputPoll(overlay: overlay, generation: generation, delay: result.delay)
                    }
                }
            }
        }
        timer.tolerance = min(delay * 0.1, 1)
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func playReveal(overlay: Overlay, source: String) {
        log("playReveal() called from \(source)")
        guard blackoutWindow === overlay.window else {
            log("playReveal: blackoutWindow mismatch, ignoring (probably already reset)")
            return
        }
        pollTimer?.invalidate()
        pollTimer = nil
        pollGeneration += 1
        pendingWork.forEach { $0.cancel() }
        pendingWork.removeAll()

        if let backdropLayer = overlay.backdropLayer, let blurObj = overlay.blurObj {
            // Restore live blur only for the short reveal animation.
            setWithoutImplicitAnimation {
                blurObj.setValue(maxBlurRadius, forKey: "inputRadius")
                overlay.containerView.layer?.insertSublayer(backdropLayer, below: overlay.blackLayer)
            }
            let blurAnim = springLikeAnimation(keyPath: "filters.gaussianBlur.inputRadius", from: maxBlurRadius, to: 0, duration: animationDuration)
            setWithoutImplicitAnimation { blurObj.setValue(0.0, forKey: "inputRadius") }
            backdropLayer.add(blurAnim, forKey: "blurRadiusOut")
        }

        let blackAnim = springLikeAnimation(keyPath: "opacity", from: 1, to: 0, duration: animationDuration)
        setWithoutImplicitAnimation { overlay.blackLayer.opacity = 0 }
        overlay.blackLayer.add(blackAnim, forKey: "blackOut")

        let cleanup = DispatchWorkItem { [weak self] in
            log("playReveal: cleanup, closing overlay window")
            self?.blackoutWindow?.orderOut(nil)
            self?.blackoutWindow = nil
        }
        pendingWork.append(cleanup)
        DispatchQueue.main.asyncAfter(deadline: .now() + animationDuration, execute: cleanup)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
