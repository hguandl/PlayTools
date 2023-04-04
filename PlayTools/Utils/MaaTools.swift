//
//  MaaTools.swift
//  PlayTools
//
//  Created by hguandl on 21/3/2023.
//

import Network
import OSLog
import ReplayKit
import VideoToolbox

final class MaaTools {
    public static let shared = MaaTools()

    private let logger = Logger(subsystem: "PlayTools", category: "MaaTools")
    private let queue = DispatchQueue(label: "MaaTools", qos: .background)
    private var listener: NWListener?

    private var windowTitle: String?
    private var imageBuffer: CVImageBuffer?
    private var tid: Int?

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

    func initialize() {
        guard PlaySettings.shared.maaTools else { return }

        Task(priority: .background) {
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

        if let bounds = window?.screen.bounds {
            width = Int(bounds.width)
            height = Int(bounds.height)
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
                if let port = self?.listener?.port?.rawValue {
                    self?.logger.log("Server started and listening on port \(port, privacy: .public)")
                    AKInterface.shared?.windowTitle = "\(self?.windowTitle ?? "") [localhost:\(port)]"
                }
            case .cancelled:
                self?.logger.log("Server closed")
            case .failed(let error):
                self?.logger.error("Server failed to start: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: queue)
    }

    private func handlerTask(on connection: NWConnection) -> Task<Void, Error> {
        Task {
            let (handshake, _, _) = try await connection.receive(minimumIncompleteLength: 4, maximumLength: 4)
            guard handshake == connectionMagic else {
                throw MaaToolsError.invalidMessage
            }
            try await startCapture()
            try await connection.send(content: "OKAY".data(using: .ascii))

            for try await payload in readPayload(from: connection) {
                guard RPScreenRecorder.shared().isRecording else {
                    throw MaaToolsError.recorderStopped
                }

                switch payload.prefix(4) {
                case screencapMagic:
                    try await screencap(to: connection)
                case sizeMagic:
                    try await screensize(to: connection)
                case terminateMagic:
                    AKInterface.shared?.terminateApplication()
                case toucherMagic:
                    toucherDispatch(payload, on: connection)
                default:
                    break
                }
            }
        }
    }

    private func startCapture() async throws {
        guard !RPScreenRecorder.shared().isRecording else {
            return
        }

        try await RPScreenRecorder.shared().startCapture { sampleBuffer, sampleBufferType, error in
            if let error {
                self.logger.error("Capture error: \(error)")
                return
            }

            guard sampleBuffer.isValid else {
                self.logger.error("Sample not valid")
                return
            }

            guard sampleBufferType == .video else {
                return
            }

            self.imageBuffer = sampleBuffer.imageBuffer
        }

        while imageBuffer == nil {
            try await Task.sleep(nanoseconds: 500_000)
        }
    }

    // swiftlint:disable line_length

    private func readPayload(from connection: NWConnection) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let receiver = Task {
                while true {
                    do {
                        try Task.checkCancellation()
                        let (header, _, _) = try await connection.receive(minimumIncompleteLength: 2, maximumLength: 2)
                        let length = Int(header[0]) * 256 + Int(header[1])

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
        let length = [UInt8(data.count >> 24 & 0xff),
                      UInt8(data.count >> 16 & 0xff),
                      UInt8(data.count >> 8 & 0xff),
                      UInt8(data.count & 0xff)]

        try await connection.send(content: Data(length) + data)
    }

    private func screenshot() -> Data? {
        guard let imageBuffer else {
            logger.error("No image buffer")
            return nil
        }

        var image: CGImage?
        let result = VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &image)
        guard result == noErr, let image else {
            logger.error("Failed to create CGImage")
            return nil
        }

        // Crop the title bar
        let titleBarHeight = 56
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
        let context = CGContext(data: buffer, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: image.colorSpace!, bitmapInfo: bitmapInfo)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let data = Data(bytesNoCopy: buffer, count: length, deallocator: .free)

        return data
    }

    private func screensize(to connection: NWConnection) async throws {
        let bytes = [UInt8(width >> 8 & 0xff),
                     UInt8(width & 0xff),
                     UInt8(height >> 8 & 0xff),
                     UInt8(height & 0xff)]

        try await connection.send(content: Data(bytes))
    }

    private func toucherDispatch(_ content: Data, on connection: NWConnection) {
        let touchPhase = content[4]

        let parseInt16 = { (data: Data, offset: Int) in
            Int(data[offset]) * 256 + Int(data[offset + 1])
        }

        let pointX = parseInt16(content, 5)
        let pointY = parseInt16(content, 7)

        switch touchPhase {
        case 0:
            toucherDown(atX: pointX, atY: pointY)
        case 1:
            toucherMove(atX: pointX, atY: pointY)
        case 3:
            toucherUp(atX: pointX, atY: pointY)
        default:
            break
        }
    }

    private func toucherDown(atX: Int, atY: Int) {
        Toucher.touchcam(point: .init(x: atX, y: atY), phase: .began, tid: &tid)
    }

    private func toucherMove(atX: Int, atY: Int) {
        Toucher.touchcam(point: .init(x: atX, y: atY), phase: .moved, tid: &tid)
    }

    private func toucherUp(atX: Int, atY: Int) {
        Toucher.touchcam(point: .init(x: atX, y: atY), phase: .ended, tid: &tid)
    }
}

private enum MaaToolsError: Error {
    case emptyContent
    case invalidMessage
    case recorderStopped
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
