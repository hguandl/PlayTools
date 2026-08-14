//
//  MacPlugin.swift
//  AKInterface
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import OSLog

// Add a lightweight struct so we can decode only the flag we care about
private struct AKAppSettingsData: Codable {
    var hideTitleBar: Bool?
    var floatingWindow: Bool?
    var resolution: Int?
    var resizableAspectRatioWidth: Int?
    var resizableAspectRatioHeight: Int?
}

class AKPlugin: NSObject, Plugin {
    private static let logger = Logger(subsystem: "PlayTools", category: "MaaTools")
    @MainActor private static var didLogSCKFallback = false

    // Cached ScreenCaptureKit filter. Building it requires enumerating all
    // shareable content, which is relatively expensive; MAA requests a frame
    // roughly once a second, so reuse the filter while the window is unchanged
    // and refresh it periodically.
    @MainActor
    @available(macOS 14.0, *)
    private final class SCKCache {
        var filter: SCContentFilter?
        var frame = CGRect.zero
        var windowID: CGWindowID = 0
        var refreshedAt = Date.distantPast

        func resolve(for windowNumber: Int) async throws -> (SCContentFilter, CGRect) {
            let now = Date()
            let windowID = CGWindowID(windowNumber)
            if let filter, self.windowID == windowID, now.timeIntervalSince(refreshedAt) < 3 {
                return (filter, frame)
            }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw SCKError.windowNotFound
            }
            let newFilter = SCContentFilter(desktopIndependentWindow: window)
            filter = newFilter
            frame = window.frame
            self.windowID = windowID
            refreshedAt = now
            return (newFilter, frame)
        }
    }

    private var sckCache: AnyObject?

    required override init() {
        super.init()
        if let window = NSApplication.shared.windows.first {
            window.styleMask.insert([.resizable])
            window.collectionBehavior = [.fullScreenPrimary, .managed, .participatesInCycle]
            window.isMovable = true
            window.isMovableByWindowBackground = true

            if self.hideTitleBarSetting == true {
                window.styleMask.insert([.fullSizeContentView])
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.toolbar = nil
                window.title = ""
            }

            if self.floatingWindowSetting == true {
                window.level = .floating
            }

            if let aspectRatio = self.aspectRatioSetting {
                window.contentAspectRatio = aspectRatio
            }

            NSWindow.allowsAutomaticWindowTabbing = true
        }

        // Apply the same appearance rules to any subsequent windows that may be created
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main) { notif in
                guard let win = notif.object as? NSWindow else { return }
                win.styleMask.insert([.resizable])

                if self.hideTitleBarSetting == true {
                    win.styleMask.insert([.fullSizeContentView])
                    win.titlebarAppearsTransparent = true
                    win.titleVisibility = .hidden
                    win.toolbar = nil
                    win.title = ""
                }

                if self.floatingWindowSetting == true {
                    win.level = .floating
                }

                if let aspectRatio = self.aspectRatioSetting {
                    win.contentAspectRatio = aspectRatio
                }
        }
    }

    var screenCount: Int {
        NSScreen.screens.count
    }

    var mousePoint: CGPoint {
        NSApplication.shared.windows.first?.mouseLocationOutsideOfEventStream ?? CGPoint()
    }

    var windowFrame: CGRect {
        NSApplication.shared.windows.first?.frame ?? CGRect()
    }

    var isMainScreenEqualToFirst: Bool {
        return NSScreen.main == NSScreen.screens.first
    }

    var mainScreenFrame: CGRect {
        return NSScreen.main!.frame as CGRect
    }

    var isFullscreen: Bool {
        NSApplication.shared.windows.first!.styleMask.contains(.fullScreen)
    }

    var windowTitle: String? {
        get {
            NSApplication.shared.windows.first?.title
        }
        set {
            if let newValue {
                DispatchQueue.main.async {
                    NSApplication.shared.windows.first?.title = newValue
                }
            }
        }
    }

    // Proactively ask for Screen Recording while the game is foreground. MAA's
    // screenshot requests arrive while the game is in the background, where
    // macOS suppresses the TCC prompt; asking here (at launch, after the
    // MaaTools switch is enabled) makes the system dialog appear and the user
    // can simply click Allow. Only invoked when MAA is enabled.
    @MainActor
    func requestScreenRecordingIfNeeded() async {
        if #available(macOS 14.0, *) {
            // Delay slightly so the app finishes coming to the foreground.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        }
    }

    var windowImage: CGImage? {
        guard let windowID = NSApplication.shared.windows.first?.windowNumber else {
            return nil
        }
        return CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(windowID), [.bestResolution, .boundsIgnoreFraming])
    }

    // Capture strategy: try the legacy CGWindowListCreateImage first (it works
    // on older macOS without needing Screen Recording permission). On macOS 27
    // beta it returns a flat dark frame for Metal content, so when the result
    // looks blank we fall back to ScreenCaptureKit, which captures the real
    // composited window content.
    @MainActor
    func captureImage() async -> CGImage? {
        let legacy = windowImage
        if let legacy = legacy, !looksBlank(legacy) {
            return legacy
        }
        if #available(macOS 14.0, *),
           let windowNumber = NSApplication.shared.windows.first?.windowNumber {
            do {
                let cache = (sckCache as? SCKCache) ?? SCKCache()
                let (filter, frame) = try await cache.resolve(for: windowNumber)
                sckCache = cache
                let config = SCStreamConfiguration()
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                config.width = Int(frame.width * scale)
                config.height = Int(frame.height * scale)
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                logSCKFallbackOnce()
                return image
            } catch {
                Self.logger.error("ScreenCaptureKit failed, returning legacy capture: \(error, privacy: .public)")
            }
        }
        return legacy
    }

    private enum SCKError: Error {
        case windowNotFound
    }

    @MainActor
    private func logSCKFallbackOnce() {
        guard !Self.didLogSCKFallback else { return }
        Self.didLogSCKFallback = true
        Self.logger.info("ScreenCaptureKit fallback active (legacy capture returns blank frames)")
    }

    // A blank/legacy-broken frame is nearly uniform, e.g. the flat dark frame
    // (everything ~44/255) or the flat bright frame (everything ~240/255) that
    // CGWindowListCreateImage returns for Metal windows on macOS 27 beta.
    // Real frames have contrast, so we treat low-contrast frames as blank and
    // fall back to ScreenCaptureKit. To avoid being fooled by the macOS title
    // bar (system-drawn, stays bright even when the Metal content below is
    // black), we skip the top ~12% of the frame plus a small edge margin
    // instead of assuming a fixed content aspect ratio.
    private func looksBlank(_ image: CGImage) -> Bool {
        let sw = 96, sh = 54
        var buf = [UInt8](repeating: 0, count: sw * sh * 4)
        guard let ctx = CGContext(data: &buf, width: sw, height: sh,
                                  bitsPerComponent: 8, bytesPerRow: sw * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return false
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        var maxV = 0
        var sum = 0
        var count = 0
        let topSkip = sh * 12 / 100
        let sideSkip = sw * 2 / 100
        for y in topSkip..<sh {
            for x in sideSkip..<(sw - sideSkip) {
                let o = (y * sw + x) * 4
                let v = Int(max(buf[o], buf[o + 1], buf[o + 2]))
                if v > maxV { maxV = v }
                sum += v
                count += 1
            }
        }
        let avg = count > 0 ? sum / count : 0
        return maxV < 80 || (avg < 60 && maxV - avg < 12) || (avg > 200 && maxV - avg < 12)
    }

    var windowContentRect: CGRect {
        guard let window = NSApplication.shared.windows.first else {
            return CGRect()
        }
        return window.contentRect(forFrameRect: window.frame)
    }

    var cmdPressed: Bool = false
    var cursorHideLevel = 0
    func hideCursor() {
        NSCursor.hide()
        cursorHideLevel += 1
        CGAssociateMouseAndMouseCursorPosition(0)
        warpCursor()
    }

    func hideCursorMove() {
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func warpCursor() {
        guard let firstScreen = NSScreen.screens.first else {return}
        let frame = windowFrame
        // Convert from NS coordinates to CG coordinates
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: firstScreen.frame.height - frame.midY))
    }

    func unhideCursor() {
        NSCursor.unhide()
        cursorHideLevel -= 1
        if cursorHideLevel <= 0 {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    func terminateApplication() {
        NSApplication.shared.terminate(self)
    }

    private var modifierFlag: UInt = 0

    // swiftlint:disable:next function_body_length
    func setupKeyboard(keyboard: @escaping (UInt16, Bool, Bool, Bool) -> Bool,
                       swapMode: @escaping () -> Bool) {
        func checkCmd(modifier: NSEvent.ModifierFlags) -> Bool {
            if modifier.contains(.command) {
                self.cmdPressed = true
                return true
            } else if self.cmdPressed {
                self.cmdPressed = false
            }
            return false
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            if checkCmd(modifier: event.modifierFlags) {
                return event
            }
            let consumed = keyboard(event.keyCode, true, event.isARepeat,
                                    event.modifierFlags.contains(.control))
            if consumed {
                return nil
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: .keyUp, handler: { event in
            if checkCmd(modifier: event.modifierFlags) {
                return event
            }
            let consumed = keyboard(event.keyCode, false, false,
                                    event.modifierFlags.contains(.control))
            if consumed {
                return nil
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            if checkCmd(modifier: event.modifierFlags) {
                return event
            }
            let pressed = self.modifierFlag < event.modifierFlags.rawValue
            let changed = self.modifierFlag ^ event.modifierFlags.rawValue
            self.modifierFlag = event.modifierFlags.rawValue
            let changedFlags = NSEvent.ModifierFlags(rawValue: changed)
            if pressed && changedFlags.contains(.option) {
                if swapMode() {
                    return nil
                }
                return event
            }
            let consumed = keyboard(event.keyCode, pressed, false,
                                    event.modifierFlags.contains(.control))
            if consumed {
                return nil
            }
            return event
        })
    }

    func setupMouseMoved(_ mouseMoved: @escaping (CGFloat, CGFloat) -> Bool) {
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .otherMouseDragged, .rightMouseDragged]
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            let consumed = mouseMoved(event.deltaX, event.deltaY)
            if consumed {
                return nil
            }
            return event
        })
        // transpass mouse moved event when no button pressed, for traffic light button to light up
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            _ = mouseMoved(event.deltaX, event.deltaY)
            return event
        })
    }

    func setupMouseButton(left: Bool, right: Bool, _ consumed: @escaping (Int, Bool) -> Bool) {
        let downType: NSEvent.EventTypeMask = left ? .leftMouseDown : right ? .rightMouseDown : .otherMouseDown
        let upType: NSEvent.EventTypeMask = left ? .leftMouseUp : right ? .rightMouseUp : .otherMouseUp

        // Helper to detect whether the event is inside any of the window "traffic-light" buttons
        func isInTrafficLightArea(_ event: NSEvent) -> Bool {
            if self.hideTitleBarSetting == false {
                return false
            }
            guard let win = event.window else { return false }
            let pointInWindow = event.locationInWindow
            let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton, .fullScreenButton]
            for type in buttonTypes {
                if let button = win.standardWindowButton(type) {
                    let localPoint = button.convert(pointInWindow, from: nil) // convert from window coords
                    if button.bounds.contains(localPoint) {
                        return true
                    }
                }
            }
            return false
        }

        NSEvent.addLocalMonitorForEvents(matching: downType, handler: { event in
            // Always allow clicks on the window traffic-light buttons to pass through
            if isInTrafficLightArea(event) {
                return event
            }

            // Detect double-clicks on the title-bar area (respecting system preference)

            if left && event.clickCount == 2, self.hideTitleBarSetting, let win = event.window {
                let contentRect = win.contentLayoutRect
                // Title-bar area is the region above contentLayoutRect
                if event.locationInWindow.y > contentRect.maxY {
                    win.performZoom(nil)
                    return nil
                }
            }

            // For traffic light buttons when fullscreen
            if event.window != NSApplication.shared.windows.first! {
                return event
            }
            if consumed(event.buttonNumber, true) {
                return nil
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: upType, handler: { event in
            // Always allow releases on the traffic-light buttons to pass through
            if isInTrafficLightArea(event) {
                return event
            }
            if consumed(event.buttonNumber, false) {
                return nil
            }
            return event
        })
    }

    func setupScrollWheel(_ onMoved: @escaping (CGFloat, CGFloat) -> Bool) {
        NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask.scrollWheel, handler: { event in
            var deltaX = event.scrollingDeltaX, deltaY = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas {
                deltaX *= 16
                deltaY *= 16
            }
            let consumed = onMoved(deltaX, deltaY)
            if consumed {
                return nil
            }
            return event
        })
    }

    func urlForApplicationWithBundleIdentifier(_ value: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
    }

    func setMenuBarVisible(_ visible: Bool) {
        NSMenu.setMenuBarVisible(visible)
    }

    /// Convenience instance property that exposes the cached static preference.
    private var hideTitleBarSetting: Bool { Self.akAppSettingsData?.hideTitleBar ?? false }
    private var floatingWindowSetting: Bool { Self.akAppSettingsData?.floatingWindow ?? false }
    private var aspectRatioSetting: NSSize? {
        guard Self.akAppSettingsData?.resolution == 6 else {
            return nil
        }
        let width = Self.akAppSettingsData?.resizableAspectRatioWidth ?? 0
        let height = Self.akAppSettingsData?.resizableAspectRatioHeight ?? 0
        guard width > 0 && height > 0 else {
            return nil
        }
        return NSSize(width: width, height: height)
    }

    fileprivate static var akAppSettingsData: AKAppSettingsData? = {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        let settingsURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("App Settings")
            .appendingPathComponent("\(bundleIdentifier).plist")
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? PropertyListDecoder().decode(AKAppSettingsData.self, from: data) else {
            return nil
        }
        return decoded
    }()
}
