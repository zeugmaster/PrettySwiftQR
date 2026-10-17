//
//  QRLiquidRenderer.swift
//  PrettySwiftQR
//
//  Metal plumbing for the liquid transitions: one compiled pipeline per
//  process, and a renderer per view that uploads a frame of the simulation
//  and draws it.
//

import Foundation
import Metal
import QuartzCore
import os
import PrettyQRCore

/// The device, queue and compiled pipeline, shared by every liquid view.
///
/// The shader is compiled from source with the system's runtime Metal compiler
/// (about 0.1 s), off the main actor, the first time a `QRCodeView` with a liquid
/// reveal loads. Until then, or where Metal is unavailable, views fall back to
/// the growing reveal.
final class QRLiquidGPU: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let start = ContinuousClock.now
        do {
            let library = try device.makeLibrary(source: QRLiquidShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "PrettySwiftQR liquid"
            descriptor.vertexFunction = library.makeFunction(name: "qrLiquidVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "qrLiquidFragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = Self.pixelFormat
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            Self.logger.info("Liquid shader compiled in \(ContinuousClock.now - start, privacy: .public)")
        } catch {
            Self.logger.error("Liquid shader unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    private static let logger = Logger(subsystem: "PrettySwiftQR", category: "liquid")
    /// Built once, on first access (thread-safe).
    private static let instance: QRLiquidGPU? = QRLiquidGPU()
    private static let loaded = OSAllocatedUnfairLock(initialState: false)

    /// The pipeline if it has been compiled; never blocks.
    static var ready: QRLiquidGPU? {
        loaded.withLock { $0 } ? instance : nil
    }

    /// Compiles the pipeline off the calling actor if that has not happened yet.
    @discardableResult
    static func prepare() async -> QRLiquidGPU? {
        if let ready { return ready }
        return await Task.detached(priority: .userInitiated) {
            let gpu = instance
            loaded.withLock { $0 = true }
            return gpu
        }.value
    }

    /// Compiles synchronously. For tests and offscreen rendering.
    static func prepareNow() -> QRLiquidGPU? {
        let gpu = instance
        loaded.withLock { $0 = true }
        return gpu
    }
}

/// Everything that decides one rendered frame.
struct QRLiquidRequest: Equatable {
    var matrix: QRMatrix
    var radii: QROutlineRadii
    var quietZone: Double
    var liquid: QRLiquidStyle
    /// nil draws the code at rest (used to check the hand-off to the vector outline).
    var motion: QRLiquidMotion?
    var progress: Double
    /// Premultiplied sRGB.
    var foreground: SIMD4<Float>
    var background: SIMD4<Float> = .zero
}

/// Mirrors `Uniforms` in the shader (seven 16-byte rows, then four for the stroke).
private struct QRLiquidUniforms {
    var rect: SIMD4<Float>
    var radii: SIMD4<Float>
    var foreground: SIMD4<Float>
    var background: SIMD4<Float>
    var params: SIMD4<Float>
    var counts: SIMD4<Int32>
    var strokeCount: SIMD4<Int32>
    var stroke: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
}

/// Draws requests for one view. Keeps the textures of the current symbol and
/// re-simulates only when the progress or the motion changes.
final class QRLiquidRenderer {
    let gpu: QRLiquidGPU
    private var model: QRLiquidModel?
    private var info: MTLTexture?
    private var state: MTLTexture?
    private var bonds: MTLTexture?
    private var profile: MTLTexture?
    private var attach: MTLTexture?
    private var simulated: SimulationKey?
    private var counts = (drops: 0, bonds: 0)
    private var inFlight: MTLCommandBuffer?

    private struct SimulationKey: Equatable {
        let model: ObjectIdentifier
        let motion: QRLiquidMotion?
        let progress: Double
        let stagger: Double
    }

    init(gpu: QRLiquidGPU) {
        self.gpu = gpu
    }

    /// Renders into `drawable` and presents it with the current Core Animation
    /// transaction, so the frame appears together with the SwiftUI update that
    /// asked for it (the hand-off to and from the vector outline is seamless).
    func render(_ request: QRLiquidRequest, to drawable: CAMetalDrawable) {
        guard let commandBuffer = encode(request, into: drawable.texture) else { return }
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        drawable.present()
        inFlight = commandBuffer
    }

    /// Renders into a new texture and returns its BGRA bytes (premultiplied).
    func pixels(_ request: QRLiquidRequest, width: Int, height: Int) -> [UInt8]? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: QRLiquidGPU.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        #if os(macOS)
        let unified = gpu.device.hasUnifiedMemory
        descriptor.storageMode = unified ? .shared : .managed
        #else
        descriptor.storageMode = .shared
        #endif
        guard let texture = gpu.device.makeTexture(descriptor: descriptor), let commandBuffer = encode(request, into: texture) else { return nil }
        #if os(macOS)
        if !unified, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        #endif
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    private func encode(_ request: QRLiquidRequest, into target: MTLTexture) -> MTLCommandBuffer? {
        // The textures are rewritten below; the previous frame must be done reading them.
        inFlight?.waitUntilCompleted()
        inFlight = nil
        prepareTextures(for: request)
        guard let info, let state, let bonds, let profile, let attach,
              let commandBuffer = gpu.queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        let width = Double(target.width), height = Double(target.height)
        let side = min(width, height)
        let radii = request.radii
        let stroke = request.motion?.target
        let points = (stroke?.points ?? []).map { SIMD2<Float>(Float($0.x), Float($0.y)) * Float(request.matrix.size) }
        func pair(_ k: Int) -> SIMD4<Float> {
            let a = k * 2 < points.count ? points[k * 2] : .zero, b = k * 2 + 1 < points.count ? points[k * 2 + 1] : .zero
            return SIMD4(a.x, a.y, b.x, b.y)
        }
        let mode: Int32
        switch request.motion {
        case nil: mode = 0
        case .pullApart: mode = 4
        case .flow: mode = 3
        }
        var uniforms = QRLiquidUniforms(
            rect: SIMD4(Float((width - side) / 2), Float((height - side) / 2), Float(side), Float(request.quietZone)),
            radii: SIMD4(Float(radii.module), Float(radii.inner), Float(radii.finderOuter), Float(radii.finderInner)),
            foreground: request.foreground,
            background: request.background,
            params: SIMD4(Float(radii.finderCenter), Float(request.liquid.tension), Float(model?.stroke?.total ?? 1), 0),
            counts: SIMD4(Int32(request.matrix.size), mode, Int32(counts.drops), Int32(counts.bonds)),
            strokeCount: SIMD4(Int32(points.count), 0, 0, 0),
            stroke: (pair(0), pair(1), pair(2), pair(3)))

        encoder.setRenderPipelineState(gpu.pipeline)
        encoder.setFragmentTextures([info, state, bonds, profile, attach], range: 0..<5)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<QRLiquidUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return commandBuffer
    }

    private func prepareTextures(for request: QRLiquidRequest) {
        let model = QRLiquidModel.cached(matrix: request.matrix, dropsPerSide: request.liquid.dropsPerSide, target: request.motion?.target)
        if model !== self.model {
            self.model = model
            simulated = nil
            let w = model.size + 1
            info = makeTexture(.rgba8Uint, width: w, height: w)
            info?.replace(region: MTLRegionMake2D(0, 0, w, w), mipmapLevel: 0, withBytes: model.info, bytesPerRow: w * 4)
            state = makeTexture(.rgba32Float, width: QRLiquidFrame.stateTexels, height: model.drops.count)
            bonds = makeTexture(.rgba32Float, width: QRLiquidFrame.bondTexels, height: max(1, model.bonds.count))
            profile = makeTexture(.r32Float, width: QRLiquidFrame.profileSamples, height: 1)
            attach = makeTexture(.rgba8Unorm, width: model.size, height: model.size)
        }
        let key = SimulationKey(model: ObjectIdentifier(model), motion: request.motion, progress: request.progress, stagger: request.liquid.stagger)
        guard key != simulated else { return }
        simulated = key
        let frame = model.frame(progress: request.motion == nil ? 0 : request.progress, motion: request.motion ?? .pullApart, stagger: request.liquid.stagger)
        counts = (frame.dropCount, request.motion == nil ? 0 : frame.bondCount)
        state?.replace(region: MTLRegionMake2D(0, 0, QRLiquidFrame.stateTexels, frame.dropCount), mipmapLevel: 0, withBytes: frame.state, bytesPerRow: QRLiquidFrame.stateTexels * 16)
        bonds?.replace(region: MTLRegionMake2D(0, 0, QRLiquidFrame.bondTexels, max(1, frame.bondCount)), mipmapLevel: 0, withBytes: frame.bonds, bytesPerRow: QRLiquidFrame.bondTexels * 16)
        profile?.replace(region: MTLRegionMake2D(0, 0, QRLiquidFrame.profileSamples, 1), mipmapLevel: 0, withBytes: frame.profile, bytesPerRow: QRLiquidFrame.profileSamples * 4)
        attach?.replace(region: MTLRegionMake2D(0, 0, model.size, model.size), mipmapLevel: 0, withBytes: frame.attach, bytesPerRow: model.size * 4)
    }

    private func makeTexture(_ format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        return gpu.device.makeTexture(descriptor: descriptor)
    }
}
