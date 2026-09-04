//
//  AKPluginLoader.swift
//  PlayTools
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import Foundation
import OSLog

class AKInterface {
    public static var shared: Plugin?

    public static func initialize() {
        shared = loadPlugin()
    }

    private static func loadPlugin() -> Plugin? {
        // 1. Form the plugin's bundle URL
        guard let bundleURL = Bundle.main.builtInPlugInsURL?
                                    .appendingPathComponent("AKInterface")
                                    .appendingPathExtension("bundle") else { return nil }

        // 2. Create a bundle instance with the plugin URL
        guard let bundle = Bundle(url: bundleURL) else { return nil }

        // 3. Load the bundle and our plugin class
        guard let pluginClass = bundle.principalClass as? Plugin.Type else { return nil }

        let logger = Logger(subsystem: "PlayTools", category: "MaaTools")
        let sckAvailable: Bool

        if #available(iOS 18.2, *) {
            logger.info("Available iOS 18.2, enabling ScreenCaptureKit")
            sckAvailable = true
        } else {
            logger.info("Unavailable iOS 18.2, fallback to Core Graphics")
            sckAvailable = false
        }

        // 4. Create an instance of the plugin class
        return pluginClass.init(sckAvailable: sckAvailable)
    }
}
