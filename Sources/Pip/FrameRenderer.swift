import AppKit
import CoreVideo
import Foundation
import Metal
import MetalKit
import simd

private enum FrameRendererError: LocalizedError {
  case noMetalDevice
  case commandQueueUnavailable
  case textureCacheUnavailable(CVReturn)
  case shaderResourceUnavailable
  case shaderSourceUnavailable
  case shaderCompilationFailed(Error)
  case pipelineUnavailable
  case samplerUnavailable

  var errorDescription: String? {
    switch self {
    case .noMetalDevice:
      return "Metal device is unavailable."
    case .commandQueueUnavailable:
      return "Metal command queue could not be created."
    case .textureCacheUnavailable(let status):
      return "Core Video texture cache could not be created (\(status))."
    case .shaderResourceUnavailable:
      return "Video shader resource is unavailable."
    case .shaderSourceUnavailable:
      return "Video shader source could not be read."
    case .shaderCompilationFailed(let error):
      return "Video shader compilation failed: \(error.localizedDescription)"
    case .pipelineUnavailable:
      return "Metal render pipeline could not be created."
    case .samplerUnavailable:
      return "Metal sampler could not be created."
    }
  }
}

/// The small amount of state shared by capture callbacks, the main actor, and
/// Metal command-buffer completion handlers. It deliberately owns no AppKit or
/// MetalKit object; those stay on the main actor.
private final class RendererSharedState: @unchecked Sendable {
  let lock = NSLock()

  var generation: UInt64 = 0
  var serial: UInt64 = 0
  var latest: PendingFrame?
  var lastRenderedSerial: UInt64 = 0
  var needsRedraw = false
  var needsBlank = false
  var wakeScheduled = false
  var inFlight = 0
  var shuttingDown = false
}

private final class PendingFrame: @unchecked Sendable {
  let frame: CaptureFrame
  let serial: UInt64

  init(frame: CaptureFrame, serial: UInt64) {
    self.frame = frame
    self.serial = serial
  }
}

/// Resources retained by a command buffer until its GPU work has completed.
/// The pixel buffer and CVMetalTexture must outlive sampling from the MTLTexture;
/// retaining the MTLTexture itself also keeps the encoder's source explicit.
private final class DrawResources: @unchecked Sendable {
  let pixelBuffer: CVPixelBuffer
  let metalTexture: CVMetalTexture
  let texture: MTLTexture

  init(pixelBuffer: CVPixelBuffer, metalTexture: CVMetalTexture, texture: MTLTexture) {
    self.pixelBuffer = pixelBuffer
    self.metalTexture = metalTexture
    self.texture = texture
  }
}

private struct VideoUniforms {
  var scale: SIMD2<Float>
  var sourceMin: SIMD2<Float>
  var sourceMax: SIMD2<Float>
  /// Clockwise quarter turns (0-3) applied to the output; mirrors Video.metal.
  var rotation: UInt32
}
@MainActor
private final class FrameRendererDelegateBridge: NSObject, MTKViewDelegate {
  weak var renderer: FrameRenderer?

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    renderer?.handleDrawableSizeWillChange(size)
  }

  func draw(in view: MTKView) {
    renderer?.draw(in: view)
  }
}

final class FrameRenderer: @unchecked Sendable {
  private let shared = RendererSharedState()

  @MainActor private let metalView: MTKView
  @MainActor private let commandQueue: MTLCommandQueue
  @MainActor private let textureCache: CVMetalTextureCache
  @MainActor private let pipelineState: MTLRenderPipelineState
  @MainActor private let samplerState: MTLSamplerState
  @MainActor private let delegateBridge: FrameRendererDelegateBridge
  @MainActor private var rotation: VideoRotation = .none

  @MainActor
  init() throws {
    guard let metalDevice = MTLCreateSystemDefaultDevice() else {
      throw FrameRendererError.noMetalDevice
    }
    guard let queue = metalDevice.makeCommandQueue() else {
      throw FrameRendererError.commandQueueUnavailable
    }

    var cache: CVMetalTextureCache?
    let cacheStatus = CVMetalTextureCacheCreate(
      kCFAllocatorDefault,
      nil,
      metalDevice,
      nil,
      &cache
    )
    guard cacheStatus == kCVReturnSuccess, let cache else {
      throw FrameRendererError.textureCacheUnavailable(cacheStatus)
    }

    guard let shaderURL = Bundle.module.url(forResource: "Video", withExtension: "metal") else {
      throw FrameRendererError.shaderResourceUnavailable
    }
    let shaderSource: String
    do {
      shaderSource = try String(contentsOf: shaderURL, encoding: .utf8)
    } catch {
      throw FrameRendererError.shaderSourceUnavailable
    }

    let library: MTLLibrary
    do {
      library = try metalDevice.makeLibrary(source: shaderSource, options: nil)
    } catch {
      throw FrameRendererError.shaderCompilationFailed(error)
    }
    guard let vertexFunction = library.makeFunction(name: "videoVertex"),
      let fragmentFunction = library.makeFunction(name: "videoFragment")
    else {
      throw FrameRendererError.pipelineUnavailable
    }

    let view = MTKView(frame: .zero, device: metalDevice)
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = true
    view.enableSetNeedsDisplay = true
    view.isPaused = true
    view.autoResizeDrawable = true
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = vertexFunction
    pipelineDescriptor.fragmentFunction = fragmentFunction
    pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
    guard let pipeline = try? metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    else {
      throw FrameRendererError.pipelineUnavailable
    }

    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.minFilter = .linear
    samplerDescriptor.magFilter = .linear
    samplerDescriptor.mipFilter = .notMipmapped
    samplerDescriptor.sAddressMode = .clampToEdge
    samplerDescriptor.tAddressMode = .clampToEdge
    guard let sampler = metalDevice.makeSamplerState(descriptor: samplerDescriptor) else {
      throw FrameRendererError.samplerUnavailable
    }

    let bridge = FrameRendererDelegateBridge()
    self.metalView = view
    self.commandQueue = queue
    self.textureCache = cache
    self.pipelineState = pipeline
    self.samplerState = sampler
    self.delegateBridge = bridge
    bridge.renderer = self
    view.delegate = bridge
  }

  @MainActor
  var view: MTKView {
    metalView
  }

  /// Rotates the displayed video clockwise and repaints the last frame
  /// immediately, even while capture delivers no new frames.
  @MainActor
  func setRotation(_ rotation: VideoRotation) {
    guard rotation != self.rotation else { return }
    self.rotation = rotation
    shared.lock.lock()
    guard !shared.shuttingDown else {
      shared.lock.unlock()
      return
    }
    shared.needsRedraw = true
    shared.lock.unlock()
    requestMainRedrawIfNeeded()
  }

  /// Replaces the bounded mailbox with the newest frame. The capture
  /// callback never waits for the main actor or the GPU; the only lock is the
  /// short state update below, and at most one main-queue wake is coalesced.
  func submit(_ frame: CaptureFrame) {
    shared.lock.lock()
    guard !shared.shuttingDown else {
      shared.lock.unlock()
      return
    }

    if frame.generation < shared.generation {
      shared.lock.unlock()
      return
    }

    if frame.generation > shared.generation {
      shared.generation = frame.generation
      shared.latest = nil
      shared.lastRenderedSerial = 0
      shared.needsBlank = true
    }

    shared.serial &+= 1
    shared.latest = PendingFrame(frame: frame, serial: shared.serial)
    shared.lock.unlock()

    requestMainRedrawIfNeeded()
  }

  /// Invalidates every frame from an older source. This is intentionally
  /// callable from the capture callback's non-main context.
  func reset(generation: UInt64) {
    shared.lock.lock()
    guard !shared.shuttingDown, generation >= shared.generation else {
      shared.lock.unlock()
      return
    }

    shared.generation = generation
    shared.latest = nil
    shared.lastRenderedSerial = 0
    shared.needsRedraw = false
    shared.needsBlank = true
    shared.lock.unlock()

    requestMainRedrawIfNeeded()
  }

  @MainActor
  func shutdown() {
    shared.lock.lock()
    guard !shared.shuttingDown else {
      shared.lock.unlock()
      return
    }
    shared.shuttingDown = true
    shared.latest = nil
    shared.needsRedraw = false
    shared.needsBlank = false
    shared.wakeScheduled = false
    shared.lock.unlock()

    metalView.delegate = nil
    metalView.isPaused = true
    metalView.enableSetNeedsDisplay = true
    // In-flight command buffers retain their DrawResources completion
    // captures. They are released by Metal after GPU completion; no wait is
    // performed on the main actor.
  }

  private func requestMainRedrawIfNeeded() {
    var shouldEnqueue = false
    shared.lock.lock()
    if !shared.shuttingDown && !shared.wakeScheduled && shared.inFlight < 2 {
      let hasNewFrame =
        shared.latest.map {
          shared.needsRedraw || $0.serial != shared.lastRenderedSerial
        } ?? false
      if shared.needsBlank || hasNewFrame {
        shared.wakeScheduled = true
        shouldEnqueue = true
      }
    }
    shared.lock.unlock()

    guard shouldEnqueue else { return }
    DispatchQueue.main.async { @MainActor [weak self] in
      self?.requestRedraw()
    }
  }

  @MainActor
  private func requestRedraw() {
    shared.lock.lock()
    shared.wakeScheduled = false
    let shouldDraw: Bool
    if shared.shuttingDown || shared.inFlight >= 2 {
      shouldDraw = false
    } else {
      let hasNewFrame =
        shared.latest.map {
          shared.needsRedraw || $0.serial != shared.lastRenderedSerial
        } ?? false
      shouldDraw = shared.needsBlank || hasNewFrame
    }
    shared.lock.unlock()

    guard shouldDraw else { return }
    metalView.setNeedsDisplay(metalView.bounds)
  }

  @MainActor
  private func reserveDraw() -> (PendingFrame?, UInt64)? {
    shared.lock.lock()
    defer { shared.lock.unlock() }
    guard !shared.shuttingDown, shared.inFlight < 2 else { return nil }

    let pending = shared.latest
    let hasNewFrame =
      pending.map {
        shared.needsRedraw || $0.serial != shared.lastRenderedSerial
      } ?? false
    let blank = pending == nil && shared.needsBlank
    guard hasNewFrame || blank else { return nil }

    shared.inFlight += 1
    return (pending, shared.generation)
  }

  @MainActor
  private func releaseReservedDraw() {
    shared.lock.lock()
    if shared.inFlight > 0 {
      shared.inFlight -= 1
    }
    shared.lock.unlock()
  }

  @MainActor
  private func encodeDraw(
    view: MTKView,
    pending: PendingFrame?,
    generation: UInt64
  ) {
    guard let drawable = view.currentDrawable else {
      releaseReservedDraw()
      return
    }
    guard let passDescriptor = view.currentRenderPassDescriptor else {
      releaseReservedDraw()
      return
    }
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      releaseReservedDraw()
      return
    }

    passDescriptor.colorAttachments[0].loadAction = .clear
    passDescriptor.colorAttachments[0].clearColor = MTLClearColor(
      red: 0, green: 0, blue: 0, alpha: 1)
    passDescriptor.colorAttachments[0].storeAction = .store

    var drawResources: DrawResources?
    var uniforms: VideoUniforms?
    if let pending {
      guard let prepared = prepareFrame(pending.frame, drawableSize: view.drawableSize) else {
        releaseReservedDraw()
        return
      }
      drawResources = prepared.resources
      uniforms = prepared.uniforms
    }

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
      releaseReservedDraw()
      return
    }

    if let drawResources, var uniforms {
      encoder.setRenderPipelineState(pipelineState)
      encoder.setVertexBytes(
        &uniforms,
        length: MemoryLayout<VideoUniforms>.stride,
        index: 0
      )
      encoder.setFragmentTexture(drawResources.texture, index: 0)
      encoder.setFragmentSamplerState(samplerState, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
    encoder.endEncoding()
    commandBuffer.present(drawable)

    // Keep command submission and the generation check atomic with reset.
    // If reset has already won the lock, abandon this command before
    // commit. If reset follows us, this command is ordered before its clear
    // command on the same queue and cannot become the final image.
    shared.lock.lock()
    guard !shared.shuttingDown, shared.generation == generation else {
      shared.lock.unlock()
      releaseReservedDraw()
      return
    }

    commandBuffer.addCompletedHandler { [weak self, drawResources] _ in
      // The capture and CVMetalTexture references remain alive through GPU
      // completion, even if the renderer itself has already shut down.
      withExtendedLifetime(drawResources) {
        self?.completeDraw()
      }
    }
    commandBuffer.commit()

    if let pending {
      if shared.latest?.serial == pending.serial {
        shared.lastRenderedSerial = pending.serial
        shared.needsRedraw = false
      }
      shared.needsBlank = false
    } else {
      shared.needsBlank = false
      shared.needsRedraw = false
    }
    shared.lock.unlock()

  }

  @MainActor
  private func prepareFrame(
    _ frame: CaptureFrame,
    drawableSize: CGSize
  ) -> (resources: DrawResources, uniforms: VideoUniforms)? {
    guard CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_32BGRA else {
      return nil
    }

    let pixelWidth = CVPixelBufferGetWidth(frame.pixelBuffer)
    let pixelHeight = CVPixelBufferGetHeight(frame.pixelBuffer)
    guard pixelWidth > 0, pixelHeight > 0,
      drawableSize.width > 0, drawableSize.height > 0
    else {
      return nil
    }

    let inputRect = frame.contentRect
    guard inputRect.origin.x.isFinite, inputRect.origin.y.isFinite,
      inputRect.size.width.isFinite, inputRect.size.height.isFinite
    else {
      return nil
    }
    let minX = max(0, min(CGFloat(pixelWidth), min(inputRect.minX, inputRect.maxX)))
    let maxX = max(0, min(CGFloat(pixelWidth), max(inputRect.minX, inputRect.maxX)))
    let minY = max(0, min(CGFloat(pixelHeight), min(inputRect.minY, inputRect.maxY)))
    let maxY = max(0, min(CGFloat(pixelHeight), max(inputRect.minY, inputRect.maxY)))
    guard maxX > minX, maxY > minY else { return nil }

    var cvTexture: CVMetalTexture?
    let textureStatus = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault,
      textureCache,
      frame.pixelBuffer,
      nil,
      .bgra8Unorm,
      pixelWidth,
      pixelHeight,
      0,
      &cvTexture
    )
    guard textureStatus == kCVReturnSuccess,
      let cvTexture,
      let sourceTexture = CVMetalTextureGetTexture(cvTexture)
    else {
      return nil
    }

    let sourceWidth = maxX - minX
    let sourceHeight = maxY - minY
    // A quarter-turn rotation displays the source with its width and height
    // exchanged, so the aspect fit uses the rotated dimensions. The UV corner
    // math below stays unrotated; the vertex shader applies the rotation.
    let sourceAspect =
      rotation.swapsDimensions ? sourceHeight / sourceWidth : sourceWidth / sourceHeight
    let drawableAspect = drawableSize.width / drawableSize.height
    let scale: SIMD2<Float>
    if sourceAspect > drawableAspect {
      scale = SIMD2(1, Float(drawableAspect / sourceAspect))
    } else {
      scale = SIMD2(Float(sourceAspect / drawableAspect), 1)
    }

    let normalizedMinX = Float(minX / CGFloat(pixelWidth))
    let normalizedMaxX = Float(maxX / CGFloat(pixelWidth))
    // Metal vertex coordinates map the output's top edge to sourceMin
    // and its bottom edge to sourceMax. Capture metadata is top-left
    // pixel coordinates, while CVMetalTextureIsFlipped reports whether
    // texture coordinate y = 0 is the upper-left source pixel.
    let isFlipped = CVMetalTextureIsFlipped(cvTexture)
    let normalizedTopY: Float
    let normalizedBottomY: Float
    if isFlipped {
      normalizedTopY = Float(minY / CGFloat(pixelHeight))
      normalizedBottomY = Float(maxY / CGFloat(pixelHeight))
    } else {
      normalizedTopY = Float(1 - (minY / CGFloat(pixelHeight)))
      normalizedBottomY = Float(1 - (maxY / CGFloat(pixelHeight)))
    }

    let uniforms = VideoUniforms(
      scale: scale,
      sourceMin: SIMD2(normalizedMinX, normalizedTopY),
      sourceMax: SIMD2(normalizedMaxX, normalizedBottomY),
      rotation: UInt32(rotation.rawValue)
    )
    let resources = DrawResources(
      pixelBuffer: frame.pixelBuffer,
      metalTexture: cvTexture,
      texture: sourceTexture
    )
    return (resources, uniforms)
  }

  private func completeDraw() {
    shared.lock.lock()
    if shared.inFlight > 0 {
      shared.inFlight -= 1
    }
    shared.lock.unlock()
    requestMainRedrawIfNeeded()
  }
}

@MainActor
extension FrameRenderer {
  fileprivate func handleDrawableSizeWillChange(_ size: CGSize) {
    shared.lock.lock()
    guard !shared.shuttingDown else {
      shared.lock.unlock()
      return
    }
    if shared.latest != nil {
      shared.needsRedraw = true
    } else {
      shared.needsBlank = true
    }
    shared.lock.unlock()
    requestMainRedrawIfNeeded()
  }

  fileprivate func draw(in view: MTKView) {
    guard let (pending, generation) = reserveDraw() else { return }
    encodeDraw(view: view, pending: pending, generation: generation)
  }
}
