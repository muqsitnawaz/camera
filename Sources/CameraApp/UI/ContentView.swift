import AVFoundation
import SwiftUI

/// How big the popover's picture is, on its long side.
enum PopoverSize: Int, CaseIterable {
    case small = 384, medium = 512, large = 720
    var name: String { ["Small", "Medium", "Large"][Self.allCases.firstIndex(of: self)!] }
}

struct ContentView: View {
    @ObservedObject var camera: Camera
    @ObservedObject var library: Library
    /// In its own window the picture fills whatever size the window is; in the popover it has a set size.
    var inWindow = false
    @AppStorage("popoverSize") private var popoverSize = PopoverSize.medium
    @AppStorage("timer") private var timerOn = false
    @AppStorage("timerSeconds") private var timerSeconds = 3
    @AppStorage("ringLightLevel") private var ringLight = RingLight.Level.off
    /// The displays the ring light shines from, by ID; empty is the main display.
    @AppStorage("ringLightDisplays") private var ringLightDisplays = ""
    @State private var overlay: Overlay?
    @State private var countdown: Int?
    @State private var flash = false
    @State private var countdownTask: Task<Void, Never>?
    /// The framing when a drag on the picture began; nil again when it ends or is cancelled.
    @GestureState private var dragFraming: Double?
    @State private var mapShown = false
    @State private var mapHide: Task<Void, Never>?
    @State private var previewPoints = CGSize.zero
    /// A capture shown in place of the live picture.
    @State private var viewing: URL?

    enum Overlay { case settings, effects }

    private var mode: CaptureMode { camera.config.mode }

    private var previewSize: CGSize {
        let r = camera.config.ratio, long = CGFloat(popoverSize.rawValue)
        return r >= 1 ? CGSize(width: long, height: (long / r).rounded()) : CGSize(width: (long * r).rounded(), height: long)
    }

    private var feedMessage: String? {
        switch camera.feed {
        case .live, .off: return nil
        case .waiting: return "Waiting for \(camera.deviceName)…"
        case .black: return "Picture is black\nIs \(camera.deviceName) on?"
        case .suspended: return "Lid closed\nPick another camera"
        case .noCamera: return "No camera"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            preview
            AspectPicker(config: $camera.config)
                .disabled(camera.isRecording || viewing != nil)
            modePicker
            shutterRow
            if !library.items.isEmpty { strip }
        }
        .padding(14)
        .frame(width: inWindow ? nil : max(previewSize.width, 300) + 28)
        .frame(maxWidth: inWindow ? .infinity : nil, maxHeight: inWindow ? .infinity : nil)
        .background { if !inWindow { sizeShortcuts } }
        .animation(.easeInOut(duration: 0.25), value: camera.config.ratio)
        .animation(.easeInOut(duration: 0.25), value: popoverSize)
        // Closing the popover stops the camera; a countdown must not fire into a stopped camera.
        .onDisappear { cancelCountdown() }
        .onChange(of: shownRingLight, initial: true) { RingLight.show(shownRingLight, on: ringLightScreens) }
        .onChange(of: ringLightDisplays) { RingLight.show(shownRingLight, on: ringLightScreens) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            RingLight.show(shownRingLight, on: ringLightScreens)
        }
    }

    private var shownRingLight: RingLight.Level { camera.feed == .off ? .off : ringLight }

    private var ringLightScreens: [NSScreen] { RingLight.screens(chosen: ringLightDisplays) }

    /// ⌘+ and ⌘− step the popover's size.
    private var sizeShortcuts: some View {
        let sizes = PopoverSize.allCases, i = sizes.firstIndex(of: popoverSize)!
        return ZStack {
            Button("Larger") { popoverSize = sizes[min(i + 1, sizes.count - 1)] }.keyboardShortcut("=", modifiers: .command)
            Button("Smaller") { popoverSize = sizes[max(i - 1, 0)] }.keyboardShortcut("-", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            PreviewView(layer: camera.displayLayer)
            if camera.config.grid && camera.feed == .live && viewing == nil { ThirdsGrid() }
            if camera.access == .denied {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash.fill").font(.title)
                    Text("Camera needs access to your camera.").font(.callout)
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                    }
                }
                .foregroundStyle(.white)
            }
            if camera.access == .granted, let message = feedMessage {
                VStack(spacing: 8) {
                    if camera.feed == .waiting { ProgressView().controlSize(.small) }
                    let lines = message.split(separator: "\n", maxSplits: 1)
                    Text(lines[0]).font(.callout)
                    if lines.count > 1 { Text(lines[1]).font(.caption).foregroundStyle(.white.opacity(0.6)) }
                }
                .padding(12)
                .foregroundStyle(.white.opacity(0.9))
            }
            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
                    .transition(.scale.combined(with: .opacity))
                    .id(countdown)
            }
            Color.white.opacity(flash ? 1 : 0).allowsHitTesting(false)
            if let viewing {
                CaptureViewer(url: viewing, library: library, close: { self.viewing = nil }, step: step)
            } else {
                previewOverlays
            }
            if mapShown, let (source, crop) = reframable {
                FrameMap(source: source, crop: crop)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 46)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .background(GeometryReader { g in Color.clear.onAppear { previewPoints = g.size }.onChange(of: g.size) { previewPoints = g.size } })
        .gesture(reframe, including: reframable == nil ? .subviews : .all)
        .gesture(TapGesture(count: 2).onEnded { camera.config.framing = 0; showMap(for: 0.9) }, including: reframable == nil ? .subviews : .all)
        .help(reframable == nil ? "" : "Drag to reframe · double-click to centre")
        .onChange(of: camera.config.ratio) { if reframable != nil { showMap(for: 1.2) } }
        .onChange(of: dragFraming == nil) { _, ended in if ended { showMap(for: 0.9) } }
        .frame(width: inWindow ? nil : previewSize.width, height: inWindow ? nil : previewSize.height)
        .aspectRatio(inWindow ? camera.config.ratio : nil, contentMode: .fit)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: inWindow ? .infinity : nil, maxHeight: inWindow ? .infinity : nil)
    }

    private var previewOverlays: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                if let since = camera.recordingSince {
                    Spacer()
                    RecordingBadge(since: since)
                    Spacer()
                } else {
                    CameraMenu(camera: camera)
                    Spacer(minLength: 8)
                    Button { toggle(.settings) } label: {
                        Text(mode == .video ? "\(camera.config.resolution.badge) · \(camera.mode.rate.rawValue)" : camera.config.resolution.badge)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .overlayChip()
                    }
                    .buttonStyle(.plain)
                    .help("Camera Settings")
                }
            }
            if overlay == .settings {
                SettingsPanel(camera: camera, close: { overlay = nil })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if let error = camera.errorMessage {
                Text(error)
                    .font(.caption)
                    .padding(6)
                    .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
            }
            if overlay == .effects {
                EffectsTray(config: $camera.config, ringLight: $ringLight, ringLightDisplays: $ringLightDisplays)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack {
                TurnButton(camera: camera).disabled(camera.isRecording)
                Spacer()
                Button { toggle(.effects) } label: {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(effectsOn ? Color.black : Color.white)
                        .frame(width: 28, height: 28)
                        .background(effectsOn ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.black.opacity(0.45)), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Effects: portrait blur, brighten, ring light")
            }
        }
        .padding(8)
        .animation(.easeOut(duration: 0.2), value: overlay)
    }

    /// The camera's upright picture and the part of it the crop keeps, when the crop leaves some of it out.
    private var reframable: (source: CGSize, crop: CGRect)? {
        let source = camera.mode.source
        guard viewing == nil, camera.feed == .live, source.width > 0, source.height > 0 else { return nil }
        let crop = Config.crop(CGRect(origin: .zero, size: source), ratio: camera.config.ratio, framing: camera.config.framing)
        return crop.width < source.width * 0.99 || crop.height < source.height * 0.99 ? (source, crop) : nil
    }

    /// Dragging the picture slides the crop over the camera's whole picture, following the hand.
    private var reframe: some Gesture {
        DragGesture()
            .updating($dragFraming) { drag, dragFraming, _ in
                guard let (source, crop) = reframable else { return }
                let start = dragFraming ?? camera.config.framing
                dragFraming = start
                let horizontal = crop.width < source.width
                let room = horizontal ? previewPoints.width * (source.width / crop.width - 1)
                                      : previewPoints.height * (source.height / crop.height - 1)
                guard room > 0 else { return }
                let moved = horizontal ? drag.translation.width : drag.translation.height
                camera.config.framing = min(max(start - 2 * moved / room, -1), 1)
                mapHide?.cancel()
                withAnimation(.easeOut(duration: 0.15)) { mapShown = true }
            }
    }

    private func showMap(for seconds: Double) {
        mapHide?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { mapShown = true }
        mapHide = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { mapShown = false }
        }
    }

    private var effectsOn: Bool { camera.config.blur != .off || camera.config.brighten != .off || ringLight != .off }

    private func toggle(_ shown: Overlay) { overlay = overlay == shown ? nil : shown }

    // MARK: Controls

    private var modePicker: some View {
        HStack(spacing: 22) {
            ForEach(CaptureMode.allCases, id: \.self) { m in
                Button { camera.config.mode = m } label: {
                    Text(m.rawValue.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(m == mode ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(camera.isRecording || countdown != nil)
    }

    /// The same width at any window size, so the controls stay beside the shutter.
    private var shutterRow: some View {
        HStack(spacing: 20) {
            HStack(spacing: 10) {
                timerButton
                if mode == .video { mic }
            }
            .frame(width: 90, alignment: .leading)
            ShutterButton(mode: mode, recording: camera.isRecording, returnsToCamera: viewing != nil, counting: countdown != nil, action: shutter)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(camera.access != .granted)
            Button { NSWorkspace.shared.open(Library.folder) } label: {
                Image(systemName: "folder")
            }
            .help("Open the Camera folder in Finder")
            .frame(width: 90, alignment: .trailing)
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
    }

    private var timerButton: some View {
        Button { timerOn.toggle() } label: {
            Image(systemName: "timer")
                .foregroundStyle(timerOn ? Color.yellow : Color.secondary)
                .overlay(alignment: .bottomTrailing) {
                    if timerOn { Text("\(timerSeconds)").font(.system(size: 8, weight: .bold)).foregroundStyle(.yellow).offset(x: 5, y: 3) }
                }
        }
        .help(timerOn ? "\(timerSeconds)-second timer · right-click for others" : "No timer · right-click for 3 or 10 seconds")
        .contextMenu {
            Picker("Timer", selection: Binding(get: { timerSeconds }, set: { timerSeconds = $0; timerOn = true })) {
                Text("3 Seconds").tag(3)
                Text("10 Seconds").tag(10)
            }
            .pickerStyle(.inline)
        }
        .disabled(camera.isRecording)
    }

    private var mic: some View {
        let systemDefault = AVCaptureDevice.default(for: .audio)?.localizedName
        let chosen = camera.mics.first { $0.uniqueID == camera.config.micID }?.localizedName ?? systemDefault ?? "the default microphone"
        return HStack(spacing: 3) {
            Button { camera.config.micOn.toggle() } label: {
                Image(systemName: camera.config.micOn ? "mic.fill" : "mic.slash")
                    .foregroundStyle(camera.config.micOn ? Color.yellow : Color.secondary)
            }
            .help(camera.config.micOn ? "Recording sound from \(chosen) · click to mute, right-click to pick a microphone"
                                      : "Muted · click to record sound, right-click to pick a microphone")
            .contextMenu {
                Picker("Microphone", selection: Binding(get: { camera.config.micID }, set: { camera.config.micID = $0; camera.config.micOn = true })) {
                    Text(systemDefault.map { "System Default (\($0))" } ?? "System Default").tag(String?.none)
                    ForEach(camera.mics, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                .pickerStyle(.inline)
            }
            if camera.config.micOn { LevelMeter(level: camera.micLevel) }
        }
        .disabled(camera.isRecording)
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(library.items, id: \.self) { url in
                    Thumbnail(url: url)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.yellow, lineWidth: viewing == url ? 2 : 0))
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                        .onTapGesture { viewing = url; overlay = nil }
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        .contextMenu {
                            ShareLink("Share…", item: url)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.writeObjects([url as NSURL])
                            }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Divider()
                            Button("Move to Trash") { library.trash(url) }
                        }
                }
            }
        }
        .frame(height: 48)
    }

    // MARK: Actions

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        withAnimation { countdown = nil }
    }

    /// The strip is newest first.
    private func step(_ by: Int) {
        guard let viewing, let i = library.items.firstIndex(of: viewing) else { return }
        let j = i + by
        if library.items.indices.contains(j) { self.viewing = library.items[j] }
    }

    private func shutter() {
        overlay = nil
        if countdown != nil {
            cancelCountdown()
            return
        }
        if viewing != nil {
            viewing = nil
            return
        }
        if mode == .video && camera.isRecording {
            camera.stopRecording { _ in library.reload() }
            return
        }
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            if timerOn {
                for n in stride(from: timerSeconds, through: 1, by: -1) {
                    withAnimation(.spring(duration: 0.3)) { countdown = n }
                    try? await Task.sleep(for: .seconds(1))
                    // A cancel can land after the sleep ends but before this resumes.
                    guard !Task.isCancelled else { return }
                }
                withAnimation { countdown = nil }
            }
            if mode == .photo {
                flash = true
                withAnimation(.easeOut(duration: 0.45)) { flash = false }
                NSSound(named: "Tink")?.play()
                camera.takePhoto { _ in library.reload() }
            } else {
                camera.startRecording()
            }
        }
    }
}
