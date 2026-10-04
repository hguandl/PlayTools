import Metal
import OSLog
import QuartzCore

private let logger = Logger(subsystem: "PlayTools", category: "MetalCapture")

final class ArknightsMetalCapture {
    private static let bundleIdentifiers = [
        "com.hypergryph.arknights"
    ]

    private static let captureTimeout: TimeInterval = 5

    private let state = MetalCaptureState()
    private let buffers = MetalCaptureBufferPool(capacity: 3)

    static let shared = ArknightsMetalCapture()

    private init() {}

    func capture() async throws -> MetalCapture {
        switch Self.installation {
        case nil: throw MetalCaptureError.disabled
        case false: throw MetalCaptureError.unavailable
        case true: break
        }
        return try await withUnsafeThrowingContinuation { continuation in
            let request = MetalCaptureRequest(continuation: continuation)
            state.register(request: request)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.captureTimeout) {
                request.finish(with: .failure(MetalCaptureError.unavailable))
            }
        }
    }

    static let installation: Bool? = {
        guard PlaySettings.shared.enableMetalCapture else { return nil }
        return shared.installHooks()
    }()

    private func installHooks() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              Self.bundleIdentifiers.contains(bundleIdentifier)
        else {
            return false
        }

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let commandBufferClass = object_getClass(commandBuffer) else {
            logger.error("Failed to discover the Metal command-buffer class")
            return false
        }

        let commitCallback: PTMetalCommitCallback = { [weak self] commandBuffer in
            self?.observeCommit(commandBuffer)
        }
        let presentCallback: PTMetalDrawableCallback = { [weak self] drawable in
            self?.observePresent(drawable)
        }
        guard PTInstallMetalCaptureHooks(commandBufferClass, commitCallback, presentCallback) else {
            logger.error("Failed to install the Metal capture hooks")
            return false
        }

        return true
    }

    private func observeCommit(_ object: Any) {
        guard let commandBuffer = object as? MTLCommandBuffer else { return }
        state.initialize(commandQueue: commandBuffer.commandQueue)
    }

    private func observePresent(_ object: Any) {
        guard let drawable = object as? CAMetalDrawable else { return }

        let texture = drawable.texture
        guard texture.pixelFormat == .bgra8Unorm,
              texture.sampleCount == 1,
              !drawable.layer.framebufferOnly else { return }

        guard let (commandQueue, request) = state.take() else {
            return
        }

        let width = texture.width
        let height = texture.height
        guard width > 0, height > 0 else {
            request.finish(with: .failure(MetalCaptureError.unavailable))
            return
        }
        let bytesPerRow = width * 4
        let length = bytesPerRow * height

        guard let buffer = buffers.acquire(from: texture.device, length: length),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder()
        else {
            request.finish(with: .failure(MetalCaptureError.unavailable))
            return
        }

        encoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer.buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: 0
        )
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { commandBuffer in
            if let error = commandBuffer.error {
                request.finish(with: .failure(error))
                return
            }

            guard commandBuffer.status == .completed else {
                request.finish(with: .failure(MetalCaptureError.unavailable))
                return
            }

            request.finish(with: .success(.init(width: width, height: height, buffer: buffer)))
        }
        commandBuffer.commit()
    }
}
