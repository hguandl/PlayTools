//
//  MaaTools.swift
//  PlayTools
//
//  Created by hguandl on 21/3/2023.
//

import Accelerate
import Network
import OSLog

private let MAA_TOOLS_VERSION = 3

@MainActor final class MaaTools {
    public static let shared = MaaTools()

    private let logger = Logger(subsystem: "PlayTools", category: "MaaTools")
    private let queue = DispatchQueue(label: "MaaTools", qos: .default)
    private var listener: NWListener?

    private var windowTitle: String?
    private var tid: Int?

    private var scale = 1.0
    private var width = 0
    private var height = 0

    // ['M', 'A', 'A', 0x00]
    private let connectionMagic = Data([0x4d, 0x41, 0x41, 0x00])
    // ['S', 'C', 'R', 'N']
    private let screencapMagic = Data([0x53, 0x43, 0x52, 0x4e])
    // ['S', 'I', 'Z', 'E']
    private let sizeMagic = Data([0x53, 0x49, 0x5a, 0x45])
    // ['T', 'E', 'R', 'M']
    private let terminateMagic = Data([0x54, 0x45, 0x52, 0x4d])
    // ['T', 'U', 'C', 'H']
    private let toucherMagic = Data([0x54, 0x55, 0x43, 0x48])
    // ['V', 'E', 'R', 'N']
    private let versionMagic = Data([0x56, 0x45, 0x52, 0x4e])
    // ['B', 'N', 'D', 'L']
    private let bundleMagic = Data([0x42, 0x4e, 0x44, 0x4c])
    // ['R', 'E', 'C', 'T']
    private let rectMagic = Data([0x52, 0x45, 0x43, 0x54])
    // ['B', 'G', 'R', 0x01]
    private let bgrMagic = Data([0x42, 0x47, 0x52, 0x01])

    func initialize() {
        guard PlaySettings.shared.maaTools else { return }

        Task {
            // Wait for window
            while width == 0 || height == 0 || windowTitle == nil {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                setupWindow()
            }

            startServer()
        }
    }

    private func setupWindow() {
        let window = UIApplication.shared.connectedScenes
            .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
            .first { $0.isKeyWindow }

        if let screen = window?.windowScene?.screen {
            scale = screen.nativeScale
            width = Int(screen.nativeBounds.width.rounded())
            height = Int(screen.nativeBounds.height.rounded())
        }

        windowTitle = AKInterface.shared?.windowTitle
    }

    private func startServer() {
        let port = NWEndpoint.Port(rawValue: UInt16(PlaySettings.shared.maaToolsPort & 0xffff)) ?? .any
        listener = try? NWListener(using: .tcp, on: port)

        listener?.newConnectionHandler = { [weak self] newConnection in
            guard let strongSelf = self else { return }
            newConnection.start(queue: strongSelf.queue)

            Task {
                do {
                    try await strongSelf.handlerTask(on: newConnection).value
                } catch {
                    strongSelf.logger.error("Receive failed: \(error)")
                }
                newConnection.cancel()
            }
        }

        listener?.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                DispatchQueue.main.async { [weak self] in
                    if let port = self?.listener?.port?.rawValue {
                        self?.logger.log("Server started and listening on port \(port, privacy: .public)")
                        AKInterface.shared?.windowTitle = "\(self?.windowTitle ?? "") [localhost:\(port)]"
                    }
                }
            case .cancelled:
                self?.logger.log("Server closed")
            case let .failed(error):
                self?.logger.error("Server failed to start: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: queue)
    }

    // swiftlint:disable cyclomatic_complexity

    private func handlerTask(on connection: NWConnection) -> Task<Void, Error> {
        Task {
            let (handshake, _, _) = try await connection.receive(minimumIncompleteLength: 4, maximumLength: 4)
            guard handshake == connectionMagic else {
                throw MaaToolsError.invalidMessage
            }
            try await connection.send(content: "OKAY".data(using: .ascii))

            for try await payload in readPayload(from: connection) {
                switch payload.prefix(4) {
                case screencapMagic:
                    try await screencap(to: connection)
                case sizeMagic:
                    try await screensize(to: connection)
                case terminateMagic:
                    AKInterface.shared?.terminateApplication()
                case toucherMagic:
                    toucherDispatch(payload, on: connection)
                case versionMagic:
                    try await version(to: connection)
                case bundleMagic:
                    try await bundleID(to: connection)
                case rectMagic:
                    try await rectangle(to: connection)
                case bgrMagic:
                    try await bgrScreencap(to: connection)
                default:
                    break
                }
            }
        }
    }

    // swiftlint:enable cyclomatic_complexity

    // swiftlint:disable line_length

    private func readPayload(from connection: NWConnection) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let receiver = Task {
                while true {
                    do {
                        try Task.checkCancellation()
                        let (header, _, _) = try await connection.receive(minimumIncompleteLength: 2, maximumLength: 2)
                        let length = header.u16(at: 0)

                        try Task.checkCancellation()
                        let (payload, _, _) = try await connection.receive(minimumIncompleteLength: length, maximumLength: length)
                        continuation.yield(payload)
                    } catch {
                        continuation.finish(throwing: error)
                        break
                    }
                }
            }

            continuation.onTermination = { _ in
                receiver.cancel()
            }
        }
    }

    // swiftlint:enable line_length

    private func screencap(to connection: NWConnection) async throws {
        let data = screenshot() ?? Data()
        try await connection.send(content: data.count.u32Bytes + data)
    }

    private func screenshot() -> Data? {
        guard let image = AKInterface.shared?.windowImage else {
            logger.error("Failed to fetch CGImage")
            return nil
        }

        // Crop the title bar
        let titleBarHeight = image.height - image.width * height / width
        let contentRect = CGRect(x: 0, y: titleBarHeight, width: image.width,
                                 height: image.height - titleBarHeight)
        guard let image = image.cropping(to: contentRect) else {
            logger.error("Failed to crop image")
            return nil
        }

        let length = 4 * height * width
        let bytesPerRow = 4 * width
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrderDefault.rawValue
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: buffer, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: colorSpace, bitmapInfo: bitmapInfo)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let data = Data(bytesNoCopy: buffer, count: length, deallocator: .free)

        return data
    }

    private func screensize(to connection: NWConnection) async throws {
        try await connection.send(content: width.u16Bytes + height.u16Bytes)
    }

    private func toucherDispatch(_ content: Data, on _: NWConnection) {
        let touchPhase = content[4]

        let pointX = content.u16(at: 5).divRound(by: scale)
        let pointY = content.u16(at: 7).divRound(by: scale)

        switch touchPhase {
        case 0:
            toucherDown(atX: pointX, atY: pointY)
        case 1:
            toucherMove(atX: pointX, atY: pointY)
        case 3:
            toucherUp(atX: pointX, atY: pointY)
            Toucher.keyView = nil
        default:
            break
        }
    }

    private func toucherDown(atX: Int, atY: Int) {
        Toucher.touchcam(point: .init(x: atX, y: atY), phase: .began, tid: &tid,
                         actionName: "down", keyName: "touch")
    }

    private func toucherMove(atX: Int, atY: Int) {
        Toucher.touchcam(point: .init(x: atX, y: atY), phase: .moved, tid: &tid,
                         actionName: "move", keyName: "touch")
    }

    private func toucherUp(atX: Int, atY: Int) {
        Toucher.touchcam(point: .init(x: atX, y: atY), phase: .ended, tid: &tid,
                         actionName: "up", keyName: "touch")
    }

    private func version(to connection: NWConnection) async throws {
        try await connection.send(content: MAA_TOOLS_VERSION.u32Bytes)
    }

    private func bundleID(to connection: NWConnection) async throws {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let data = Data(bundleID.utf8)
        try await connection.send(content: data.count.u32Bytes + data)
    }

    private func rectangle(to connection: NWConnection) async throws {
        let frame = AKInterface.shared?.windowFrame ?? CGRect()
        let content = AKInterface.shared?.windowContentRect ?? CGRect()

        let flatten = { (rect: CGRect) in
            [rect.origin.x, rect.origin.y,
             rect.size.width, rect.size.height]
        }

        let data = [frame, content].flatMap(flatten)
            .map { Int($0.rounded()).u16Bytes }
            .reduce(into: Data()) { partialResult, value in
                partialResult.append(value)
            }

        try await connection.send(content: data)
    }

    private func bgrScreenshot() -> (Int, Int, Data)? {
        guard let image = AKInterface.shared?.windowImage else {
            logger.error("Failed to fetch CGImage")
            return nil
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(alpha: .noneSkipLast, byteOrder: .orderDefault)

        let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
                                          colorSpace: colorSpace, bitmapInfo: bitmapInfo)

        let buffer: vImage_Buffer
        do {
            buffer = try vImage_Buffer(cgImage: image, format: format!)
            logger.debug("Got buffer: \(buffer.width)x\(buffer.height)")
        } catch {
            logger.error("Failed to create buffer: \(error.localizedDescription)")
            return nil
        }
        defer { buffer.free() }

        // Crop the title bar
        let expectedHeight = buffer.width * UInt(height) / UInt(width)
        let titleBarHeight = buffer.height - expectedHeight
        logger.debug("Cropping \(titleBarHeight) rows, expecting \(buffer.width)x\(expectedHeight)")

        let offset = Int(titleBarHeight) * buffer.rowBytes
        var src = vImage_Buffer(data: buffer.data + offset,
                                height: expectedHeight, width: buffer.width,
                                rowBytes: buffer.rowBytes)

        let bgrLength = Int(3 * expectedHeight * buffer.width)
        let bgrBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bgrLength)
        var dst = vImage_Buffer(data: bgrBuffer,
                                height: expectedHeight, width: buffer.width,
                                rowBytes: 3 * Int(buffer.width))

        vImagePermuteChannels_ARGB8888(&src, &src, [2, 1, 0, 3], vImage_Flags(kvImageNoFlags))
        vImageConvert_RGBA8888toRGB888(&src, &dst, vImage_Flags(kvImageNoFlags))

        let data = Data(bytesNoCopy: bgrBuffer, count: bgrLength, deallocator: .custom { pointer, _ in
            pointer.deallocate()
        })

        return (Int(buffer.width), Int(expectedHeight), data)
    }

    private func bgrScreencap(to connection: NWConnection) async throws {
        let (width, height, data) = bgrScreenshot() ?? (0, 0, Data())
        let payload = width.u32Bytes + height.u32Bytes + data.count.u32Bytes + data
        try await connection.send(content: payload)
    }
}

private enum MaaToolsError: Error {
    case emptyContent
    case invalidMessage
}

private extension Int {
    var u16Bytes: Data {
        let bytes = [UInt8(self >> 8 & 0xff), UInt8(self & 0xff)]
        return Data(bytes)
    }

    var u32Bytes: Data {
        let bytes = [UInt8(self >> 24 & 0xff), UInt8(self >> 16 & 0xff), UInt8(self >> 8 & 0xff), UInt8(self & 0xff)]
        return Data(bytes)
    }

    func divRound(by div: Double) -> Int {
        let value = Double(self) / div
        return Int(value.rounded())
    }
}

private extension Data {
    func u16(at offset: Int) -> Int {
        guard offset < count - 1 else { return 0 }
        return Int(self[offset]) * 256 + Int(self[offset + 1])
    }
}

// swiftlint:disable large_tuple line_length

private extension NWConnection {
    func receive(minimumIncompleteLength: Int, maximumLength: Int) async throws -> (Data, NWConnection.ContentContext, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength) { content, contentContext, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let content, let contentContext else {
                    continuation.resume(throwing: MaaToolsError.emptyContent)
                    return
                }

                continuation.resume(returning: (content, contentContext, isComplete))
            }
        }
    }

    func send(content: Data?, contentContext: NWConnection.ContentContext = .defaultMessage, isComplete: Bool = true) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            send(content: content, contentContext: contentContext, isComplete: isComplete, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}

// swiftlint:enable large_tuple line_length
