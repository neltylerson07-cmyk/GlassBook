import Foundation
import Combine
import ScreenCaptureKit
import CoreGraphics
import Cocoa
import Metal
import MetalKit
import MetalPerformanceShaders

struct PreparedDisplayTexture: @unchecked Sendable {
    let texture: MTLTexture
    let blurredTexture: MTLTexture
}

struct MultiScreenSnapshots {
    var builtinSnapshot: CGImage?
    var builtinScreen: NSScreen?
    var builtinTextures: PreparedDisplayTexture?

    var hasBuiltin: Bool {
        builtinSnapshot != nil || builtinTextures != nil
    }
}

enum TextureResolutionQuality: String, CaseIterable, Identifiable {
    case efficient = "Efficient (Half-Res, ~6MB)"
    case balanced = "Balanced (~12MB)"
    case native = "Native (Full Retina)"

    var id: String { rawValue }

    var scaleFactor: Double {
        switch self {
        case .efficient: return 0.50
        case .balanced:  return 0.75
        case .native:    return 1.00
        }
    }
}

@MainActor
final class ScreenCaptureManager: ObservableObject {
    @Published var textureQuality: TextureResolutionQuality = {
        if let raw = UserDefaults.standard.string(forKey: "textureResolutionQuality"),
           let quality = TextureResolutionQuality(rawValue: raw) {
            return quality
        }
        return .efficient
    }() {
        didSet {
            UserDefaults.standard.set(textureQuality.rawValue, forKey: "textureResolutionQuality")
            invalidateSnapshots()
        }
    }

    private let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    private lazy var metalQueue: MTLCommandQueue? = metalDevice?.makeCommandQueue()

    private var inFlightCaptureTask: Task<MultiScreenSnapshots, Never>?
    private var warmSnapshots: MultiScreenSnapshots?
    private var lastCaptureTimestamp: CFTimeInterval = 0.0

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func isBuiltin(screen: NSScreen) -> Bool {
        guard let id = displayID(for: screen) else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    /// Prepares Metal texture and GPU-blurred texture asynchronously on any thread.
    nonisolated static func prepareTextures(
        from image: CGImage,
        device: (any MTLDevice)?,
        queue: (any MTLCommandQueue)?,
        scaleFactor: Double = 0.5
    ) -> PreparedDisplayTexture? {
        guard let device = device, let queue = queue else { return nil }

        let loader = MTKTextureLoader(device: device)
        guard let sourceTexture = try? loader.newTexture(cgImage: image, options: [
            .SRGB: false,
            .generateMipmaps: true,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
        ]) else {
            return nil
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: sourceTexture.pixelFormat,
            width: sourceTexture.width,
            height: sourceTexture.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]

        guard let target = device.makeTexture(descriptor: desc),
              let commandBuffer = queue.makeCommandBuffer() else {
            return nil
        }

        let sigma = max(Float(40.0 * scaleFactor), 12.0)
        let blurFilter = MPSImageGaussianBlur(device: device, sigma: sigma)
        blurFilter.edgeMode = .clamp
        blurFilter.encode(commandBuffer: commandBuffer, sourceTexture: sourceTexture, destinationTexture: target)
        commandBuffer.commit()

        return PreparedDisplayTexture(texture: sourceTexture, blurredTexture: target)
    }

    private let freshnessDuration: CFTimeInterval = 2.5

    /// Synchronous zero-latency snapshot getter for instant presentation.
    func getImmediateSnapshots() -> MultiScreenSnapshots? {
        guard isFresh, let warm = warmSnapshots, warm.hasBuiltin else { return nil }
        return warm
    }

    /// Checks if the cached snapshot is recently taken (within last 2.5 seconds).
    var isFresh: Bool {
        guard warmSnapshots?.hasBuiltin == true else { return false }
        return (CACurrentMediaTime() - lastCaptureTimestamp) < freshnessDuration
    }

    var hasWarmOrInFlightCapture: Bool {
        inFlightCaptureTask != nil || warmSnapshots != nil
    }

    /// Starts a proactive background capture so snapshots are immediately available when the lid reaches 90°.
    func precapture(force: Bool = false) {
        if !force && (inFlightCaptureTask != nil || isFresh) {
            return
        }
        if inFlightCaptureTask != nil {
            return
        }
        inFlightCaptureTask = Task { [weak self] in
            guard let self = self else { return MultiScreenSnapshots() }
            let snaps = await self.performCaptureAllScreens()
            guard !Task.isCancelled else { return MultiScreenSnapshots() }
            if snaps.hasBuiltin {
                self.warmSnapshots = snaps
                self.lastCaptureTimestamp = CACurrentMediaTime()
            }
            self.inFlightCaptureTask = nil
            return snaps
        }
    }

    /// Refreshes snapshots in the background and returns the new result if successful.
    func refreshSnapshots() async -> MultiScreenSnapshots? {
        if let inFlight = inFlightCaptureTask {
            let snaps = await inFlight.value
            return snaps.hasBuiltin ? snaps : nil
        }
        let snaps = await performCaptureAllScreens()
        if snaps.hasBuiltin {
            self.warmSnapshots = snaps
            self.lastCaptureTimestamp = CACurrentMediaTime()
            return snaps
        }
        return nil
    }

    /// Discards in-flight capture task and clears cached snapshots.
    func cancelPrecapture() {
        inFlightCaptureTask?.cancel()
        inFlightCaptureTask = nil
        invalidateSnapshots()
    }

    /// Invalidates and clears warm snapshots so stale images are never presented.
    func invalidateSnapshots() {
        warmSnapshots = nil
        lastCaptureTimestamp = 0.0
    }

    /// Captures snapshots across all connected displays (uses warm snapshot if available, or awaits in-flight).
    func captureAllScreens() async -> MultiScreenSnapshots {
        if let warm = warmSnapshots, warm.hasBuiltin && isFresh {
            return warm
        }
        if let inFlight = inFlightCaptureTask {
            let snaps = await inFlight.value
            self.inFlightCaptureTask = nil
            if snaps.hasBuiltin {
                self.warmSnapshots = snaps
                self.lastCaptureTimestamp = CACurrentMediaTime()
                return snaps
            }
        }
        let snaps = await performCaptureAllScreens()
        if snaps.hasBuiltin {
            self.warmSnapshots = snaps
            self.lastCaptureTimestamp = CACurrentMediaTime()
        }
        return snaps
    }

    /// Internal capture worker executing capture and background texture preparation for the built-in display.
    private func performCaptureAllScreens() async -> MultiScreenSnapshots {
        var result = MultiScreenSnapshots()

        do {
            // Excluding desktop windows dramatically reduces WindowServer query overhead
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let bundleID = Bundle.main.bundleIdentifier
            let excludedApps = content.applications.filter { $0.bundleIdentifier == bundleID }

            let allScreens = NSScreen.screens
            let builtin = allScreens.first(where: { Self.isBuiltin(screen: $0) }) ?? NSScreen.main ?? allScreens.first
            result.builtinScreen = builtin

            let device = self.metalDevice
            let queue = self.metalQueue
            let scaleFactor = self.textureQuality.scaleFactor

            if let builtinScreen = builtin,
               let builtinID = Self.displayID(for: builtinScreen),
               let display = content.displays.first(where: { $0.displayID == builtinID }) ?? content.displays.first {
                let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
                let config = SCStreamConfiguration()
                // SCDisplay.width and display.height are already physical native pixels.
                // Applying configurable scaleFactor drops memory by up to 90% without perceptible loss in 3D perspective warp.
                let targetWidth = max(Int(Double(display.width) * scaleFactor), 1280)
                let targetHeight = Int(Double(targetWidth) * Double(display.height) / Double(display.width))
                config.width = targetWidth
                config.height = targetHeight
                config.showsCursor = false
                config.scalesToFit = true

                if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    let textures = Self.prepareTextures(from: img, device: device, queue: queue, scaleFactor: scaleFactor)
                    result.builtinSnapshot = img
                    result.builtinTextures = textures
                }
            }

            return result
        } catch {
            print("Screen capture failed: \(error.localizedDescription)")
            return result
        }
    }

    @discardableResult
    func captureCurrentScreen() async -> CGImage? {
        let snapshots = await captureAllScreens()
        return snapshots.builtinSnapshot
    }
}
