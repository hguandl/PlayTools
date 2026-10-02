//
//  MacPlugin.swift
//  AKInterface
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

// Add a lightweight struct so we can decode only the flag we care about
private struct AKAppSettingsData: Codable {
    var hideTitleBar: Bool?
    var floatingWindow: Bool?
    var resolution: Int?
    var resizableAspectRatioWidth: Int?
    var resizableAspectRatioHeight: Int?
}

// swiftlint:disable file_length type_body_length

class AKPlugin: NSObject, Plugin {
    required init(sckAvailable: Bool) {
        self.sckAvailable = sckAvailable
        super.init()
        Self.hookTermination()
        if let window = NSApplication.shared.windows.first {
            window.collectionBehavior = [.fullScreenPrimary, .managed, .participatesInCycle]
            window.isMovable = true
            window.isMovableByWindowBackground = true
            applyWindowSettings(to: window)
            NSWindow.allowsAutomaticWindowTabbing = true
        }

        // Apply the same appearance rules to any subsequent windows that may be created
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main) { notif in
                guard let win = notif.object as? NSWindow else { return }
                self.applyWindowSettings(to: win)
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

    let sckAvailable: Bool

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

    private let logger = Logger(subsystem: "PlayTools", category: "MaaTools")

    @MainActor private var windowID: CGWindowID? {
        guard let windowNumber = NSApplication.shared.windows.first?.windowNumber else {
            logger.error("Cannot find any window of the app")
            return nil
        }
        return CGWindowID(windowNumber)
    }

    private func windowBounds(windowID: CGWindowID) -> CGRect? {
        let infoList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
        for info in infoList as? [[CFString: Any]] ?? [] {
            guard let number = info[kCGWindowNumber] as? NSNumber,
                  number.int32Value == windowID else {
                continue
            }
            if let dictionary = info[kCGWindowBounds] as? NSDictionary {
                return CGRect(dictionaryRepresentation: dictionary)
            }
        }
        return nil
    }

    @MainActor private var windowImage: CGImage? {
        guard let windowID else {
            return nil
        }
        guard var windowBounds = windowBounds(windowID: windowID) else {
            logger.error("Cannot find the information of the window")
            return nil
        }
        let size = windowContentRect.size
        guard size.height <= windowBounds.height else {
            logger.error("Invalid height: inner \(size.height), outer \(windowBounds.height)")
            return nil
        }
        let titlebarHeight = windowBounds.height - size.height
        windowBounds.origin.y += titlebarHeight
        windowBounds.size = size
        return CGWindowListCreateImage(windowBounds, .optionIncludingWindow, windowID,
                                       [.bestResolution, .boundsIgnoreFraming, .shouldBeOpaque])
    }

    private struct WindowViewport {
        let contentView: NSView
        let child: NSView
        let contentBounds: CGRect
        let contentFrame: CGRect
        let childBounds: CGRect
        let childFrame: CGRect
        let flipped: Bool
        let convertedRect: CGRect
        let imageTopRect: CGRect

        func matches(_ other: WindowViewport) -> Bool {
            contentView === other.contentView && child === other.child &&
                contentBounds == other.contentBounds && contentFrame == other.contentFrame &&
                childBounds == other.childBounds && childFrame == other.childFrame &&
                flipped == other.flipped && convertedRect == other.convertedRect &&
                imageTopRect == other.imageTopRect
        }
    }

    @MainActor private func windowViewport(_ window: NSWindow, size: CGSize) -> WindowViewport? {
        func finite(_ rect: CGRect) -> Bool {
            rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
        }
        guard let contentView = window.contentView,
              finite(contentView.bounds), finite(contentView.frame),
              contentView.bounds.size == size, size.width > 0, size.height > 0 else {
            logger.error("Invalid fullscreen content view geometry")
            return nil
        }
        // Logical visibility remains usable when the window is on another Space.
        let children = contentView.subviews.filter { !$0.isHidden && $0.alphaValue > 0 }
        guard children.count == 1, let child = children.first,
              finite(child.bounds), finite(child.frame) else {
            logger.error("Fullscreen viewport requires one visible direct child")
            return nil
        }
        let converted = child.convert(child.bounds, to: contentView)
        guard finite(converted), converted.width > 0, converted.height > 0,
              contentView.bounds.contains(converted) else {
            logger.error("Invalid fullscreen child viewport")
            return nil
        }
        let imageTop = CGRect(x: converted.minX - contentView.bounds.minX,
                              y: contentView.isFlipped ? converted.minY - contentView.bounds.minY :
                                  contentView.bounds.maxY - converted.maxY,
                              width: converted.width, height: converted.height)
        return WindowViewport(contentView: contentView, child: child,
                              contentBounds: contentView.bounds, contentFrame: contentView.frame,
                              childBounds: child.bounds, childFrame: child.frame,
                              flipped: contentView.isFlipped, convertedRect: converted, imageTopRect: imageTop)
    }

    private static func copyImage(_ pixels: CVPixelBuffer) -> CGImage? {
        guard !CVPixelBufferIsPlanar(pixels),
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { _ = CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        guard width > 0, height > 0, width <= Int.max / 4,
              rowBytes >= width * 4, height <= Int.max / rowBytes,
              let base = CVPixelBufferGetBaseAddress(pixels),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes: base, count: rowBytes * height) as CFData)
        else { return nil }
        let bitmap = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: bitmap,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    @available(macOS 14.4, macCatalyst 14.4, *)
    @MainActor private func captureImage(_ windowID: CGWindowID, size: CGSize,
                                         frameSize: CGSize, viewport: CGRect?) async throws -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let content = try await SCShareableContent.currentProcess
        guard !Task.isCancelled else { return nil }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            logger.error("Cannot find the shareable content of the window")
            return nil
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let rect = info.contentRect
        let scale = CGFloat(info.pointPixelScale)
        // SCK metadata can retain the previous window size after a resize.
        guard rect.size == frameSize,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              rect.width.isFinite, rect.height.isFinite,
              size.width <= rect.width, size.height <= rect.height,
              scale.isFinite, scale > 0 else {
            logger.error("Invalid geometry: \(size.width)x\(size.height) in \(rect.width)x\(rect.height) @\(scale)")
            return nil
        }
        let fullWidth = ceil(rect.width * scale)
        let fullHeight = ceil(rect.height * scale)
        let contentWidth = ceil(size.width * scale)
        let contentHeight = ceil(size.height * scale)
        guard fullWidth.isFinite, fullHeight.isFinite, contentWidth.isFinite, contentHeight.isFinite,
              contentWidth > 0, contentHeight > 0,
              fullWidth < CGFloat(Int.max), fullHeight < CGFloat(Int.max) else {
            logger.error("Invalid capture pixel dimensions")
            return nil
        }
        let config = SCStreamConfiguration()
        config.width = Int(fullWidth)
        config.height = Int(fullHeight)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.shouldBeOpaque = true
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.captureResolution = .best
        let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter,
                                                                     configuration: config)
        guard !Task.isCancelled else { return nil }
        guard sample.isValid, CMSampleBufferDataIsReady(sample),
              let pixels = sample.imageBuffer,
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else {
            logger.error("Invalid or unready BGRA screenshot sample")
            return nil
        }
        let image = Self.copyImage(pixels)
        guard !Task.isCancelled, let image else { return nil }
        guard image.width == config.width, image.height == config.height else {
            logger.error("Capture size mismatch: \(image.width)x\(image.height) != \(config.width)x\(config.height)")
            return nil
        }
        return cropWindowImage(image, contentWidth: Int(contentWidth), contentHeight: Int(contentHeight),
                               scale: scale, viewport: viewport)
    }

    private func cropWindowImage(_ image: CGImage, contentWidth: Int, contentHeight: Int,
                                 scale: CGFloat, viewport: CGRect?) -> CGImage? {
        // Crop in image coordinates after whole-window acquisition.
        let cropRect = CGRect(x: 0, y: image.height - contentHeight,
                              width: contentWidth, height: contentHeight)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard bounds.contains(cropRect), let cropped = image.cropping(to: cropRect),
              cropped.width == contentWidth, cropped.height == contentHeight else {
            logger.error("""
                Invalid capture crop: x=\(cropRect.minX) y=\(cropRect.minY) \
                \(cropRect.width)x\(cropRect.height), image \(image.width)x\(image.height)
                """)
            return nil
        }
        guard let viewport else { return cropped }
        let minX = floor(viewport.minX * scale)
        let minY = floor(viewport.minY * scale)
        let maxX = ceil(viewport.maxX * scale)
        let maxY = ceil(viewport.maxY * scale)
        let viewportPixels = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let croppedBounds = CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height)
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite,
              viewportPixels.width > 0, viewportPixels.height > 0,
              croppedBounds.contains(viewportPixels),
              let viewportImage = cropped.cropping(to: viewportPixels),
              viewportImage.width == Int(viewportPixels.width),
              viewportImage.height == Int(viewportPixels.height) else {
            logger.error("Invalid fullscreen viewport pixel crop")
            return nil
        }
        return viewportImage
    }

    @MainActor func windowImage() async -> CGImage? {
        if #available(macOS 14.4, macCatalyst 14.4, *), sckAvailable {
            do {
                guard let window = NSApplication.shared.windows.first else { return nil }
                let windowNumber = window.windowNumber
                let frameSize = window.frame.size
                let size = window.contentRect(forFrameRect: window.frame).size
                let minimized = window.isMiniaturized
                let fullscreen = window.styleMask.contains(.fullScreen)
                let activeSpace = window.isOnActiveSpace
                let viewport: WindowViewport?
                if !minimized && fullscreen {
                    guard let current = windowViewport(window, size: size) else { return nil }
                    viewport = current
                } else {
                    viewport = nil
                }
                // Keep fullscreen framing consistent across active and inactive Spaces.
                let image = try await captureImage(CGWindowID(windowNumber), size: size,
                                                  frameSize: frameSize, viewport: viewport?.imageTopRect)
                // Endpoint checks cannot detect a transition back to the original state.
                guard NSApplication.shared.windows.contains(where: { $0 === window }),
                      window.windowNumber == windowNumber,
                      window.frame.size == frameSize,
                      window.contentRect(forFrameRect: window.frame).size == size,
                      window.isMiniaturized == minimized,
                      window.styleMask.contains(.fullScreen) == fullscreen,
                      window.isOnActiveSpace == activeSpace else {
                    logger.error("Window changed during capture")
                    return nil
                }
                if let viewport {
                    guard let current = windowViewport(window, size: size), viewport.matches(current) else {
                        logger.error("Fullscreen viewport changed during capture")
                        return nil
                    }
                }
                return image
            } catch {
                logger.error("ScreenCaptureKit current-process capture failed: \(error)")
                return nil
            }
        } else {
            return windowImage
        }
    }

    var windowContentRect: CGRect {
        guard let window = NSApplication.shared.windows.first else {
            return CGRect()
        }
        return window.contentRect(forFrameRect: window.frame)
    }

    var cmdPressed: Bool = false
    var cursorHideLevel = 0
    fileprivate var modifierFlag: UInt = 0

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

    func urlForApplicationWithBundleIdentifier(_ value: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
    }

    func setMenuBarVisible(_ visible: Bool) {
        NSMenu.setMenuBarVisible(visible)
    }

    // All quit paths (Cmd+Q, menu, Dock, the close-button handler in
    // PlayTools) funnel through NSApplication.terminate. Announce the
    // termination so the background keep-alive in PlayTools can stand down
    // and let the shutdown lifecycle reach the app again. Posting the
    // notification is a no-op when nobody listens.
    private static func hookTermination() {
        let selector = #selector(NSApplication.terminate(_:))
        guard let method = class_getInstanceMethod(NSApplication.self, selector) else { return }
        typealias TerminateFn = @convention(c) (NSApplication, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: TerminateFn.self)
        let block: @convention(block) (NSApplication, AnyObject?) -> Void = { app, sender in
            NotificationCenter.default.post(
                name: Notification.Name("io.playcover.PlayTools.applicationWillTerminate"),
                object: nil)
            original(app, selector, sender)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

// MARK: - Window appearance

extension AKPlugin {
    fileprivate func applyWindowSettings(to window: NSWindow) {
        window.styleMask.insert([.resizable])

        if hideTitleBarSetting {
            window.styleMask.insert([.fullSizeContentView])
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbar = nil
            window.title = ""
        }

        if floatingWindowSetting {
            window.level = .floating
        }

        if let aspectRatio = aspectRatioSetting {
            window.contentAspectRatio = aspectRatio
        }
    }
}

// MARK: - Input events

extension AKPlugin {
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
            if !self.hideTitleBarSetting {
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
}

// MARK: - App settings

extension AKPlugin {
    fileprivate var hideTitleBarSetting: Bool { Self.akAppSettingsData?.hideTitleBar ?? false }
    fileprivate var floatingWindowSetting: Bool { Self.akAppSettingsData?.floatingWindow ?? false }
    fileprivate var aspectRatioSetting: NSSize? {
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

// swiftlint:enable file_length type_body_length
