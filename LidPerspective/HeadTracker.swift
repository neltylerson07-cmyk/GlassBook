import Foundation
import AVFoundation
import Vision
import CoreGraphics
import os
import Combine
import AppKit

/// Operating mode for head tracking
enum HeadTrackingMode: String, CaseIterable, Identifiable {
    case snapshotOnClose = "Snapshot on Lid Close"
    case continuous = "Continuous Live Tracking"
    case disabled = "Disabled (Fixed Viewpoint)"

    var id: String { rawValue }

    var shortDescription: String {
        switch self {
        case .snapshotOnClose:
            return "Snaps face position once right as lid closes and turns camera off immediately (No continuous camera light, best privacy & performance)."
        case .continuous:
            return "Continuously tracks head position every frame while tilted (Camera remains active)."
        case .disabled:
            return "Fixed upright perspective from center."
        }
    }
}

/// Camera and facial tracking engine for off-axis perspective correction.
/// Supports both single-shot reference capture on lid close (recommended)
/// and continuous real-time tracking.
final class HeadTracker: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = HeadTracker()

    // MARK: - Atomic Fast-Path for Metal Render Loop
    private var _atomicHeadX: Float = 0.0
    private var _atomicHeadY: Float = 0.0
    private var _atomicHeadZ: Float = 1.0
    private var _atomicIsTracking: Bool = false
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    // MARK: - Tracking Modes & Published State
    @Published var mode: HeadTrackingMode = .snapshotOnClose {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "headTrackingMode")
            handleModeChanged()
        }
    }

    /// Legacy boolean binding for UI toggles
    var isEnabled: Bool {
        get { mode != .disabled }
        set { mode = newValue ? .snapshotOnClose : .disabled }
    }

    @Published private(set) var isTrackingFace: Bool = false
    @Published private(set) var isSnapping: Bool = false
    @Published private(set) var authorizationStatus: AVAuthorizationStatus = .notDetermined
    @Published private(set) var currentHeadX: Float = 0.0
    @Published private(set) var currentHeadY: Float = 0.0
    @Published private(set) var currentHeadZ: Float = 1.0
    @Published private(set) var lastSnapshotDate: Date? = nil
    @Published private(set) var rawFaceRect: CGRect = .zero

    // MARK: - AVFoundation & Vision Pipelines
    private var captureSession: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "com.lidperspective.headtracker", qos: .userInteractive)
    private var isSessionRunning: Bool = false
    private var activeRequestCount: Int = 0

    // Snapshot state
    private var isSnapshotPending: Bool = false
    private var snapshotTimeoutWorkItem: DispatchWorkItem? = nil
    private var lastSnapshotTimestamp: CFTimeInterval = 0.0

    // Filter & smoothing state (for continuous mode)
    private var smoothedX: Float = 0.0
    private var smoothedY: Float = 0.0
    private var smoothedZ: Float = 1.0
    private var lastDetectionTime: CFTimeInterval = 0.0
    private var uiUpdateCounter: Int = 0
    private var continuousFrameSkipCounter: Int = 0

    // Pre-allocated Vision face detection request using Neural Engine revision
    private lazy var faceDetectionRequest: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()

    // Reference calibration
    private let nominalFaceSize: Float = 0.22 // Typical face width ratio at ~50cm

    override init() {
        super.init()
        lock.initialize(to: os_unfair_lock())

        if let savedModeStr = UserDefaults.standard.string(forKey: "headTrackingMode"),
           let savedMode = HeadTrackingMode(rawValue: savedModeStr) {
            self.mode = savedMode
        } else if let legacyEnabled = UserDefaults.standard.object(forKey: "isHeadTrackingEnabled") as? Bool {
            self.mode = legacyEnabled ? .snapshotOnClose : .disabled
        } else {
            self.mode = .snapshotOnClose
        }

        self.authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        stopAllTracking()
        lock.deallocate()
    }

    @objc private func handleAppDidBecomeActive() {
        refreshAuthorization()
    }

    func refreshAuthorization() {
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        DispatchQueue.main.async {
            self.authorizationStatus = auth
        }
        if auth == .authorized {
            captureQueue.async { [weak self] in
                guard let self = self else { return }
                if self.mode == .continuous && self.activeRequestCount > 0 && self.captureSession == nil {
                    self.setupAndStartSession()
                }
            }
        }
    }

    func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestPermission() {
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        if auth == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorizationStatus = granted ? .authorized : .denied
                }
                if granted {
                    self?.captureQueue.async {
                        if self?.mode == .continuous && (self?.activeRequestCount ?? 0) > 0 {
                            self?.setupAndStartSession()
                        }
                    }
                }
            }
        } else if auth == .denied || auth == .restricted {
            openCameraSettings()
        }
    }

    private func handleModeChanged() {
        if mode == .disabled {
            stopAllTracking()
        } else if mode == .continuous {
            if activeRequestCount > 0 {
                startContinuousTracking()
            }
        } else if mode == .snapshotOnClose {
            // Stop any continuous session; camera will only wake up on demand
            captureQueue.async { [weak self] in
                guard let self = self else { return }
                if !self.isSnapshotPending {
                    self.pauseSession()
                }
            }
        }
    }

    // MARK: - Metal Fast Query
    /// Thread-safe query invoked directly from MTKView draw loop (up to 120 FPS, 0ms main thread impact)
    func getHeadPosition() -> (x: Float, y: Float, z: Float, isTracking: Bool) {
        guard mode != .disabled else {
            return (0.0, 0.0, 1.0, false)
        }
        os_unfair_lock_lock(lock)
        let x = _atomicHeadX
        let y = _atomicHeadY
        let z = _atomicHeadZ
        let tracking = _atomicIsTracking
        os_unfair_lock_unlock(lock)
        return (x, y, z, tracking)
    }

    // MARK: - Snapshot Reference Capture (Recommended Mode)
    /// Captures the user's face position once, sets the viewing perspective reference, and immediately shuts down the camera.
    func captureFaceSnapshot(force: Bool = false) {
        guard mode != .disabled else { return }
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        guard auth == .authorized else {
            if auth == .notDetermined { requestPermission() }
            return
        }

        let now = CACurrentMediaTime()
        // Debounce if already captured within 0.6s (unless forced)
        if !force && (now - lastSnapshotTimestamp < 0.6) && _atomicIsTracking {
            return
        }

        guard !isSnapshotPending else { return }
        isSnapshotPending = true

        DispatchQueue.main.async { [weak self] in
            self?.isSnapping = true
        }

        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.setupAndStartSession()

            // Safety timeout: if no face found within 1.2s, shut camera off to prevent draining power
            self.snapshotTimeoutWorkItem?.cancel()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self = self, self.isSnapshotPending else { return }
                self.isSnapshotPending = false
                DispatchQueue.main.async {
                    self.isSnapping = false
                }
                if self.mode == .snapshotOnClose || self.mode != .continuous || self.activeRequestCount == 0 {
                    self.pauseSession()
                }
            }
            self.snapshotTimeoutWorkItem = timeout
            self.captureQueue.asyncAfter(deadline: .now() + 1.2, execute: timeout)
        }
    }

    /// Cancels any in-flight snapshot attempt and turns off the camera
    func cancelSnapshot() {
        captureQueue.async { [weak self] in
            guard let self = self, self.isSnapshotPending else { return }
            self.isSnapshotPending = false
            self.snapshotTimeoutWorkItem?.cancel()
            self.snapshotTimeoutWorkItem = nil
            DispatchQueue.main.async {
                self.isSnapping = false
            }
            if self.mode == .snapshotOnClose && self.activeRequestCount == 0 {
                self.pauseSession()
            }
        }
    }

    /// Resets the debounce timestamp so the next snapshot attempt runs immediately without delay
    func resetDebounce() {
        captureQueue.async { [weak self] in
            self?.lastSnapshotTimestamp = 0.0
        }
    }

    // MARK: - Continuous Tracking Control
    func retainTracking() {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.activeRequestCount += 1
            if self.mode == .continuous {
                self.setupAndStartSession()
            }
        }
    }

    func releaseTracking() {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.activeRequestCount = max(0, self.activeRequestCount - 1)
            if self.activeRequestCount == 0 && !self.isSnapshotPending {
                self.pauseSession()
            }
        }
    }

    private func startContinuousTracking() {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.isSessionRunning {
                self.setupAndStartSession()
            }
        }
    }

    private func stopAllTracking() {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            self.isSnapshotPending = false
            self.snapshotTimeoutWorkItem?.cancel()
            self.teardownSession()
        }

        // Reset coordinates to center
        os_unfair_lock_lock(lock)
        _atomicHeadX = 0.0
        _atomicHeadY = 0.0
        _atomicHeadZ = 1.0
        _atomicIsTracking = false
        os_unfair_lock_unlock(lock)

        DispatchQueue.main.async { [weak self] in
            self?.isTrackingFace = false
            self?.isSnapping = false
            self?.currentHeadX = 0.0
            self?.currentHeadY = 0.0
            self?.currentHeadZ = 1.0
        }
    }

    // MARK: - Camera Session Setup, Pause & Teardown
    private func setupAndStartSession() {
        guard captureSession == nil else {
            if let session = captureSession, !session.isRunning {
                session.startRunning()
                isSessionRunning = true
            }
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else if session.canSetSessionPreset(.medium) {
            session.sessionPreset = .medium
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )

        guard let device = discoverySession.devices.first(where: { $0.position == .front }) ?? discoverySession.devices.first,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }

        session.addInput(input)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ]
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            return
        }

        session.addOutput(videoOutput)
        session.commitConfiguration()

        session.startRunning()
        self.captureSession = session
        self.isSessionRunning = true
    }

    /// Stops camera streaming and turns off the indicator LED, keeping the session pipeline allocated for fast wakeup
    private func pauseSession() {
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }
        isSessionRunning = false
    }

    /// Completely releases camera hardware session
    private func teardownSession() {
        pauseSession()
        captureSession = nil
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard mode != .disabled else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // In continuous mode, skip every second frame to halve Vision CPU load while maintaining ~15-30 FPS tracking
        if !isSnapshotPending && mode == .continuous {
            continuousFrameSkipCounter += 1
            if continuousFrameSkipCounter % 2 != 0 {
                return
            }
        }

        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try requestHandler.perform([faceDetectionRequest])
            if let observation = faceDetectionRequest.results?.first {
                handleFaceObservation(observation)
            } else {
                handleNoFaceDetected()
            }
        } catch {
            handleNoFaceDetected()
        }
    }

    private func handleFaceObservation(_ observation: VNFaceObservation) {
        let box = observation.boundingBox
        let now = CACurrentMediaTime()
        lastDetectionTime = now

        let faceCenterX = Float(box.midX)
        let faceCenterY = Float(box.midY)
        let faceWidth = Float(box.width)
        let faceHeight = Float(box.height)

        // Lateral head position (+X = leaning to user's right)
        let targetX = min(max((0.5 - faceCenterX) * 2.2, -1.2), 1.2)

        // Vertical head position (+Y = head higher)
        let targetY = min(max((faceCenterY - 0.5) * 2.0, -1.0), 1.0)

        // Distance ratio (Z)
        let effectiveSize = max((faceWidth + faceHeight) * 0.5, 0.05)
        let targetZ = min(max(nominalFaceSize / effectiveSize, 0.5), 2.2)

        if isSnapshotPending {
            // SINGLE-SHOT SNAPSHOT PATH:
            // Lock in exact coordinates immediately, cancel timeout, and shut off camera!
            snapshotTimeoutWorkItem?.cancel()
            snapshotTimeoutWorkItem = nil
            isSnapshotPending = false
            lastSnapshotTimestamp = now

            os_unfair_lock_lock(lock)
            _atomicHeadX = targetX
            _atomicHeadY = targetY
            _atomicHeadZ = targetZ
            _atomicIsTracking = true
            os_unfair_lock_unlock(lock)

            smoothedX = targetX
            smoothedY = targetY
            smoothedZ = targetZ

            DispatchQueue.main.async { [weak self] in
                self?.isSnapping = false
                self?.isTrackingFace = true
                self?.currentHeadX = targetX
                self?.currentHeadY = targetY
                self?.currentHeadZ = targetZ
                self?.rawFaceRect = box
                self?.lastSnapshotDate = Date()
            }

            // In snapshot mode, immediately stop camera and turn off indicator LED
            if mode == .snapshotOnClose {
                pauseSession()
            }
            return
        }

        // CONTINUOUS TRACKING PATH:
        let alpha: Float = 0.28
        smoothedX += (targetX - smoothedX) * alpha
        smoothedY += (targetY - smoothedY) * alpha
        smoothedZ += (targetZ - smoothedZ) * alpha

        os_unfair_lock_lock(lock)
        _atomicHeadX = smoothedX
        _atomicHeadY = smoothedY
        _atomicHeadZ = smoothedZ
        _atomicIsTracking = true
        os_unfair_lock_unlock(lock)

        uiUpdateCounter += 1
        if uiUpdateCounter % 4 == 0 {
            let snapX = smoothedX
            let snapY = smoothedY
            let snapZ = smoothedZ
            DispatchQueue.main.async { [weak self] in
                self?.isTrackingFace = true
                self?.currentHeadX = snapX
                self?.currentHeadY = snapY
                self?.currentHeadZ = snapZ
                self?.rawFaceRect = box
            }
        }
    }

    private func handleNoFaceDetected() {
        if isSnapshotPending {
            // Still waiting for face in snapshot window; let timeout handle failure
            return
        }

        let now = CACurrentMediaTime()
        // If face lost for > 0.4s in continuous mode, smoothly decay back to center
        if now - lastDetectionTime > 0.4 {
            let decayAlpha: Float = 0.08
            smoothedX += (0.0 - smoothedX) * decayAlpha
            smoothedY += (0.0 - smoothedY) * decayAlpha
            smoothedZ += (1.0 - smoothedZ) * decayAlpha

            let isNearCenter = abs(smoothedX) < 0.05 && abs(smoothedY) < 0.05 && abs(smoothedZ - 1.0) < 0.05

            os_unfair_lock_lock(lock)
            _atomicHeadX = smoothedX
            _atomicHeadY = smoothedY
            _atomicHeadZ = smoothedZ
            _atomicIsTracking = !isNearCenter
            os_unfair_lock_unlock(lock)

            if isNearCenter {
                DispatchQueue.main.async { [weak self] in
                    self?.isTrackingFace = false
                }
            }
        }
    }
}
