import AppKit
import WebKit

enum DesktopVisibility {
    static func quartzPoint(_ point: NSPoint, primaryTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryTop - point.y)
    }

    static func isExposed(at point: CGPoint, windows: [[String: Any]], ignoring: Set<Int>,
                          dockPID: pid_t? = nil, displayBounds: [CGRect] = []) -> Bool {
        let desktopLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        for entry in windows {
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  !ignoring.contains(number),
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer > desktopLayer,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
                if let dockPID = dockPID, layer == Int(CGWindowLevelForKey(.dockWindow)),
                    entry[kCGWindowOwnerPID as String] as? pid_t == dockPID,
                    entry[kCGWindowSharingState as String] as? Int == Int(CGWindowSharingType.none.rawValue),
                    displayBounds.contains(rectangle) { continue }
            if rectangle.contains(point) { return false }
        }
        return true
    }

    static func visibleWindows() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    }
}

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class WallpaperWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ViscositySliderView: NSView {
    let slider: NSSlider
    private let label: NSTextField
    private let title: String
    private let onChange: (Double) -> Void

    init(value: Double, title: String = "Zähigkeit", onChange: @escaping (Double) -> Void) {
        slider = NSSlider(value: value, minValue: 0, maxValue: 100, target: nil, action: nil)
        label = NSTextField(labelWithString: "")
        self.title = title
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 68))
        label.frame = NSRect(x: 16, y: 40, width: 248, height: 18)
        slider.frame = NSRect(x: 16, y: 10, width: 248, height: 24)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.setAccessibilityLabel("Zähigkeit")
        addSubview(label)
        addSubview(slider)
        setValue(value)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setValue(_ value: Double, mixed: Bool = false) {
        slider.doubleValue = value
        label.stringValue = mixed ? "\(title): gemischt" : "\(title): \(Int(value.rounded())) / 100"
    }

    @objc private func changed() {
        let value = slider.doubleValue.rounded()
        setValue(value)
        onChange(value)
    }
}

final class WallpaperSurface {
    let displayID: CGDirectDisplayID
    let window: WallpaperWindow
    let webView: WKWebView
    var lastPoint: NSPoint?
    var pageReady = false
    var qualityVerified = false
    var quality = "Medium"
    var iterations = 18
    var viscosity: Double = 0
    var displayName: String
    var renderInfo: [String: Int] = [:]

    init(screen: NSScreen, window: WallpaperWindow, webView: WKWebView) {
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        self.window = window
        self.webView = webView
        displayName = screen.localizedName
    }
}

final class WallpaperApp: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var surfaces: [WallpaperSurface] = []
    private var statusItem: NSStatusItem!
    private var interactionItem: NSMenuItem!
    private var cursorItem: NSMenuItem!
    private var timer: Timer?
    private var interactive = false
    private var followsCursor = true
    private var checkedDisplays = Set<CGDirectDisplayID>()
    private var quality = "Medium"
    private var iterations = 18
    private var viscosity: Double = 0
    private var viscosityView: ViscositySliderView!
    private var displaysMenu: NSMenu!
    private var displayCheckReloaded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--check-desktop") {
            checkDesktopVisibility()
            return
        }
        buildMenu()
        screenChanged()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        timer = Timer(timeInterval: 1.0 / 60.0, target: self,
            selector: #selector(updateCursor), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func createSurface(screen: NSScreen) -> WallpaperSurface {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "fluidSettings")
        if CommandLine.arguments.contains("--check") {
            configuration.userContentController.add(self, name: "fluidCheck")
        }
        let bridge = """
        let releaseTimer;
        let drawing = false;
        window.fluidWallpaperRelease = function() {
            clearTimeout(releaseTimer);
            const canvas = document.querySelector('canvas');
            if (canvas && drawing) canvas.dispatchEvent(new MouseEvent('mouseup', {bubbles: true}));
            drawing = false;
        };
        window.fluidWallpaperPointer = function(x, y) {
            const canvas = document.querySelector('canvas');
            if (!canvas) return;
            if (!drawing) {
                canvas.dispatchEvent(new MouseEvent('mousemove', {
                    clientX: x, clientY: y, bubbles: true, buttons: 0
                }));
                const simulation = window.fluidWallpaperGUI?.__controllers.find(
                    controller => controller.property === 'simulationQuality')?.object;
                simulation?.updateLastMouse();
                canvas.dispatchEvent(new MouseEvent('mousedown', {
                    clientX: x, clientY: y, bubbles: true, buttons: 1
                }));
                drawing = true;
            }
            canvas.dispatchEvent(new MouseEvent('mousemove', {
                clientX: x, clientY: y, bubbles: true, buttons: 1
            }));
            clearTimeout(releaseTimer);
            releaseTimer = setTimeout(window.fluidWallpaperRelease, 80);
        };
        """
        configuration.userContentController.addUserScript(WKUserScript(
            source: bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = WallpaperWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        let window = WallpaperWindow(contentRect: screen.frame,
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = webView
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue:
            Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.orderFrontRegardless()
        return WallpaperSurface(screen: screen, window: window, webView: webView)
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "water.waves",
            accessibilityDescription: "Fluid Wallpaper")
        let menu = NSMenu()
        interactionItem = NSMenuItem(title: "Menüs / Interaktion", action: #selector(toggleInteraction), keyEquivalent: "i")
        cursorItem = NSMenuItem(title: "Auf Cursor reagieren", action: #selector(toggleCursor), keyEquivalent: "")
        cursorItem.state = .on
        menu.addItem(interactionItem)
        menu.addItem(cursorItem)
        let qualityMenu = NSMenu()
        for name in ["SuperResolution", "UltraHigh", "High", "Medium", "Low", "UltraLow"] {
            let item = NSMenuItem(title: name, action: #selector(changeQuality(_:)), keyEquivalent: "")
            item.target = self
            item.state = name == quality ? .on : .off
            qualityMenu.addItem(item)
        }
        let qualityItem = NSMenuItem(title: "Quality (alle Displays)", action: nil, keyEquivalent: "")
        qualityItem.submenu = qualityMenu
        menu.addItem(qualityItem)
        let solverMenu = NSMenu()
        for count in [8, 12, 18, 24, 30, 50] {
            let item = NSMenuItem(title: String(count), action: #selector(changeIterations(_:)), keyEquivalent: "")
            item.target = self
            item.tag = count
            item.state = count == iterations ? .on : .off
            solverMenu.addItem(item)
        }
        let solverItem = NSMenuItem(title: "Solver Iterations (alle Displays)", action: nil, keyEquivalent: "")
        solverItem.submenu = solverMenu
        menu.addItem(solverItem)
        let viscosityItem = NSMenuItem(title: "Zähigkeit (alle Displays)", action: nil, keyEquivalent: "")
        viscosityView = ViscositySliderView(value: viscosity, title: "Zähigkeit (alle Displays)") { [weak self] value in
            self?.changeViscosity(value)
        }
        viscosityItem.view = viscosityView
        menu.addItem(viscosityItem)
        let displaysItem = NSMenuItem(title: "Einstellungen pro Display", action: nil, keyEquivalent: "")
        displaysMenu = NSMenu()
        displaysItem.submenu = displaysMenu
        menu.addItem(displaysItem)
        menu.addItem(NSMenuItem(title: "Reset Particles", action: #selector(resetParticles), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop Fluid", action: #selector(stopFluid), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Neu laden", action: #selector(reload), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Beenden", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func loadPage(_ webView: WKWebView) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--url"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]), ["http", "https"].contains(url.scheme ?? "") {
            webView.load(URLRequest(url: url))
        } else if let index = arguments.firstIndex(of: "--html"), index + 1 < arguments.count {
            let url = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: URL(string: "https://haxiomic.github.io/GPU-Fluid-Experiments/html5/")!))
        }
    }

    @objc private func updateCursor() {
        routeCursor(at: NSEvent.mouseLocation)
    }

    private func desktopIsExposed(at point: CGPoint, windows: [[String: Any]]) -> Bool {
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let dockActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.dock"
        return DesktopVisibility.isExposed(at: point, windows: windows,
            ignoring: Set(surfaces.map { $0.window.windowNumber }),
            dockPID: dockActive ? nil : dockPID, displayBounds: surfaces.map { CGDisplayBounds($0.displayID) })
    }

    private func routeCursor(at point: NSPoint) {
        guard !interactive, followsCursor else { return }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let quartzPoint = DesktopVisibility.quartzPoint(point, primaryTop: primaryTop)
        let exposed = DesktopVisibility.visibleWindows().map {
            desktopIsExposed(at: quartzPoint, windows: $0)
        } ?? false
        for surface in surfaces where surface.pageReady && surface.window.isVisible {
            guard surface.window.frame.contains(point), exposed else {
                if surface.lastPoint != nil {
                    surface.webView.evaluateJavaScript("window.fluidWallpaperRelease()", completionHandler: nil)
                }
                surface.lastPoint = nil
                continue
            }
            guard point != surface.lastPoint else { continue }
            surface.lastPoint = point
            let x = point.x - surface.window.frame.minX
            let y = surface.window.frame.maxY - point.y
            surface.webView.evaluateJavaScript("window.fluidWallpaperPointer(\(x), \(y))", completionHandler: nil)
        }
    }

    private func checkDesktopVisibility() {
        let point = CGPoint(x: 150, y: 150)
        func entry(number: Int, layer: Int, alpha: Double = 1, x: CGFloat = 100) -> [String: Any] {
            [kCGWindowNumber as String: number, kCGWindowLayer as String: layer,
             kCGWindowAlpha as String: alpha,
             kCGWindowBounds as String: CGRect(x: x, y: 100, width: 200, height: 200).dictionaryRepresentation]
        }
        let desktop = entry(number: 1, layer: Int(CGWindowLevelForKey(.desktopIconWindow)))
        let normal = entry(number: 2, layer: Int(CGWindowLevelForKey(.normalWindow)))
        let dock = entry(number: 3, layer: Int(CGWindowLevelForKey(.dockWindow)))
        let menu = entry(number: 4, layer: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        let cases: [(String, [[String: Any]], Set<Int>, Bool)] = [
            ("free desktop", [desktop], [], true),
            ("normal window", [desktop, normal], [], false),
            ("dock", [desktop, dock], [], false),
            ("menu", [desktop, menu], [], false),
            ("transparent window", [desktop, entry(number: 5, layer: 0, alpha: 0)], [], true),
            ("window elsewhere", [desktop, entry(number: 6, layer: 0, x: 500)], [], true),
            ("own wallpaper", [desktop, normal], [2], true)
        ]
        for (name, windows, ignoring, expected) in cases {
            guard DesktopVisibility.isExposed(at: point, windows: windows, ignoring: ignoring) == expected else {
                print("Desktop visibility failed: \(name)")
                exit(1)
            }
            print("Desktop visibility passed: \(name)")
        }
        var backdrop = entry(number: 7, layer: Int(CGWindowLevelForKey(.dockWindow)))
        backdrop[kCGWindowOwnerPID as String] = Int32(999)
        backdrop[kCGWindowSharingState as String] = Int(CGWindowSharingType.none.rawValue)
        let displayBounds = [CGRect(x: 100, y: 100, width: 200, height: 200)]
        guard DesktopVisibility.isExposed(at: point, windows: [backdrop], ignoring: [], dockPID: 999, displayBounds: displayBounds),
              !DesktopVisibility.isExposed(at: point, windows: [backdrop], ignoring: [], dockPID: 999, displayBounds: []),
              !DesktopVisibility.isExposed(at: point, windows: [backdrop], ignoring: [], dockPID: 998, displayBounds: displayBounds),
              !DesktopVisibility.isExposed(at: point, windows: [backdrop, normal], ignoring: [], dockPID: 999, displayBounds: displayBounds) else {
            print("Dock backdrop classification failed")
            exit(1)
        }
        print("Dock desktop backdrop ignored; real windows and Dock panels still block")
        let primaryTop = NSScreen.screens.first!.frame.maxY
        for screen in NSScreen.screens {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            let converted = DesktopVisibility.quartzPoint(NSPoint(x: screen.frame.midX, y: screen.frame.midY), primaryTop: primaryTop)
            guard CGDisplayBounds(id).contains(converted) else {
                print("Display coordinate conversion failed: \(id)")
                exit(1)
            }
            print("Display coordinate conversion passed: \(id)")
        }
        let testWindow = NSWindow(contentRect: NSRect(x: 100, y: primaryTop - 300, width: 200, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false)
        testWindow.isReleasedWhenClosed = false
        testWindow.backgroundColor = .black
        testWindow.level = .normal
        testWindow.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let windows = DesktopVisibility.visibleWindows(),
                  windows.contains(where: { ($0[kCGWindowNumber as String] as? Int) == testWindow.windowNumber }),
                  !DesktopVisibility.isExposed(at: point, windows: windows, ignoring: []) else {
                print("Live window occlusion failed")
                exit(1)
            }
            testWindow.close()
            print("Live window occlusion passed without requesting screen capture")
            exit(0)
        }
    }

    @objc private func toggleInteraction() {
        interactive.toggle()
        interactionItem.state = interactive ? .on : .off
        for surface in surfaces {
            surface.window.ignoresMouseEvents = !interactive
            surface.window.level = interactive ? .normal : NSWindow.Level(rawValue:
                Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            surface.webView.evaluateJavaScript("window.fluidWallpaperRelease()", completionHandler: nil)
            surface.webView.evaluateJavaScript("window.fluidWallpaperInteraction?.(\(interactive))", completionHandler: nil)
            surface.lastPoint = nil
            surface.window.orderFrontRegardless()
        }
        if interactive {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if let surface = surfaces.first(where: { $0.window.frame.contains(NSEvent.mouseLocation) }) ?? surfaces.first {
                surface.window.makeKeyAndOrderFront(nil)
                surface.window.makeFirstResponder(surface.webView)
            }
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func toggleCursor() {
        followsCursor.toggle()
        cursorItem.state = followsCursor ? .on : .off
        for surface in surfaces {
            surface.webView.evaluateJavaScript("window.fluidWallpaperRelease()", completionHandler: nil)
            surface.lastPoint = nil
        }
    }

    @objc private func screenChanged() {
        let screens = NSScreen.screens
        let ids = screens.map { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value }
        for surface in surfaces where !ids.contains(surface.displayID) { surface.window.close() }
        surfaces.removeAll { !ids.contains($0.displayID) }
        for (screen, id) in zip(screens, ids) {
            if let surface = surfaces.first(where: { $0.displayID == id }) {
                surface.window.setFrame(screen.frame, display: true)
                surface.lastPoint = nil
                surface.displayName = screen.localizedName
            } else {
                let surface = createSurface(screen: screen)
                surface.quality = quality
                surface.iterations = iterations
                surface.viscosity = viscosity
                surfaces.append(surface)
                loadPage(surface.webView)
                surface.window.ignoresMouseEvents = !interactive
                if interactive { surface.window.level = .normal }
            }
        }
        refreshDisplayMenus()
        print("Wallpaper displays: \(surfaces.count)")
    }

    private func refreshDisplayMenus() {
        displaysMenu.removeAllItems()
        for surface in surfaces {
            let displayItem = NSMenuItem(title: "\(surface.displayName) (\(Int(surface.window.frame.width)) × \(Int(surface.window.frame.height)))", action: nil, keyEquivalent: "")
            let menu = NSMenu()
            displayItem.submenu = menu
            let qualityItem = NSMenuItem(title: "Quality: \(surface.quality)", action: nil, keyEquivalent: "")
            let qualityMenu = NSMenu()
            qualityItem.submenu = qualityMenu
            for name in ["SuperResolution", "UltraHigh", "High", "Medium", "Low", "UltraLow"] {
                let item = NSMenuItem(title: name, action: #selector(changeDisplayQuality(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: surface.displayID)
                item.state = name == surface.quality ? .on : .off
                qualityMenu.addItem(item)
            }
            menu.addItem(qualityItem)
            let solverItem = NSMenuItem(title: "Solver Iterations: \(surface.iterations)", action: nil, keyEquivalent: "")
            let solverMenu = NSMenu()
            solverItem.submenu = solverMenu
            for count in [8, 12, 14, 18, 20, 24, 30, 50] {
                let item = NSMenuItem(title: String(count), action: #selector(changeDisplayIterations(_:)), keyEquivalent: "")
                item.target = self
                item.tag = count
                item.representedObject = NSNumber(value: surface.displayID)
                item.state = count == surface.iterations ? .on : .off
                solverMenu.addItem(item)
            }
            menu.addItem(solverItem)
            let viscosityItem = NSMenuItem(title: "Zähigkeit", action: nil, keyEquivalent: "")
            viscosityItem.view = ViscositySliderView(value: surface.viscosity) { [weak self, weak surface] value in
                guard let self = self, let surface = surface else { return }
                self.setViscosity(value, for: surface)
                self.syncViscosityViews()
            }
            menu.addItem(viscosityItem)
            if let width = surface.renderInfo["fluidWidth"], let height = surface.renderInfo["fluidHeight"],
               let outputWidth = surface.renderInfo["outputWidth"], let outputHeight = surface.renderInfo["outputHeight"],
               let particles = surface.renderInfo["particles"] {
                menu.addItem(.separator())
                menu.addItem(NSMenuItem(title: "Fluid: \(width) × \(height)", action: nil, keyEquivalent: ""))
                menu.addItem(NSMenuItem(title: "Ausgabe: \(outputWidth) × \(outputHeight)", action: nil, keyEquivalent: ""))
                menu.addItem(NSMenuItem(title: "Partikel: \(particles)", action: nil, keyEquivalent: ""))
            }
            displaysMenu.addItem(displayItem)
        }
        for parent in statusItem.menu?.items ?? [] {
            if parent.title == "Quality (alle Displays)" {
                for item in parent.submenu?.items ?? [] {
                    item.state = !surfaces.isEmpty && surfaces.allSatisfy { $0.quality == item.title } ? .on : .off
                }
            } else if parent.title == "Solver Iterations (alle Displays)" {
                for item in parent.submenu?.items ?? [] {
                    item.state = !surfaces.isEmpty && surfaces.allSatisfy { $0.iterations == item.tag } ? .on : .off
                }
            }
        }
        syncViscosityViews()
    }

    private func setViscosity(_ value: Double, for surface: WallpaperSurface) {
        surface.viscosity = min(100, max(0, value))
        if surface.pageReady {
            surface.webView.evaluateJavaScript("window.fluidWallpaperSetting('wallpaperViscosity', \(surface.viscosity))") { _, error in
                if let error = error { NSLog("Viscosity setting failed: %@", error.localizedDescription) }
            }
        }
    }

    private func changeViscosity(_ value: Double) {
        viscosity = value
        for surface in surfaces { setViscosity(value, for: surface) }
        syncViscosityViews()
    }

    private func syncViscosityViews() {
        let firstValue = surfaces.first?.viscosity ?? viscosity
        let mixed = surfaces.contains { $0.viscosity != firstValue }
        viscosityView.setValue(mixed ? viscosity : firstValue, mixed: mixed)
        for (surface, item) in zip(surfaces, displaysMenu.items) {
            for child in item.submenu?.items ?? [] {
                (child.view as? ViscositySliderView)?.setValue(surface.viscosity)
            }
        }
    }

    private func applySettings(_ surface: WallpaperSurface) {
        guard surface.pageReady else { return }
        surface.webView.evaluateJavaScript("window.fluidWallpaperSetting?.('simulationQuality', '\(surface.quality)'); window.fluidWallpaperSetting?.('fluidIterations', \(surface.iterations)); window.fluidWallpaperSetting?.('wallpaperViscosity', \(surface.viscosity))") { _, error in
            if let error = error { NSLog("Display %u setting failed: %@", surface.displayID, error.localizedDescription) }
        }
    }

    @objc private func changeDisplayQuality(_ item: NSMenuItem) {
        guard let id = item.representedObject as? NSNumber,
              let surface = surfaces.first(where: { $0.displayID == id.uint32Value }) else { return }
        surface.quality = item.title
        surface.iterations = ["SuperResolution": 30, "UltraHigh": 30, "High": 20, "Medium": 18, "Low": 14, "UltraLow": 12][item.title] ?? 18
        applySettings(surface)
        refreshDisplayMenus()
    }

    @objc private func changeDisplayIterations(_ item: NSMenuItem) {
        guard let id = item.representedObject as? NSNumber,
              let surface = surfaces.first(where: { $0.displayID == id.uint32Value }) else { return }
        surface.iterations = item.tag
        if surface.pageReady {
            surface.webView.evaluateJavaScript("window.fluidWallpaperSetting('fluidIterations', \(surface.iterations))", completionHandler: nil)
        }
        refreshDisplayMenus()
    }

    private func runOnDisplays(_ script: String) {
        for surface in surfaces where surface.pageReady {
            surface.webView.evaluateJavaScript(script) { _, error in
                if let error = error { NSLog("Wallpaper setting failed: %@", error.localizedDescription) }
            }
        }
    }

    @objc private func changeQuality(_ item: NSMenuItem) {
        quality = item.title
        iterations = ["SuperResolution": 30, "UltraHigh": 30, "High": 20, "Medium": 18, "Low": 14, "UltraLow": 12][quality] ?? 18
        for surface in surfaces {
            surface.quality = quality
            surface.iterations = iterations
            applySettings(surface)
        }
        refreshDisplayMenus()
    }

    @objc private func changeIterations(_ item: NSMenuItem) {
        iterations = item.tag
        for surface in surfaces { surface.iterations = iterations }
        runOnDisplays("window.fluidWallpaperSetting('fluidIterations', \(iterations))")
        refreshDisplayMenus()
    }

    @objc private func resetParticles() { runOnDisplays("window.fluidWallpaperCommand('Reset Particles')") }
    @objc private func stopFluid() { runOnDisplays("window.fluidWallpaperCommand('Stop Fluid')") }
    @objc private func reload() {
        for surface in surfaces { surface.pageReady = false; surface.webView.reload() }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let surface = surfaces.first(where: { $0.webView === webView }) else { return }
        surface.pageReady = true
        surface.lastPoint = nil
        if CommandLine.arguments.contains("--viscous") { surface.viscosity = 65 }
        if CommandLine.arguments.contains("--super-resolution"), !CommandLine.arguments.contains("--check-displays") {
            surface.quality = "SuperResolution"
            surface.iterations = 30
        }
        applySettings(surface)
        if CommandLine.arguments.contains("--check-viscosity") {
            followsCursor = false
            viscosityView.slider.doubleValue = 65
            viscosityView.slider.sendAction(viscosityView.slider.action!, to: viscosityView.slider.target)
            webView.evaluateJavaScript("""
            (() => {
                const simulation = window.fluidWallpaperGUI.__controllers.find(c => c.property === 'simulationQuality').object;
                if (simulation.wallpaperViscosity !== 65) throw new Error('Native viscosity slider did not reach simulation');
                const result = checkFluidViscosity(simulation);
                window.fluidWallpaperSetting('simulationQuality', 'Low');
                if (simulation.wallpaperViscosity !== 65) throw new Error('Quality reset viscosity');
                return result;
            })()
            """) { result, error in
                guard error == nil, result != nil else {
                    print("Viscosity check failed: \(String(describing: error))")
                    exit(1)
                }
                print("Display \(surface.displayID) viscosity GPU check: \(String(describing: result))")
                self.checkedDisplays.insert(surface.displayID)
                if self.checkedDisplays.count == self.surfaces.count { exit(0) }
            }
        }
        webView.evaluateJavaScript("window.fluidWallpaperInteraction?.(\(interactive))", completionHandler: nil)
        if CommandLine.arguments.contains("--check-displays"), surfaces.allSatisfy({ $0.pageReady }) {
            checkDisplaySettings()
        }
        if CommandLine.arguments.contains("--check-cursor"), surfaces.allSatisfy({ $0.pageReady }) {
            checkCursorRouting()
        }
        if CommandLine.arguments.contains("--check") {
            followsCursor = false
            webView.evaluateJavaScript("""
            (() => {
                const gui = window.fluidWallpaperGUI;
                const controller = gui.__controllers.find(item => item.property === 'simulationQuality');
                const simulation = controller.object;
                const profiles = [
                    ['SuperResolution', 1048576, 0.5, 30, 1, 2],
                    ['UltraHigh', 1048576, 0.5, 30, 1],
                    ['High', 1048576, 0.25, 20, 1],
                    ['Medium', 262144, 0.25, 18, 1],
                    ['Low', 65536, 0.2, 14, 1],
                    ['UltraLow', 16384, 1 / 6, 12, 0.5]
                ];
                const results = profiles.map(([name, count, scale, iterations, outputScale, pixelScale = 1]) => {
                    window.fluidWallpaperSetting('simulationQuality', name);
                    window.dispatchEvent(new Event('resize'));
                    const viewport = simulation.windows[0];
                    const fluid = simulation.fluid;
                    const output = simulation.offScreenTarget;
                    if (String(simulation.simulationQuality) !== name || simulation.particles.count !== count ||
                        viewport.canvas.width !== Math.round(innerWidth * pixelScale) ||
                        viewport.canvas.height !== Math.round(innerHeight * pixelScale) ||
                        viewport.width !== viewport.canvas.width || viewport.height !== viewport.canvas.height ||
                        fluid.width !== Math.round(viewport.width * scale) ||
                        fluid.height !== Math.round(viewport.height * scale) ||
                        fluid.solverIterations !== iterations ||
                        output.width !== Math.round(viewport.width * outputScale) ||
                        output.height !== Math.round(viewport.height * outputScale) ||
                        simulation.performanceMonitor.fpsTooLowCallback !== null) {
                        throw new Error('Quality profile mismatch: ' + name);
                    }
                    return {quality: name, particles: count, fluid: [fluid.width, fluid.height],
                        output: [output.width, output.height], iterations: fluid.solverIterations};
                });
                window.fluidWallpaperSetting('simulationQuality', '\(CommandLine.arguments.contains("--super-resolution") ? "SuperResolution" : "Low")');
                const menu = document.querySelector('.dg.ac');
                if (getComputedStyle(menu).display !== 'none') throw new Error('Wallpaper menu visible');
                window.fluidWallpaperInteraction(true);
                if (getComputedStyle(menu).display === 'none') throw new Error('Interactive menu hidden');
                window.fluidWallpaperInteraction(false);
                return results;
            })()
            """) { result, error in
                guard error == nil, let profiles = result as? [[String: Any]], profiles.count == 6 else {
                    print("Quality check failed on display \(surface.displayID): \(String(describing: error))")
                    exit(1)
                }
                surface.qualityVerified = true
                let summary = profiles.map { "\($0["quality"] ?? "?"): \($0["particles"] ?? 0) particles, \($0["iterations"] ?? 0) iterations, output \($0["output"] ?? [])" }.joined(separator: "; ")
                print("Display \(surface.displayID) quality profiles verified: \(summary)")
            }
            webView.evaluateJavaScript("""
            let frame = 0;
            function stroke() {
                window.fluidWallpaperPointer(innerWidth * (0.25 + frame / 240),
                    innerHeight * (0.5 + 0.15 * Math.sin(frame / 12)));
                if (++frame < 120) {
                    requestAnimationFrame(stroke);
                } else {
                    requestAnimationFrame(() => requestAnimationFrame(() =>
                        window.webkit.messageHandlers.fluidCheck.postMessage('strokeFinished')));
                }
            }
            requestAnimationFrame(stroke);
            """, completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                if !self.checkedDisplays.contains(surface.displayID) {
                    print("Rendering check timed out on display \(surface.displayID)")
                    exit(1)
                }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "fluidSettings",
           let surface = surfaces.first(where: { $0.webView === message.webView }),
           let values = message.body as? [String: Any],
           let quality = values["quality"] as? String, let iterations = values["iterations"] as? Int {
            let oldQuality = surface.quality
            let oldIterations = surface.iterations
            let oldRenderInfo = surface.renderInfo
            surface.quality = quality
            surface.iterations = iterations
            surface.viscosity = values["viscosity"] as? Double ?? surface.viscosity
            for key in ["fluidWidth", "fluidHeight", "outputWidth", "outputHeight", "particles"] {
                surface.renderInfo[key] = values[key] as? Int
            }
            if oldQuality != quality || oldIterations != iterations || oldRenderInfo != surface.renderInfo {
                refreshDisplayMenus()
            } else {
                syncViscosityViews()
            }
            return
        }
        guard message.name == "fluidCheck", message.body as? String == "strokeFinished",
              let surface = surfaces.first(where: { $0.webView === message.webView }) else { return }
        checkPage(surface)
    }

    private func checkCursorRouting() {
        guard let windows = DesktopVisibility.visibleWindows() else { print("Window query failed"); exit(1) }
        let primaryTop = NSScreen.screens.first!.frame.maxY
        var remaining = surfaces.count
        followsCursor = true
        for surface in surfaces {
            let frame = surface.window.frame
            var available: NSPoint?
            for row in 1...9 {
                for column in 1...9 {
                    let point = NSPoint(x: frame.minX + frame.width * CGFloat(column) / 10,
                        y: frame.minY + frame.height * CGFloat(row) / 10)
                    if desktopIsExposed(at: DesktopVisibility.quartzPoint(point, primaryTop: primaryTop), windows: windows) {
                        available = point
                        break
                    }
                }
                if available != nil { break }
            }
            guard let point = available else {
                print("No exposed desktop test point on display \(surface.displayID); move covering windows away")
                exit(1)
            }
            routeCursor(at: point)
            let x = point.x - frame.minX
            let y = frame.maxY - point.y
            let pixelScale: CGFloat = surface.quality == "SuperResolution" ? 2 : 1
            surface.webView.evaluateJavaScript("""
            (() => {
                const simulation = window.fluidWallpaperGUI.__controllers.find(c => c.property === 'simulationQuality').object;
                return {x: simulation.mouse.x, y: simulation.mouse.y};
            })()
            """) { result, error in
                guard error == nil, let values = result as? [String: Double],
                          values["x"] == x.rounded(.towardZero) * pixelScale, values["y"] == y.rounded(.towardZero) * pixelScale else {
                    print("Cursor routing failed on display \(surface.displayID): \(String(describing: result)), \(String(describing: error))")
                    exit(1)
                }
                print("Display \(surface.displayID): exposed desktop cursor reached simulation at \(x), \(y)")
                remaining -= 1
                if remaining == 0 { exit(0) }
            }
        }
        followsCursor = false
    }

    private func checkDisplaySettings() {
        followsCursor = false
        guard surfaces.count >= 2 else { print("Display isolation check requires two displays"); exit(1) }
        let higherResolution = CommandLine.arguments.contains("--super-resolution")
        let secondQuality = higherResolution ? "SuperResolution" : "High"
        if !displayCheckReloaded {
            for (index, surface) in surfaces.enumerated() {
                let item = NSMenuItem(title: index == 0 ? "Low" : secondQuality, action: nil, keyEquivalent: "")
                item.representedObject = NSNumber(value: surface.displayID)
                changeDisplayQuality(item)
            }
            let solver = NSMenuItem(title: "8", action: nil, keyEquivalent: "")
            solver.tag = 8
            solver.representedObject = NSNumber(value: surfaces[0].displayID)
            changeDisplayIterations(solver)
        }
        var remaining = surfaces.count
        for (index, surface) in surfaces.enumerated() {
            let expectedQuality = index == 0 ? "Low" : secondQuality
            let expectedIterations = index == 0 ? 8 : (higherResolution ? 30 : 20)
            let expectedParticles = index == 0 ? 65536 : 1048576
            let scale = index == 0 ? 0.2 : (higherResolution ? 0.5 : 0.25)
            let pixelScale: CGFloat = index != 0 && higherResolution ? 2 : 1
            surface.webView.evaluateJavaScript("""
            (() => {
                const simulation = window.fluidWallpaperGUI.__controllers.find(c => c.property === 'simulationQuality').object;
                return {quality: String(simulation.simulationQuality), iterations: simulation.fluid.solverIterations,
                    particles: simulation.particles.count, width: simulation.fluid.width, height: simulation.fluid.height,
                    outputWidth: simulation.offScreenTarget.width, outputHeight: simulation.offScreenTarget.height};
            })()
            """) { result, error in
                guard error == nil, let values = result as? [String: Any],
                      values["quality"] as? String == expectedQuality,
                      values["iterations"] as? Int == expectedIterations,
                      values["particles"] as? Int == expectedParticles,
                      values["width"] as? Int == Int((surface.window.frame.width * pixelScale * scale).rounded()),
                      values["height"] as? Int == Int((surface.window.frame.height * pixelScale * scale).rounded()),
                      values["outputWidth"] as? Int == Int(surface.window.frame.width * pixelScale),
                      values["outputHeight"] as? Int == Int(surface.window.frame.height * pixelScale),
                      surface.renderInfo["fluidWidth"] == values["width"] as? Int,
                      surface.renderInfo["particles"] == expectedParticles,
                      surface.quality == expectedQuality, surface.iterations == expectedIterations else {
                    print("Display isolation check failed: \(surface.displayID), \(String(describing: result)), \(String(describing: error))")
                    exit(1)
                }
                print("Display \(surface.displayID) independent settings verified: \(values)")
                remaining -= 1
                if remaining == 0 {
                    if self.displayCheckReloaded { print("Independent display settings survive page reload"); exit(0) }
                    self.displayCheckReloaded = true
                    self.surfaces[0].pageReady = false
                    self.surfaces[0].webView.reload()
                }
            }
        }
    }

    private func checkPage(_ surface: WallpaperSurface) {
        let superResolution = CommandLine.arguments.contains("--super-resolution")
        let expectedQuality = superResolution ? "SuperResolution" : "Low"
        let expectedParticles = superResolution ? 1048576 : 65536
        let script = """
        (() => {
            const gui = window.fluidWallpaperGUI;
            const solver = gui?.__controllers.find(c => c.property === 'fluidIterations');
            const quality = gui?.__controllers.find(c => c.property === 'simulationQuality');
            if (quality) {
                quality.__select.value = '\(expectedQuality)';
                quality.__select.dispatchEvent(new Event('change', {bubbles: true}));
            }
            if (solver) {
                const input = solver.domElement.querySelector('input');
                input.value = '12';
                input.dispatchEvent(new Event('blur'));
            }
            const canvas = document.querySelector('canvas');
            let received = false;
            if (canvas) {
                canvas.addEventListener('mousemove', () => received = true, {once: true});
                window.fluidWallpaperPointer(100, 100);
            }
            return {canvas: !!canvas, width: canvas?.width, height: canvas?.height,
                menuHidden: getComputedStyle(document.querySelector('.dg.ac')).display === 'none',
                solver: solver?.object.fluid?.solverIterations,
                quality: String(quality?.object.simulationQuality),
                particles: quality?.object.particles.count,
                menu: document.querySelectorAll('.dg .cr').length, pointer: received};
        })()
        """
        surface.webView.evaluateJavaScript(script) { result, error in
            print("Display \(surface.displayID) check: \(String(describing: result)); error: \(String(describing: error))")
            guard let values = result as? [String: Any], values["canvas"] as? Bool == true,
                surface.qualityVerified, values["menuHidden"] as? Bool == true,
                  values["solver"] as? Int == 12, values["quality"] as? String == expectedQuality,
                  values["particles"] as? Int == expectedParticles,
                  values["pointer"] as? Bool == true, (values["menu"] as? Int ?? 0) >= 5 else {
                exit(1)
            }
            surface.webView.takeSnapshot(with: nil) { image, error in
                guard let image = image, let data = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: data) else {
                    print("Snapshot failed: \(String(describing: error))")
                    exit(1)
                }
                var colored = 0
                var blue = 0
                for row in stride(from: bitmap.pixelsHigh / 4, to: bitmap.pixelsHigh, by: 8) {
                    for column in stride(from: 0, to: bitmap.pixelsWide * 3 / 4, by: 8) {
                        if let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) {
                            if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.08 {
                                colored += 1
                            }
                            if color.blueComponent > 0.3 && color.blueComponent > color.redComponent * 1.5 {
                                blue += 1
                            }
                        }
                    }
                }
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "Export/wallpaper-check-\(surface.displayID).png"))
                }
                print("Rendered samples outside menu: \(colored); blue fluid samples: \(blue)")
                guard blue > 20 else { exit(1) }
                self.checkedDisplays.insert(surface.displayID)
                if self.checkedDisplays.count == self.surfaces.count { exit(0) }
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let alert = NSAlert()
        alert.messageText = "Fluid Wallpaper konnte nicht geladen werden"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

let app = NSApplication.shared
let delegate = WallpaperApp()
app.delegate = delegate
app.run()