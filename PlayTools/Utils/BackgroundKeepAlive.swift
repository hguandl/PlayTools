//
//  BackgroundKeepAlive.swift
//  PlayTools
//

import AVFoundation
import os

// Since macOS 15, runningboardd freezes iOS apps as soon as their scene is
// no longer visible. Like on iOS, an app that is actively playing audio is
// exempt, so keep an inaudible player running for the whole app lifetime.
// Requires "UIBackgroundModes: [audio]" in the app's Info.plist.
@available(iOS 18.0, *)
class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()
    static let log = Logger(subsystem: "io.playcover.PlayTools", category: "BackgroundKeepAlive")

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var silence: AVAudioPCMBuffer?

    // The OS legitimately moves the scene to background when it becomes
    // invisible (the signal does not come from NSWindow.occlusionState, so it
    // cannot be spoofed there). Games then pause themselves per the iOS
    // lifecycle convention. Audio playback already prevents the OS-side
    // suspension, so it is sufficient to hide the background transition from
    // the app: drop the lifecycle notifications and neuter the corresponding
    // app/scene delegate callbacks.
    // Name is shared with AKInterface, which posts it from its
    // NSApplication.terminate hook before the actual termination starts.
    static let willTerminateNotification =
        Notification.Name("io.playcover.PlayTools.applicationWillTerminate")

    // Cleared once termination starts: the shutdown sequence replays exactly
    // the suppressed lifecycle events (resign active, enter background) so the
    // game can save its state — from that point on they must reach the app.
    private enum LifecycleState {
        case inactive, active, interrupted, terminating
    }
    private static let lifecycleState = OSAllocatedUnfairLock(initialState: LifecycleState.inactive)

    private static var suppressionActive: Bool {
        lifecycleState.withLock { $0 == .active }
    }

    private static func setSuppressionActive(_ active: Bool) {
        lifecycleState.withLock { state in
            guard state != .terminating, state != .interrupted else { return }
            state = active ? .active : .inactive
        }
    }

    private static func setInterrupted(_ interrupted: Bool) {
        lifecycleState.withLock { state in
            guard state != .terminating else { return }
            state = interrupted ? .interrupted : .inactive
        }
    }

    private static func beginTermination() -> Bool {
        lifecycleState.withLock { state in
            guard state != .terminating else { return false }
            state = .terminating
            return true
        }
    }

    private static var canRun: Bool {
        lifecycleState.withLock { $0 == .inactive || $0 == .active }
    }

    private static let suppressedNotifications: Set<String> = [
        UIApplication.willResignActiveNotification.rawValue,
        UIApplication.didEnterBackgroundNotification.rawValue,
        UIScene.willDeactivateNotification.rawValue,
        UIScene.didEnterBackgroundNotification.rawValue
    ]

    private func suppressBackgroundLifecycle() {
        Self.installPostFilter(NSSelectorFromString("postNotificationName:object:userInfo:"))
        Self.installPostFilter(NSSelectorFromString("postNotification:"))

        NotificationCenter.default.addObserver(forName: UIScene.willConnectNotification,
                                               object: nil, queue: .main) { notif in
            guard let scene = notif.object as? UIScene, let delegate = scene.delegate else { return }
            Self.neuter(type(of: delegate), "sceneDidEnterBackground:")
            Self.neuter(type(of: delegate), "sceneWillResignActive:")
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didFinishLaunchingNotification,
                                               object: nil, queue: .main) { _ in
            guard let delegate = UIApplication.shared.delegate else { return }
            Self.neuter(type(of: delegate), "applicationDidEnterBackground:")
            Self.neuter(type(of: delegate), "applicationWillResignActive:")
        }
    }

    private static func installPostFilter(_ selector: Selector) {
        guard let method = class_getInstanceMethod(NotificationCenter.self, selector) else { return }
        let originalImp = method_getImplementation(method)
        if selector == NSSelectorFromString("postNotification:") {
            typealias PostFn = @convention(c) (NotificationCenter, Selector, NSNotification) -> Void
            let original = unsafeBitCast(originalImp, to: PostFn.self)
            let block: @convention(block) (NotificationCenter, NSNotification) -> Void = { center, notif in
                if center === NotificationCenter.default
                    && suppressedNotifications.contains(notif.name.rawValue) && suppressionActive {
                    log.debug("suppressed post: \(notif.name.rawValue, privacy: .public)")
                    return
                }
                original(center, selector, notif)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        } else {
            typealias PostNameFn = @convention(c)
                (NotificationCenter, Selector, NSString, AnyObject?, NSDictionary?) -> Void
            let original = unsafeBitCast(originalImp, to: PostNameFn.self)
            let block: @convention(block)
                (NotificationCenter, NSString, AnyObject?, NSDictionary?) -> Void = { center, name, obj, info in
                if center === NotificationCenter.default
                    && suppressedNotifications.contains(name as String) && suppressionActive {
                    log.debug("suppressed postName: \(name, privacy: .public)")
                    return
                }
                original(center, selector, name, obj, info)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    private static func neuter(_ cls: AnyClass, _ selectorName: String) {
        let selector = NSSelectorFromString(selectorName)
        guard let method = class_getInstanceMethod(cls, selector) else {
            log.error("neuter: \(String(describing: cls), privacy: .public) has no \(selectorName, privacy: .public)")
            return
        }
        typealias LifecycleFn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: LifecycleFn.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { target, arg in
            if suppressionActive {
                log.debug("neutered call: \(selectorName, privacy: .public)")
                return
            }
            original(target, selector, arg)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        log.notice("neutered: \(String(describing: cls), privacy: .public).\(selectorName, privacy: .public)")
    }

    // Stop hiding the background transition and release the audio exemption
    // so the app can shut down cleanly. Without this, the game never receives
    // its save-and-quit lifecycle events and the process lingers half-dead.
    func prepareForTermination() {
        guard Self.beginTermination() else { return }
        if engine.isRunning {
            player.stop()
            engine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false)
        Self.log.notice("terminating: suppression disabled, silent audio stopped")
    }

    func start() {
        suppressBackgroundLifecycle()

        // AKInterface posts this from its NSApplication.terminate hook, which
        // covers Cmd+Q, the menu item and quitting from the Dock. Observe with
        // queue nil so it runs synchronously before termination proceeds.
        NotificationCenter.default.addObserver(forName: Self.willTerminateNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.prepareForTermination()
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            Self.log.error("audio session setup failed: \(error, privacy: .public)")
            return
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100) else {
            Self.log.error("could not create silence buffer")
            return
        }
        buffer.frameLength = buffer.frameCapacity
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
            }
        }
        silence = buffer

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        // The engine stops on output device changes and session interruptions;
        // restart it or the suspension exemption is silently lost.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine,
                                               queue: .main) { [weak self] _ in
            self?.ensureRunning()
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: nil,
                                               queue: .main) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            switch type {
            case .began:
                Self.setInterrupted(true)
            case .ended:
                Self.setInterrupted(false)
                self?.ensureRunning()
            @unknown default:
                break
            }
        }

        ensureRunning()
    }

    private func ensureRunning() {
        guard Self.canRun, let silence = silence else { return }
        Self.setSuppressionActive(false)
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                try engine.start()
            }
            if !player.isPlaying {
                player.scheduleBuffer(silence, at: nil, options: .loops)
                player.play()
            }
            Self.setSuppressionActive(engine.isRunning && player.isPlaying)
            Self.log.notice("silent audio running")
        } catch {
            Self.log.error("audio playback restart failed: \(error, privacy: .public)")
        }
    }
}
