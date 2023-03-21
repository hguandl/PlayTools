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
        Task(priority: .background) {
            // Wait for window
            while width == 0 || height == 0 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                setupScreenSize()
            }

            startServer()
            startCapture()
        }
    }

    private func setupScreenSize() {
        let window = UIApplication.shared.connectedScenes
            .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
            .first { $0.isKeyWindow }

        if let bounds = window?.screen.bounds {
            width = Int(bounds.width)
            height = Int(bounds.height)
        }
    }

    private func startServer() {
        listener = try? NWListener(using: .tcp, on: .init(rawValue: 2333)!)

        listener?.newConnectionHandler = { [weak self] newConnection in
            guard let strongSelf = self else { return }
            newConnection.start(queue: strongSelf.queue)
            newConnection.receive(minimumIncompleteLength: 4, maximumLength: 4) { content, _, _, error in
                if let error {
                    strongSelf.logger.error("Receive failed: \(error)")
                    newConnection.cancelCurrentEndpoint()
                    return
                }

                guard let content, content == strongSelf.connectionMagic else {
                    newConnection.cancelCurrentEndpoint()
                    return
                }

                newConnection.send(content: "OKAY".data(using: .ascii), completion: .idempotent)
                strongSelf.accept(on: newConnection)
            }
        }

        listener?.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                if let port = self?.listener?.port?.rawValue {
                    self?.logger.log("Server started and listening on port \(port, privacy: .public)")
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

    private func startCapture() {
        RPScreenRecorder.shared().startCapture { sampleBuffer, sampleBufferType, error in
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
        } completionHandler: { error in
            if let error {
                self.logger.error("Start Capture Error: \(error)")
            } else {
                self.logger.log("Capture started.")
            }
        }
    }

    private func accept(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { content, _, _, error in
            if let error {
                self.logger.error("Receive failed: \(error)")
                connection.cancelCurrentEndpoint()
                return
            }

            guard let content, content.count == 2 else {
                connection.cancelCurrentEndpoint()
                return
            }

            let length = Int(content[0]) * 256 + Int(content[1])
            self.dispatch(length, on: connection)
        }
    }

    private func dispatch(_ length: Int, on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { content, _, _, error in
            if let error {
                self.logger.error("Receive failed: \(error)")
                connection.cancelCurrentEndpoint()
                return
            }

            guard let content, content.count == length else {
                connection.cancelCurrentEndpoint()
                return
            }

            switch content.prefix(4) {
            case self.screencapMagic:
                self.screencap(to: connection)
            case self.sizeMagic:
                self.screensize(to: connection)
            case self.terminateMagic:
                AKInterface.shared?.terminateApplication()
            case self.toucherMagic:
                self.toucherDispatch(content, on: connection)
            default:
                break
            }

            self.accept(on: connection)
        }
    }

    private func screencap(to connection: NWConnection) {
        let data = screenshot() ?? Data()
        let length = [UInt8(data.count >> 24 & 0xff),
                      UInt8(data.count >> 16 & 0xff),
                      UInt8(data.count >> 8 & 0xff),
                      UInt8(data.count & 0xff)]

        connection.send(content: Data(length), completion: .idempotent)
        connection.send(content: data, completion: .idempotent)
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

    private func screensize(to connection: NWConnection) {
        let bytes = [UInt8(width >> 8 & 0xff),
                     UInt8(width & 0xff),
                     UInt8(height >> 8 & 0xff),
                     UInt8(height & 0xff)]

        connection.send(content: Data(bytes), completion: .idempotent)
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
