//
//  MetalCapture.swift
//  PlayTools
//
//  Created by hguandl on 2026/9/2.
//

import Foundation
import Metal
import OSLog

private let logger = Logger(subsystem: "PlayTools", category: "MetalCapture")

final class MetalCapture: Sendable {
    let width: Int
    let height: Int

    private let _buffer: MetalCaptureBuffer

    var buffer: any MTLBuffer {
        _buffer.buffer
    }

    init(width: Int, height: Int, buffer: MetalCaptureBuffer) {
        self.width = width
        self.height = height
        _buffer = buffer
    }
}

enum MetalCaptureError: Error {
    case disabled
    case outdated
    case unavailable
}

final class MetalCaptureBuffer: @unchecked Sendable {
    let buffer: any MTLBuffer

    private weak var pool: MetalCaptureBufferPool?

    fileprivate init(_ buffer: any MTLBuffer, from pool: MetalCaptureBufferPool) {
        self.buffer = buffer
        self.pool = pool
    }

    deinit {
        pool?.release(buffer: buffer)
    }
}

final class MetalCaptureBufferPool: @unchecked Sendable {
    let capacity: Int

    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    private var pool = [ObjectIdentifier: [any MTLBuffer]]()
    private var quotas = [ObjectIdentifier: Int]()

    init(capacity: Int) {
        self.capacity = capacity
        lock.initialize(to: .init())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    fileprivate func release(buffer: any MTLBuffer) {
        let id = ObjectIdentifier(buffer.device)
        os_unfair_lock_lock(lock)
        pool[id, default: []].append(buffer)
        os_unfair_lock_unlock(lock)
        logger.debug("Buffer released for \(buffer.device.name)")
    }

    private func makeBuffer(from device: MTLDevice, length: Int) -> MetalCaptureBuffer? {
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            logger.error("Failed to create buffer for \(device.name)")
            os_unfair_lock_lock(lock)
            quotas[ObjectIdentifier(device), default: 0] -= 1
            os_unfair_lock_unlock(lock)
            return nil
        }
        logger.debug("New buffer created for \(device.name)")
        return .init(buffer, from: self)
    }

    private func newBuffer(from device: MTLDevice, length: Int) -> MetalCaptureBuffer? {
        let id = ObjectIdentifier(device)
        os_unfair_lock_lock(lock)
        let quota = quotas[id, default: 0]
        guard quota < capacity else {
            os_unfair_lock_unlock(lock)
            logger.error("Buffers drained for \(device.name)")
            return nil
        }
        quotas[id] = quota + 1
        os_unfair_lock_unlock(lock)
        return makeBuffer(from: device, length: length)
    }

    func acquire(from device: MTLDevice, length: Int) -> MetalCaptureBuffer? {
        let id = ObjectIdentifier(device)
        os_unfair_lock_lock(lock)
        guard var buffers = pool[id], !buffers.isEmpty else {
            os_unfair_lock_unlock(lock)
            return newBuffer(from: device, length: length)
        }
        let buffer = buffers.removeFirst()
        pool[id] = buffers
        os_unfair_lock_unlock(lock)
        if buffer.length >= length {
            logger.debug("Cached buffer reused for \(device.name)")
            return .init(buffer, from: self)
        } else {
            logger.info("Larger buffer of \(length) created for \(device.name)")
            return makeBuffer(from: device, length: length)
        }
    }
}

final class MetalCaptureState: @unchecked Sendable {
    private var commandQueue: MTLCommandQueue?
    private var continuation: UnsafeContinuation<MetalCapture, any Error>?

    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    init() {
        lock.initialize(to: .init())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func initialize(commandQueue: MTLCommandQueue) {
        os_unfair_lock_lock(lock)
        guard self.commandQueue == nil else {
            fatalError("Cannot initialize twice")
        }
        self.commandQueue = commandQueue
        os_unfair_lock_unlock(lock)
    }

    func register(continuation: UnsafeContinuation<MetalCapture, any Error>) {
        os_unfair_lock_lock(lock)
        let oldContinuation = self.continuation
        self.continuation = continuation
        os_unfair_lock_unlock(lock)
        oldContinuation?.resume(throwing: MetalCaptureError.outdated)
    }

    func take() -> (MTLCommandQueue, UnsafeContinuation<MetalCapture, any Error>)? {
        guard os_unfair_lock_trylock(lock) else {
            return nil
        }
        guard let commandQueue else {
            os_unfair_lock_unlock(lock)
            return nil
        }
        guard let continuation else {
            os_unfair_lock_unlock(lock)
            return nil
        }
        self.continuation = nil
        os_unfair_lock_unlock(lock)
        return (commandQueue, continuation)
    }
}
