import Foundation
import SwiftUI
import Combine


@MainActor
final class AutoPerspectiveManager: ObservableObject {
    @Published var isAutoModeEnabled: Bool = true {
        didSet {
            handleAutoModeToggled()
        }
    }
    private var previousNonZeroDelay: Double = 1.0

    @Published var autoSettleDelay: Double = 1.0 {
        didSet {
            let clamped = min(3.0, max(0.0, autoSettleDelay))
            if autoSettleDelay != clamped {
                autoSettleDelay = clamped
                return
            }
            if autoSettleDelay > 0 {
                previousNonZeroDelay = autoSettleDelay
                if !isAutoSettleEnabled {
                    isAutoSettleEnabled = true
                }
            } else {
                if isAutoSettleEnabled {
                    isAutoSettleEnabled = false
                }
            }
            builtinDwellTimerTask?.cancel()
            builtinDwellTimerTask = nil
            if isAutoSettleEnabled && autoSettleDelay > 0 && overlayController.isShowing && !overlayController.viewState.showCalibrator {
                clockTimerTask?.cancel()
                clockTimerTask = nil
                overlayController.deactivateClockMode()
                scheduleBuiltinDwellTimer()
            } else if isClockModeEnabled && (!isAutoSettleEnabled || autoSettleDelay <= 0) && overlayController.isShowing && !overlayController.viewState.showCalibrator {
                scheduleClockTimer()
            }
        }
    }

    @Published var isAutoSettleEnabled: Bool = true {
        didSet {
            if !isAutoSettleEnabled {
                builtinDwellTimerTask?.cancel()
                builtinDwellTimerTask = nil
                if isClockModeEnabled && overlayController.isShowing && !overlayController.viewState.showCalibrator {
                    scheduleClockTimer()
                }
            } else {
                clockTimerTask?.cancel()
                clockTimerTask = nil
                overlayController.deactivateClockMode()
                if autoSettleDelay <= 0 {
                    autoSettleDelay = previousNonZeroDelay > 0 ? previousNonZeroDelay : 1.0
                }
                if overlayController.isShowing && !overlayController.viewState.showCalibrator {
                    scheduleBuiltinDwellTimer()
                }
            }
        }
    }

    @Published var isClockModeEnabled: Bool = true {
        didSet {
            if !isClockModeEnabled {
                clockTimerTask?.cancel()
                clockTimerTask = nil
                overlayController.deactivateClockMode()
            } else {
                if (!isAutoSettleEnabled || autoSettleDelay <= 0) && overlayController.isShowing && !overlayController.viewState.showCalibrator {
                    scheduleClockTimer()
                }
            }
        }
    }

    var isExternalDisplayEnabled: Bool {
        get { overlayController.isExternalAnimationEnabled }
        set {
            overlayController.isExternalAnimationEnabled = newValue
            objectWillChange.send()
        }
    }

    var formattedDelay: String {
        if autoSettleDelay.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0fs", autoSettleDelay)
        } else {
            return String(format: "%.1fs", autoSettleDelay)
        }
    }


    @Published var isArmed: Bool = false
    @Published var isCapturing: Bool = false
    @Published var statusDescription: String = "Initializing..."

    let sensor: LidSensor
    let captureManager: ScreenCaptureManager
    let overlayController: FullscreenOverlayController

    let closeThreshold: Double = 90.0
    let rearmThreshold: Double = 92.0 // Hysteresis to prevent jitter near 90°
    let minUsableAngle: Double = 10.0 // Below 10° screen is closing shut
    let precaptureThreshold: Double = 105.0 // Proactively captures only when closing towards 90°
    let precaptureCancelThreshold: Double = 110.0

    // Separate settle tracking for built-in and external displays
    private var builtinDwellTimerTask: Task<Void, Never>?
    private var externalDwellTimerTask: Task<Void, Never>?
    private var clockTimerTask: Task<Void, Never>?
    private var dwellReferenceAngle: Double = 90.0
    private var lastSettledAngle: Double?
    private var lastDismissalTime: CFTimeInterval = 0.0

    init(
        sensor: LidSensor,
        captureManager: ScreenCaptureManager,
        overlayController: FullscreenOverlayController
    ) {
        self.sensor = sensor
        self.captureManager = captureManager
        self.overlayController = overlayController

        let initialAngle = sensor.displayAngle
        if initialAngle >= closeThreshold {
            self.isArmed = true
            self.statusDescription = "Armed — Close lid (<90°) to activate"
        } else {
            self.isArmed = false
            self.lastSettledAngle = initialAngle >= minUsableAngle ? initialAngle : nil
            self.statusDescription = "Open lid past 90° to arm automatic mode"
        }

        sensor.onAngleChanged = { [weak self] angle in
            self?.handleAngleUpdate(angle)
        }
    }

    func handleAngleUpdate(_ angle: Double) {
        guard isAutoModeEnabled else {
            cancelAllDwellTimers()
            statusDescription = "Automatic mode disabled"
            return
        }

        // If overlay is currently displayed on any screen
        if overlayController.isShowing {
            if angle >= closeThreshold {
                // Lid opened to 90° or wider: dismiss overlay and re-arm
                cancelAllDwellTimers()
                overlayController.deactivateClockMode()
                overlayController.cancelSettling()
                overlayController.dismiss()
                captureManager.cancelPrecapture()
                isArmed = true
                lastSettledAngle = nil
                lastDismissalTime = CACurrentMediaTime()
                statusDescription = "Armed — Close lid (<90°) to activate"
                return
            }

            if angle < minUsableAngle {
                // Lid closing shut (<10°)
                cancelAllDwellTimers()
                overlayController.deactivateClockMode()
                overlayController.cancelSettling()
                statusDescription = "Lid closing"
                return
            }

            // Overlay active between minUsableAngle and closeThreshold
            let velocity = abs(sensor.latestVelocity)
            let angleDelta = abs(angle - dwellReferenceAngle)
            let isMoving = (velocity > 2.0 || angleDelta > 0.8)

            if isMoving {
                dwellReferenceAngle = angle

                if overlayController.viewState.isClockActive {
                    overlayController.deactivateClockMode()
                }

                // If user resumes moving while settling, cancel immediately and resume live 3D perspective!
                if overlayController.isSettling || overlayController.isExternalSettling {
                    overlayController.cancelSettling()
                    lastSettledAngle = nil
                }

                // Restart external dwell timer if external overlay is still showing
                if overlayController.isExternalShowing {
                    scheduleExternalDwellTimer()
                }

                // Restart builtin dwell timer if enabled
                if isAutoSettleEnabled && autoSettleDelay > 0 {
                    scheduleBuiltinDwellTimer()
                } else if isClockModeEnabled {
                    scheduleClockTimer()
                }

                statusDescription = String(format: "Perspective active (%.1f°)", angle)
            } else {
                // Holding steady: schedule timers if not already active
                if overlayController.isExternalShowing && !overlayController.isExternalSettling && externalDwellTimerTask == nil {
                    scheduleExternalDwellTimer()
                }

                if isAutoSettleEnabled && autoSettleDelay > 0 && !overlayController.viewState.isSettling && builtinDwellTimerTask == nil {
                    scheduleBuiltinDwellTimer()
                } else if isClockModeEnabled && (!isAutoSettleEnabled || autoSettleDelay <= 0) && !overlayController.viewState.isClockActive && clockTimerTask == nil {
                    scheduleClockTimer()
                }

                if overlayController.viewState.isClockActive {
                    statusDescription = String(format: "Clock mode active (%.1f°) — Move lid to resume", angle)
                } else {
                    statusDescription = String(format: "Perspective active (%.1f°)", angle)
                }
            }
            return
        }

        // Overlay is not showing. Avoid capturing if already capturing.
        guard !isCapturing else { return }

        if angle >= closeThreshold {
            if !isArmed {
                isArmed = true
            }
            lastSettledAngle = nil
            statusDescription = "Armed — Close lid (<90°) to activate"

            // Pre-warm the builtin overlay window once so show() is 0ms
            overlayController.prepareBuiltinWindow(sensor: sensor)
        }

        // Proactive desktop capture when closing towards 90° (ScreenCaptureKit only, no camera)
        if angle >= closeThreshold {
            let isClosing = sensor.latestVelocity < -0.6
            if angle <= precaptureThreshold && isArmed {
                if isClosing && !captureManager.isFresh {
                    captureManager.precapture()
                }
            } else if angle > precaptureCancelThreshold || sensor.latestVelocity > 0.5 {
                captureManager.cancelPrecapture()
            }
        } else if angle < closeThreshold && angle >= minUsableAngle {
            let now = CACurrentMediaTime()
            let timeSinceDismissal = now - lastDismissalTime

            if isArmed {
                isArmed = false
                lastSettledAngle = nil
                triggerPerspective()
            } else if let settledAngle = lastSettledAngle {
                // Screen was settled at a low angle. Check if user deliberately adjusts the lid again!
                let velocity = abs(sensor.latestVelocity)
                let angleDelta = abs(angle - settledAngle)
                if timeSinceDismissal > 0.4 && ((velocity > 1.2 && angleDelta > 0.8) || angleDelta > 2.0) {
                    lastSettledAngle = nil
                    triggerPerspective()
                }
            } else if timeSinceDismissal > 0.3 {
                // Deliberate movement below 90° when not settled: reactivate perspective immediately
                lastSettledAngle = nil
                triggerPerspective()
            }
        }
    }

    /// Dwell timer for built-in laptop screen (perspective mode)
    private func scheduleBuiltinDwellTimer() {
        builtinDwellTimerTask?.cancel()
        guard isAutoSettleEnabled && autoSettleDelay > 0 else {
            builtinDwellTimerTask = nil
            return
        }
        let delay = autoSettleDelay
        builtinDwellTimerTask = Task { [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            self.handleBuiltinDwellTimeout()
        }
    }

    /// Dwell timer for external monitor(s) — ALWAYS active so external monitors remain usable!
    private func scheduleExternalDwellTimer() {
        externalDwellTimerTask?.cancel()
        guard overlayController.isExternalShowing else {
            externalDwellTimerTask = nil
            return
        }

        // Use autoSettleDelay if positive, otherwise fall back to 1.0s so it settles no matter what
        let delay = (isAutoSettleEnabled && autoSettleDelay > 0) ? autoSettleDelay : (previousNonZeroDelay > 0 ? previousNonZeroDelay : 1.0)

        externalDwellTimerTask = Task { [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            self.handleExternalDwellTimeout()
        }
    }

    private func cancelAllDwellTimers() {
        builtinDwellTimerTask?.cancel()
        builtinDwellTimerTask = nil
        externalDwellTimerTask?.cancel()
        externalDwellTimerTask = nil
        clockTimerTask?.cancel()
        clockTimerTask = nil
    }

    /// Dwell timer for digital clock mode when stationary with auto-settle off (3.0s delay)
    private func scheduleClockTimer() {
        clockTimerTask?.cancel()
        guard isClockModeEnabled && (!isAutoSettleEnabled || autoSettleDelay <= 0) else {
            clockTimerTask = nil
            return
        }
        clockTimerTask = Task { [weak self] in
            let nanoseconds = UInt64(3.0 * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            self.handleClockTimeout()
        }
    }

    private func handleClockTimeout() {
        guard overlayController.isShowing, !overlayController.viewState.isSettling else { return }
        guard !overlayController.viewState.showCalibrator else { return }
        guard isClockModeEnabled && (!isAutoSettleEnabled || autoSettleDelay <= 0) else { return }
        let currentAngle = sensor.displayAngle
        guard currentAngle >= minUsableAngle && currentAngle < closeThreshold else { return }

        overlayController.viewState.currentLidAngle = currentAngle
        overlayController.activateClockMode()
        statusDescription = String(format: "Clock mode active (%.1f°) — Move lid to resume", currentAngle)
    }

    private func handleBuiltinDwellTimeout() {
        guard overlayController.isShowing, !overlayController.viewState.isSettling else { return }
        guard !overlayController.viewState.showCalibrator else { return }
        let currentAngle = sensor.displayAngle
        guard currentAngle >= minUsableAngle && currentAngle < closeThreshold else { return }

        statusDescription = String(format: "Lid settled at %.1f° — Returning to screen...", currentAngle)
        let settledAngle = currentAngle

        overlayController.unwarpAndDismissBuiltin { [weak self] in
            guard let self = self else { return }
            self.lastDismissalTime = CACurrentMediaTime()
            self.lastSettledAngle = self.sensor.displayAngle
            self.statusDescription = String(format: "Screen ready (%.1f°) — Adjust lid to reactivate", self.sensor.displayAngle)
        }
    }

    private func handleExternalDwellTimeout() {
        guard overlayController.isExternalShowing, !overlayController.isExternalSettling else { return }
        overlayController.unwarpAndDismissExternal()
    }

    func triggerPerspective(showCalibrator: Bool = false) {
        guard !isCapturing && !overlayController.isShowing else {
            if overlayController.isShowing && showCalibrator {
                overlayController.viewState.showCalibrator = true
                overlayController.viewState.requestRender()
            }
            return
        }

        cancelAllDwellTimers()
        dwellReferenceAngle = sensor.displayAngle
        sensor.resetPrediction()

        if HeadTracker.shared.mode == .snapshotOnClose {
            HeadTracker.shared.captureFaceSnapshot()
        }

        // FAST PATH: If warm snapshots are already in memory, display IMMEDIATELY on this exact stack frame!
        if let immediateSnapshots = captureManager.getImmediateSnapshots() {
            self.overlayController.show(snapshots: immediateSnapshots, sensor: self.sensor, showCalibrator: showCalibrator) { [weak self] in
                self?.handleOverlayDismissed()
            }
            self.statusDescription = "Perspective active"

            if self.isAutoSettleEnabled && self.autoSettleDelay > 0 && !showCalibrator {
                self.scheduleBuiltinDwellTimer()
            } else if self.isClockModeEnabled && !showCalibrator {
                self.scheduleClockTimer()
            }
            if immediateSnapshots.hasExternalSnapshots && self.overlayController.isExternalAnimationEnabled {
                self.scheduleExternalDwellTimer()
            }

            return
        }

        // COLD PATH: If no warm snapshot exists, capture asynchronously
        isCapturing = true
        statusDescription = "Activating perspective..."

        Task { [weak self] in
            guard let self = self else { return }
            let snapshots = await self.captureManager.captureAllScreens()

            if snapshots.builtinSnapshot != nil || snapshots.hasExternalSnapshots {
                self.dwellReferenceAngle = self.sensor.displayAngle

                // Built-in dwell timer (respects user toggle)
                if self.isAutoSettleEnabled && self.autoSettleDelay > 0 && !showCalibrator {
                    self.scheduleBuiltinDwellTimer()
                } else if self.isClockModeEnabled && !showCalibrator {
                    self.scheduleClockTimer()
                }

                // External dwell timer: ALWAYS scheduled so external monitor remains usable
                if snapshots.hasExternalSnapshots && self.overlayController.isExternalAnimationEnabled {
                    self.scheduleExternalDwellTimer()
                }

                self.overlayController.show(snapshots: snapshots, sensor: self.sensor, showCalibrator: showCalibrator) { [weak self] in
                    self?.handleOverlayDismissed()
                }
                self.statusDescription = "Perspective active"
            } else {
                self.statusDescription = "Screen capture failed"
                if self.sensor.displayAngle < self.closeThreshold && self.sensor.displayAngle >= self.minUsableAngle {
                    self.isArmed = true
                }
            }
            self.isCapturing = false
        }
    }

    private func handleOverlayDismissed() {
        lastDismissalTime = CACurrentMediaTime()
        cancelAllDwellTimers()
        overlayController.deactivateClockMode()
        captureManager.invalidateSnapshots()
        sensor.resetPrediction()
        if sensor.displayAngle < closeThreshold && sensor.displayAngle >= minUsableAngle {
            isArmed = false
            lastSettledAngle = sensor.displayAngle
            statusDescription = String(format: "Screen ready (%.1f°) — Adjust lid to reactivate", sensor.displayAngle)
        } else if sensor.displayAngle >= closeThreshold {
            isArmed = true
            lastSettledAngle = nil
            statusDescription = "Armed — Close lid (<90°) to activate"
        } else {
            isArmed = false
            lastSettledAngle = nil
            statusDescription = "Open lid past 92° to re-arm"
        }
    }

    private func handleAutoModeToggled() {
        cancelAllDwellTimers()
        overlayController.deactivateClockMode()
        captureManager.cancelPrecapture()
        if !isAutoModeEnabled {
            statusDescription = "Automatic mode disabled"
        } else {
            if sensor.displayAngle >= rearmThreshold {
                isArmed = true
                statusDescription = "Armed — Close lid (<90°) to activate"
            } else {
                isArmed = false
                lastSettledAngle = sensor.displayAngle >= minUsableAngle ? sensor.displayAngle : nil
                statusDescription = "Open lid past 92° to arm automatic mode"
            }
        }
    }
}
