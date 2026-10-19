import SwiftUI
import AVFoundation

@main
struct LidPerspectiveApp: App {
    @StateObject private var sensor: LidSensor
    @StateObject private var captureManager: ScreenCaptureManager
    @StateObject private var bootstrap: AppBootstrap
    @StateObject private var overlayController: FullscreenOverlayController
    @StateObject private var autoManager: AutoPerspectiveManager
    @StateObject private var headTracker = HeadTracker.shared

    init() {
        let sensorInstance = LidSensor()
        let captureInstance = ScreenCaptureManager()
        let overlayInstance = FullscreenOverlayController()
        let bootstrapInstance = AppBootstrap()
        let autoInstance = AutoPerspectiveManager(
            sensor: sensorInstance,
            captureManager: captureInstance,
            overlayController: overlayInstance
        )

        _sensor = StateObject(wrappedValue: sensorInstance)
        _captureManager = StateObject(wrappedValue: captureInstance)
        _overlayController = StateObject(wrappedValue: overlayInstance)
        _bootstrap = StateObject(wrappedValue: bootstrapInstance)
        _autoManager = StateObject(wrappedValue: autoInstance)
    }

    var body: some Scene {
        // Background Menu Bar Extra (Persistent agent in macOS menu bar)
        MenuBarExtra("LidPerspective", systemImage: "laptopcomputer.and.arrow.down") {
            MenuBarMenuView(autoManager: autoManager)
        }

        // Auxiliary Settings Window (Openable from Menu Bar or on launch)
        WindowGroup("LidPerspective Settings", id: "settings") {
            ContentView(
                sensor: sensor,
                captureManager: captureManager,
                bootstrap: bootstrap,
                overlayController: overlayController,
                autoManager: autoManager,
                headTracker: headTracker
            )
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Menu Bar View (Agent Interface)
struct MenuBarMenuView: View {
    @ObservedObject var autoManager: AutoPerspectiveManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Automatic Perspective (<90°)", isOn: $autoManager.isAutoModeEnabled)
            Toggle("Auto-Settle Below 90°", isOn: $autoManager.isAutoSettleEnabled)

            Divider()

            Button {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit LidPerspective", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

// MARK: - Settings Tab Definition
private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case effects = "Effects"
    case clock = "Clock"
    case tracking = "Tracking & Sensor"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .effects: return "sparkles"
        case .clock: return "clock"
        case .tracking: return "person.crop.circle"
        }
    }
}

// MARK: - Sensor Readings Box (Isolated View to Prevent Global Invalidation)
private struct SensorReadingsBox: View {
    @ObservedObject var sensor: LidSensor

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Lid Hinge Angle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f°", sensor.displayAngle))
                    .font(.title3.weight(.bold).monospacedDigit())
            }

            HStack {
                Text("Angular Velocity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.1f°/s", sensor.currentVelocity))
                    .font(.body.monospacedDigit())
            }

            HStack {
                Text("Sensor Status")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(sensor.isAvailable ? "Connected (IOHID)" : "Simulation Mode")
                    .font(.caption.bold())
                    .foregroundStyle(sensor.isAvailable ? .green : .orange)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4))
        .cornerRadius(10)
    }
}

// MARK: - Shortcuts Guide Box
private struct ShortcutsGuideBox: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keyboard Shortcuts (While Lid <90°)")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("C").font(.caption.bold().monospaced())
                    Text("Open / Close Calibrator HUD").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("T").font(.caption.bold().monospaced())
                    Text("Toggle 3D Perspective Clock").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("F").font(.caption.bold().monospaced())
                    Text("Toggle Frosted Glass Effect").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("K").font(.caption.bold().monospaced())
                    Text("Toggle Keyboard Reflection").font(.caption).foregroundStyle(.secondary)
                }
                GridRow {
                    Text("ESC").font(.caption.bold().monospaced())
                    Text("Exit Perspective Overlay").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3))
        .cornerRadius(8)
    }
}

// MARK: - Main Settings & Diagnostics Window
struct ContentView: View {
    let sensor: LidSensor
    @ObservedObject var captureManager: ScreenCaptureManager
    @ObservedObject var bootstrap: AppBootstrap
    @ObservedObject var overlayController: FullscreenOverlayController
    @ObservedObject var autoManager: AutoPerspectiveManager
    @ObservedObject var headTracker: HeadTracker

    @State private var selectedTab: SettingsTab = .general
    @State private var isRunningDiagnostics: Bool = false
    @State private var diagnosticMessage: String? = nil
    @State private var keyMonitor: Any? = nil

    var body: some View {
        VStack(spacing: 12) {
            // Header with status indicator
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text("GlassBook")
                        .font(.title3.bold())
                    Text("Simulates a glass door effect when the lid is tilted below 90 degrees")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Armed status badge
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusIndicatorColor)
                        .frame(width: 8, height: 8)
                    Text(autoManager.statusDescription)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5))
                .clipShape(Capsule())
            }

            // Tab Selector
            Picker("Settings Tab", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            // Tab Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    switch selectedTab {
                    case .general:
                        generalTabContent
                    case .effects:
                        effectsTabContent
                    case .clock:
                        clockTabContent
                    case .tracking:
                        trackingTabContent
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(18)
        .frame(width: 520, height: 460)
        .background(WindowAccessor { window in
            window.title = "LidPerspective Settings"
            window.identifier = NSUserInterfaceItemIdentifier("settings")
            overlayController.viewState.settingsWindow = window
            overlayController.viewState.isSettingsWindowOpen = true
            overlayController.viewState.isSettingsWindowFocused = true
        })
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            overlayController.viewState.isSettingsWindowOpen = true
            setupKeyMonitor()
            headTracker.retainTracking()
        }
        .onDisappear {
            headTracker.releaseTracking()
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
            overlayController.viewState.isSettingsWindowOpen = false
            overlayController.viewState.isSettingsWindowFocused = false
            // When Settings closes, hide from Dock and run quietly in the background
            NSApp.setActivationPolicy(.accessory)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow,
               window == overlayController.viewState.settingsWindow || window.identifier?.rawValue == "settings" || window.title.contains("Settings") {
                overlayController.viewState.isSettingsWindowOpen = false
                overlayController.viewState.isSettingsWindowFocused = false
                NSApp.setActivationPolicy(.accessory)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow,
               window == overlayController.viewState.settingsWindow || window.title.contains("Settings") || window.identifier?.rawValue == "settings" {
                overlayController.viewState.isSettingsWindowFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow,
               window == overlayController.viewState.settingsWindow || window.title.contains("Settings") || window.identifier?.rawValue == "settings" {
                overlayController.viewState.isSettingsWindowFocused = false
            }
        }
        .onKeyPress(KeyEquivalent("c")) {
            if handleKeyPress("c") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("C")) {
            if handleKeyPress("c") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("f")) {
            if handleKeyPress("f") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("F")) {
            if handleKeyPress("f") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("k")) {
            if handleKeyPress("k") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("K")) {
            if handleKeyPress("k") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("h")) {
            if handleKeyPress("h") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("H")) {
            if handleKeyPress("h") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("t")) {
            if handleKeyPress("t") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("T")) {
            if handleKeyPress("t") { return .handled }
            return .ignored
        }
    }

    // MARK: - Tab Views
    @ViewBuilder
    private var generalTabContent: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $autoManager.isAutoModeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Automatic Perspective")
                            .font(.body.weight(.medium))
                        Text("Automatically takes a screenshot and engages perspective view when the lid passes below 90°.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Return to Usable Desktop")
                                .font(.body.weight(.medium))
                            Text(autoManager.isAutoSettleEnabled && autoManager.autoSettleDelay > 0
                                ? "When the lid is paused below 90° for >\(autoManager.formattedDelay), smoothly unwarps and fades out back to desktop."
                                : "Auto-return disabled. Perspective view remains active until lid is opened past 90° or ESC is pressed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(autoManager.isAutoSettleEnabled && autoManager.autoSettleDelay > 0
                            ? String(format: "%.1f s", autoManager.autoSettleDelay)
                            : "Off")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(autoManager.isAutoSettleEnabled && autoManager.autoSettleDelay > 0 ? .primary : .secondary)
                    }

                    Slider(
                        value: Binding(
                            get: {
                                autoManager.isAutoSettleEnabled ? autoManager.autoSettleDelay : 0.0
                            },
                            set: { newValue in
                                let currentVal = autoManager.isAutoSettleEnabled ? autoManager.autoSettleDelay : 0.0
                                let stepVal = (newValue * 2.0).rounded() / 2.0
                                if abs(currentVal - stepVal) > 0.05 {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                }
                                if stepVal <= 0 {
                                    autoManager.autoSettleDelay = 0
                                    autoManager.isAutoSettleEnabled = false
                                } else {
                                    autoManager.autoSettleDelay = min(3.0, stepVal)
                                    autoManager.isAutoSettleEnabled = true
                                }
                            }
                        ),
                        in: 0...3,
                        step: 0.5,
                        label: {
                            Text("Auto-Return Delay")
                        },
                        minimumValueLabel: {
                            Text("Off (0s)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        },
                        maximumValueLabel: {
                            Text("3s")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    )
                    .sensoryFeedback(.levelChange, trigger: autoManager.autoSettleDelay)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .padding()
            .background(.quaternary.opacity(0.4))
            .cornerRadius(10)

            // Actions card
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        autoManager.triggerPerspective(showCalibrator: true)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "slider.horizontal.2.square")
                            Text("Launch Calibrator HUD")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        runDiagnostics()
                    } label: {
                        HStack(spacing: 6) {
                            if isRunningDiagnostics {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "stethoscope")
                            }
                            Text("Run Diagnostics")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunningDiagnostics)
                }

                if let message = diagnosticMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.25))
            .cornerRadius(10)
        }
    }

    @ViewBuilder
    private var effectsTabContent: some View {
        VStack(spacing: 12) {
            Toggle(isOn: overlayController.frostedGlassBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Frosted Glass Effect")
                        .font(.body.weight(.medium))
                    Text("Simulates an acid-etched frosted glass pane with a visible tactile grain pattern, micro-facet refraction, and Fresnel sheen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Toggle(isOn: overlayController.keyboardReflectionBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simulated Keyboard Reflection")
                        .font(.body.weight(.medium))
                    Text("Simulates specular laptop keyboard reflection on the screen glass between 45° and 90°.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Toggle(isOn: $overlayController.viewState.isTransitionBlurEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick Blur & Fade Transition")
                        .font(.body.weight(.medium))
                    Text("Softly blurs and fades between the live desktop and snapshot when perspective activates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Texture Quality & Memory Profile")
                        .font(.body.weight(.medium))
                    Text("Scales snapshot and blur texture memory by up to 90% without perceptible loss.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $captureManager.textureQuality) {
                    ForEach(TextureResolutionQuality.allCases) { quality in
                        Text(quality.rawValue).tag(quality)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
        .toggleStyle(.switch)
        .padding()
        .background(.quaternary.opacity(0.4))
        .cornerRadius(10)
    }

    @ViewBuilder
    private var clockTabContent: some View {
        VStack(spacing: 12) {
            Toggle(isOn: $autoManager.isClockModeEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Perspective Clock Mode")
                            .font(.body.weight(.medium))
                        if autoManager.isAutoSettleEnabled {
                            Text("(Active when Auto-Return is Off)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text("When Auto-Return is off, dims the desktop and projects a 3D perspective digital clock after 3 seconds of the lid remaining stationary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(autoManager.isAutoSettleEnabled)

            if autoManager.isClockModeEnabled {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Position")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: overlayController.clockPositionBinding) {
                            Section("Top") {
                                Text("Top Left").tag(ClockPosition.topLeading)
                                Text("Top").tag(ClockPosition.top)
                                Text("Top Right").tag(ClockPosition.topTrailing)
                            }
                            Section("Center") {
                                Text("Center Left").tag(ClockPosition.leading)
                                Text("Center").tag(ClockPosition.center)
                                Text("Center Right").tag(ClockPosition.trailing)
                            }
                            Section("Bottom") {
                                Text("Bottom Left").tag(ClockPosition.bottomLeading)
                                Text("Bottom").tag(ClockPosition.bottom)
                                Text("Bottom Right").tag(ClockPosition.bottomTrailing)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }

                    HStack {
                        Text("Size")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: overlayController.clockSizeBinding) {
                            ForEach(ClockSize.allCases) { size in
                                Text(size.rawValue).tag(size)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }

                    Divider()

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("StandBy Calendar & Clock Style")
                                .font(.subheadline.weight(.medium))
                            Text("Replaces single digital clock with Apple StandBy dual calendar & analog clock layout.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: overlayController.standByStyleBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .disabled(autoManager.isAutoSettleEnabled)
            }
        }
        .toggleStyle(.switch)
        .padding()
        .background(.quaternary.opacity(0.4))
        .cornerRadius(10)
    }

    @ViewBuilder
    private var trackingTabContent: some View {
        VStack(spacing: 12) {
            // Viewing Angle Adaptation
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Viewing Angle Adaptation")
                                .font(.body.weight(.medium))
                            if headTracker.mode != .disabled {
                                Circle()
                                    .fill(headTracker.isTrackingFace ? Color.green : (headTracker.isSnapping ? Color.blue : Color.orange))
                                    .frame(width: 8, height: 8)
                            }
                        }
                        Text(headTracker.mode.shortDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()

                    Picker("", selection: $headTracker.mode) {
                        ForEach(HeadTrackingMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                if headTracker.mode != .disabled {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Camera Access")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if headTracker.authorizationStatus == .authorized {
                                Text("Authorized")
                                    .font(.caption.bold())
                                    .foregroundStyle(.green)
                            } else if headTracker.authorizationStatus == .notDetermined {
                                Button("Grant Access…") {
                                    headTracker.requestPermission()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else {
                                Text("Denied")
                                    .font(.caption.bold())
                                    .foregroundStyle(.red)
                            }
                        }

                        if headTracker.authorizationStatus == .denied {
                            HStack {
                                Text("Camera permission is denied. Enable it in macOS System Settings.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Open Settings…") {
                                    headTracker.openCameraSettings()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(.top, 2)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(headTracker.mode == .snapshotOnClose ? "Viewing Reference" : "Live Tracking")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if headTracker.isTrackingFace {
                                    HStack(spacing: 10) {
                                        Text(String(format: "X: %+.2f", headTracker.currentHeadX))
                                        Text(String(format: "Y: %+.2f", headTracker.currentHeadY))
                                        Text(String(format: "Dist: %.2fx", headTracker.currentHeadZ))
                                    }
                                    .font(.caption2.monospacedDigit().bold())
                                    .foregroundStyle(.primary)
                                } else {
                                    Text(headTracker.isSnapping ? "Snapping face photo..." : "No reference snapped yet (Close lid to snap)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button {
                                headTracker.captureFaceSnapshot(force: true)
                            } label: {
                                HStack(spacing: 4) {
                                    if headTracker.isSnapping {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Image(systemName: "camera.viewfinder")
                                    }
                                    Text(headTracker.isSnapping ? "Snapping…" : "Capture Now")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(headTracker.authorizationStatus != .authorized || headTracker.isSnapping)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.35))
                    .cornerRadius(8)
                }
            }
            .padding()
            .background(.quaternary.opacity(0.4))
            .cornerRadius(10)

            // Live Sensor Readings Box
            SensorReadingsBox(sensor: sensor)

            // Shortcuts Guide
            ShortcutsGuideBox()
        }
    }

    private func setupKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let char = event.charactersIgnoringModifiers?.lowercased()
            if char == "c" {
                if sensor.displayAngle < 90.0 {
                    if overlayController.isShowing {
                        overlayController.viewState.showCalibrator.toggle()
                        if overlayController.viewState.showCalibrator {
                            overlayController.viewState.requestRender()
                        }
                    } else {
                        autoManager.triggerPerspective(showCalibrator: true)
                    }
                    return nil
                }
            } else if char == "t" {
                if overlayController.isShowing {
                    if overlayController.viewState.isClockActive {
                        overlayController.deactivateClockMode()
                    } else {
                        overlayController.viewState.currentLidAngle = sensor.displayAngle
                        overlayController.activateClockMode()
                    }
                    return nil
                }
            } else if char == "f" {
                overlayController.viewState.isFrostedGlassEnabled.toggle()
                if overlayController.viewState.showCalibrator {
                    overlayController.viewState.requestRender()
                }
                return nil
            } else if char == "k" {
                overlayController.viewState.isKeyboardReflectionEnabled.toggle()
                if overlayController.viewState.showCalibrator {
                    overlayController.viewState.requestRender()
                }
                return nil
            }
            return event
        }
    }

    private func handleKeyPress(_ key: String) -> Bool {
        if key.lowercased() == "c" {
            if sensor.displayAngle < 90.0 {
                if overlayController.isShowing {
                    overlayController.viewState.showCalibrator.toggle()
                    if overlayController.viewState.showCalibrator {
                        overlayController.viewState.requestRender()
                    }
                } else {
                    autoManager.triggerPerspective(showCalibrator: true)
                }
                return true
            }
        } else if key.lowercased() == "t" {
            if overlayController.isShowing {
                if overlayController.viewState.isClockActive {
                    overlayController.deactivateClockMode()
                } else {
                    overlayController.viewState.currentLidAngle = sensor.displayAngle
                    overlayController.activateClockMode()
                }
                return true
            }
        } else if key.lowercased() == "f" {
            overlayController.viewState.isFrostedGlassEnabled.toggle()
            if overlayController.viewState.showCalibrator {
                overlayController.viewState.requestRender()
            }
            return true
        } else if key.lowercased() == "k" {
            overlayController.viewState.isKeyboardReflectionEnabled.toggle()
            if overlayController.viewState.showCalibrator {
                overlayController.viewState.requestRender()
            }
            return true
        } else if key.lowercased() == "h" {
            headTracker.isEnabled.toggle()
            return true
        }
        return false
    }

    private var statusIndicatorColor: Color {
        if !autoManager.isAutoModeEnabled {
            return .gray
        } else if overlayController.isShowing {
            return .blue
        } else if autoManager.isCapturing {
            return .orange
        } else if autoManager.isArmed {
            return .green
        } else {
            return .yellow
        }
    }

    private func runDiagnostics() {
        isRunningDiagnostics = true
        diagnosticMessage = nil
        Task {
            await bootstrap.runDiagnostics()
            diagnosticMessage = "Diagnostics logged to console"
            isRunningDiagnostics = false
        }
    }
}

// MARK: - Window Accessor Helper
private struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                callback(window)
            }
        }
    }
}
