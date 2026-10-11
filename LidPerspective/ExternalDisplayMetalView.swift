import SwiftUI
import MetalKit
import simd
import MetalPerformanceShaders

struct ExternalDisplayMetalView: NSViewRepresentable {
    var snapshot: CGImage?
    var preloadedTexture: MTLTexture? = nil
    var preloadedBlurredTexture: MTLTexture? = nil
    var sensor: LidSensor? = nil
    var fallbackAngle: Double = 90.0
    var lookahead: Double = 0.4
    var activationCount: Int = 0
    var maxZoomOut: Float = 0.10
    var maxBlur: Float = 1.00
    var maxDarken: Float = 0.40
    var isSettling: Bool = false
    var isTransitionBlurEnabled: Bool = true
    var isRippleEnabled: Bool = true
    var rippleIntensity: Float = 1.00
    var isRippling: Bool = false
    var onRippleCompleted: (() -> Void)? = nil
    var onSettleCompleted: (() -> Void)? = nil
    var onFirstFrame: (() -> Void)? = nil

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true

        if let colorSpace = snapshot?.colorSpace ?? NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) {
            mtkView.colorspace = colorSpace
        }

        mtkView.preferredFramesPerSecond = 120
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        if let colorSpace = snapshot?.colorSpace ?? nsView.window?.screen?.colorSpace?.cgColorSpace ?? NSScreen.main?.colorSpace?.cgColorSpace {
            if nsView.colorspace != colorSpace {
                nsView.colorspace = colorSpace
            }
        }

        if context.coordinator.activationCount != activationCount {
            context.coordinator.activationCount = activationCount
            context.coordinator.reset(angle: fallbackAngle)
        }

        context.coordinator.onFirstFrame = onFirstFrame
        context.coordinator.isTransitionBlurEnabled = isTransitionBlurEnabled
        context.coordinator.isRippleEnabled = isRippleEnabled
        context.coordinator.rippleIntensity = rippleIntensity
        context.coordinator.sensor = sensor
        context.coordinator.lookahead = lookahead
        context.coordinator.onSettleCompleted = onSettleCompleted
        context.coordinator.onRippleCompleted = onRippleCompleted

        if isSettling && !context.coordinator.isSettling {
            context.coordinator.startSettling()
        } else if !isSettling && context.coordinator.isSettling {
            context.coordinator.cancelSettling()
        }

        if isRippling && !context.coordinator.isRippling {
            context.coordinator.triggerRipple(onCompleted: onRippleCompleted)
        } else if !isRippling && context.coordinator.isRippling {
            context.coordinator.cancelRipple()
        }

        context.coordinator.updateParameters(
            snapshot: snapshot,
            preloadedTexture: preloadedTexture,
            preloadedBlurredTexture: preloadedBlurredTexture,
            targetAngle: fallbackAngle,
            maxZoomOut: maxZoomOut,
            maxBlur: maxBlur,
            maxDarken: maxDarken
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var onFirstFrame: (() -> Void)?
        var sensor: LidSensor?
        var lookahead: Double = 0.4
        var activationCount: Int = -1
        var isTransitionBlurEnabled: Bool = true
        var isRippleEnabled: Bool = true
        var rippleIntensity: Float = 1.00
        private(set) var isRippling: Bool = false
        private var rippleStartTime: CFTimeInterval = 0.0
        private let rippleDuration: CFTimeInterval = 0.40
        var onRippleCompleted: (() -> Void)? = nil
        private var introStartTime: CFTimeInterval = 0.0
        private let introDuration: CFTimeInterval = 0.20

        func reset(angle: Double) {
            let initial = min(angle, 90.0)
            self.smoothedAngle = 90.0
            self.targetAngle = initial
            self.isFirstFrame = true
            self.isSettling = false
            self.hasFiredFirstFrame = false
            self.introStartTime = CACurrentMediaTime()
            cancelRipple()
        }

        func triggerRipple(onCompleted: (() -> Void)? = nil) {
            guard isRippleEnabled else {
                onCompleted?()
                return
            }
            isRippling = true
            rippleStartTime = CACurrentMediaTime()
            onRippleCompleted = onCompleted
        }

        func cancelRipple() {
            isRippling = false
            rippleStartTime = 0.0
            onRippleCompleted = nil
        }
        private var hasFiredFirstFrame = false

        // Shared static GPU assets to eliminate main-thread recompilations
        private static let sharedDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
        private static let sharedCommandQueue: MTLCommandQueue? = sharedDevice?.makeCommandQueue()
        private static let sharedPipelineState: MTLRenderPipelineState? = {
            guard let device = sharedDevice,
                  let library = device.makeDefaultLibrary(),
                  let vertexFunc = library.makeFunction(name: "vertex_main"),
                  let fragmentFunc = library.makeFunction(name: "fragment_external_display") else { return nil }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunc
            desc.fragmentFunction = fragmentFunc
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: desc)
        }()
        private static let sharedSampler: MTLSamplerState? = {
            guard let device = sharedDevice else { return nil }
            let desc = MTLSamplerDescriptor()
            desc.minFilter = .linear
            desc.magFilter = .linear
            desc.sAddressMode = .clampToEdge
            desc.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: desc)
        }()

        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var texture: MTLTexture?
        private var blurredTexture: MTLTexture?
        private var textureSampler: MTLSamplerState?

        private var lastLoadedSnapshotID: CGImage?

        private var isFirstFrame = true
        private var targetAngle: Double = 90.0
        private var smoothedAngle: Double = 90.0
        private var maxZoomOut: Float = 0.10
        private var maxBlur: Float = 1.00
        private var maxDarken: Float = 0.40

        private(set) var isSettling: Bool = false
        private var settleStartTime: CFTimeInterval = 0.0
        private let settleDuration: CFTimeInterval = 0.32
        private var frozenAngle: Double = 90.0
        var onSettleCompleted: (() -> Void)?

        struct ExternalDisplayUniforms {
            var angle: Float
            var settleProgress: Float
            var maxZoomOut: Float
            var maxBlur: Float
            var maxDarken: Float
            var aspect: Float
            var transitionBlur: Float
            var pad0: Float = 0.0
            var rippleProgress: Float = -1.0
            var rippleIntensity: Float = 1.0
            var pad1: Float = 0.0
            var pad2: Float = 0.0
        }

        override init() {
            super.init()
            self.device = Self.sharedDevice
            self.commandQueue = Self.sharedCommandQueue
            self.pipelineState = Self.sharedPipelineState
            self.textureSampler = Self.sharedSampler
        }

        func startSettling() {
            guard !isSettling else { return }
            isSettling = true
            settleStartTime = CACurrentMediaTime()
            frozenAngle = smoothedAngle
        }

        func cancelSettling() {
            isSettling = false
            cancelRipple()
        }

        func updateParameters(
            snapshot: CGImage?,
            preloadedTexture: MTLTexture? = nil,
            preloadedBlurredTexture: MTLTexture? = nil,
            targetAngle: Double,
            maxZoomOut: Float,
            maxBlur: Float,
            maxDarken: Float
        ) {
            self.targetAngle = targetAngle
            if isFirstFrame {
                self.smoothedAngle = min(targetAngle, 90.0)
            }
            self.maxZoomOut = maxZoomOut
            self.maxBlur = maxBlur
            self.maxDarken = maxDarken

            // Use pre-prepared GPU textures directly if available
            if let preloaded = preloadedTexture, let preloadedBlur = preloadedBlurredTexture {
                self.texture = preloaded
                self.blurredTexture = preloadedBlur
            } else if let snapshot = snapshot, snapshot !== lastLoadedSnapshotID, let device = self.device {
                self.lastLoadedSnapshotID = snapshot
                let loader = MTKTextureLoader(device: device)
                let loadedTexture = try? loader.newTexture(cgImage: snapshot, options: [
                    .SRGB: false,
                    .generateMipmaps: false,
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue | MTLTextureUsage.shaderWrite.rawValue)
                ])
                self.texture = loadedTexture

                if let sourceTexture = loadedTexture {
                    self.blurredTexture = makeBlurredTexture(from: sourceTexture, device: device, sigma: 40)
                }
            }
        }

        private func makeBlurredTexture(from source: MTLTexture, device: MTLDevice, sigma: Float) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: source.pixelFormat,
                width: source.width,
                height: source.height,
                mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite]

            guard let target = device.makeTexture(descriptor: desc),
                  let queue = self.commandQueue,
                  let commandBuffer = queue.makeCommandBuffer() else {
                return nil
            }

            let blurFilter = MPSImageGaussianBlur(device: device, sigma: sigma)
            blurFilter.edgeMode = .clamp
            blurFilter.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: target)
            commandBuffer.commit()

            return target
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipelineState = pipelineState,
                  let drawable = view.currentDrawable,
                  let renderPass = view.currentRenderPassDescriptor,
                  let texture = texture,
                  let blurredTexture = blurredTexture else { return }

            renderPass.colorAttachments[0].loadAction = .dontCare
            renderPass.colorAttachments[0].storeAction = .store

            guard let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }

            let now = CACurrentMediaTime()

            var transitionBlur: Float = 0.0
            if isTransitionBlurEnabled && introStartTime > 0.0 {
                let elapsed = now - introStartTime
                let t = min(max(Float(elapsed / introDuration), 0.0), 1.0)
                let factor = 1.0 - t
                transitionBlur = factor * factor
                if t >= 1.0 {
                    introStartTime = 0.0
                    transitionBlur = 0.0
                }
            }

            var settleFactor: Float = 0.0
            if isSettling {
                let elapsed = now - settleStartTime
                let t = min(max(Float(elapsed / settleDuration), 0.0), 1.0)
                settleFactor = 1.0 - pow(1.0 - t, 3.0)

                if t >= 1.0 {
                    isSettling = false
                    settleFactor = 1.0
                    if isRippleEnabled && !isRippling {
                        triggerRipple { [weak self] in
                            self?.onSettleCompleted?()
                        }
                    } else {
                        DispatchQueue.main.async { [weak self] in
                            self?.onSettleCompleted?()
                        }
                    }
                }
            } else if isRippling {
                settleFactor = 1.0
            }

            var currentRippleProgress: Float = -1.0
            if isRippling {
                let elapsed = now - rippleStartTime
                let t = min(max(Float(elapsed / rippleDuration), 0.0), 1.0)
                currentRippleProgress = t
                if t >= 1.0 {
                    isRippling = false
                    currentRippleProgress = -1.0
                    let completion = onRippleCompleted
                    onRippleCompleted = nil
                    DispatchQueue.main.async {
                        completion?()
                    }
                }
            }

            let targetAngle: Double
            if isSettling {
                targetAngle = frozenAngle
            } else if let sensor = self.sensor {
                targetAngle = min(sensor.extrapolatedAngle(lookahead: self.lookahead), 90.0)
            } else {
                targetAngle = min(self.targetAngle, 90.0)
            }

            if isFirstFrame {
                isFirstFrame = false
                if isTransitionBlurEnabled {
                    self.smoothedAngle = 90.0
                } else {
                    self.smoothedAngle = targetAngle
                }
            } else if isSettling {
                self.smoothedAngle = frozenAngle
            } else {
                let speed = abs(sensor?.latestVelocity ?? 0.0)
                let smoothingFactor = min(max(0.25 + speed * 0.005, 0.25), 0.40)
                self.smoothedAngle += (targetAngle - self.smoothedAngle) * smoothingFactor
            }

            let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
            let angleRadians = Float(smoothedAngle * (.pi / 180.0))

            var uniforms = ExternalDisplayUniforms(
                angle: angleRadians,
                settleProgress: settleFactor,
                maxZoomOut: self.maxZoomOut,
                maxBlur: self.maxBlur,
                maxDarken: self.maxDarken,
                aspect: aspect,
                transitionBlur: transitionBlur,
                pad0: 0.0,
                rippleProgress: currentRippleProgress,
                rippleIntensity: self.rippleIntensity,
                pad1: 0.0,
                pad2: 0.0
            )

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ExternalDisplayUniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentTexture(blurredTexture, index: 1)
            encoder.setFragmentSamplerState(textureSampler, index: 0)

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()

            if !hasFiredFirstFrame {
                hasFiredFirstFrame = true
                DispatchQueue.main.async { [weak self] in
                    self?.onFirstFrame?()
                }
            }
        }
    }
}
