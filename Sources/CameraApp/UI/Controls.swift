import AVFoundation
import SwiftUI

/// The kind of camera as an icon on the preview; click it for the cameras by name.
struct CameraMenu: View {
    @ObservedObject var camera: Camera

    static func symbol(_ device: AVCaptureDevice?) -> String {
        switch device?.deviceType {
        case .continuityCamera?: return "iphone"
        case .builtInWideAngleCamera?: return "laptopcomputer"
        case nil: return "video.slash.fill"
        default: return "camera.fill"
        }
    }

    static func name(_ device: AVCaptureDevice) -> String {
        device.isSuspended ? "\(device.localizedName) (off: lid closed)" : device.localizedName
    }

    var body: some View {
        let current = camera.devices.first { $0.uniqueID == camera.config.deviceID }
        Menu {
            Picker("Camera", selection: Binding(get: { camera.config.deviceID }, set: { Self.choose($0, for: camera) })) {
                ForEach(camera.devices, id: \.uniqueID) { device in
                    Label(Self.name(device), systemImage: Self.symbol(device)).tag(Optional(device.uniqueID))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: Self.symbol(current))
                .font(.caption.weight(.semibold))
                .overlayChip()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(camera.isRecording)
        .help(current?.localizedName ?? "No camera")
    }

    /// Picking the camera in the corner as the main one swaps the two, in one change.
    static func choose(_ id: String?, for camera: Camera) {
        var config = camera.config
        if id != nil && id == config.secondDeviceID { config.secondDeviceID = config.deviceID }
        config.deviceID = id
        camera.config = config
    }
}

/// A second camera in the picture's corner. A click turns the corner on or off, a right-click
/// picks its camera, and both are remembered.
struct CornerButton: View {
    @ObservedObject var camera: Camera

    var body: some View {
        let main = camera.config.deviceID
        let others = camera.devices.filter { $0.uniqueID != main }
        let chosen = others.first { $0.uniqueID == camera.config.secondDeviceID }
        let on = camera.config.secondOn && chosen != nil
        Button(action: toggle) {
            Image(systemName: on ? "pip.fill" : "pip")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(width: 28, height: 28)
                .background(on ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.black.opacity(0.45)), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(others.isEmpty)
        .help(others.isEmpty ? "Connect another camera to show it in the corner"
              : on ? "\(chosen!.localizedName) in the corner · click to hide, right-click to pick a camera"
              : "Show a second camera in the corner · right-click to pick one")
        .contextMenu {
            Picker("In the Corner", selection: Binding(get: { on ? camera.config.secondDeviceID : nil }, set: pick)) {
                ForEach(others, id: \.uniqueID) { device in
                    Label(CameraMenu.name(device), systemImage: CameraMenu.symbol(device)).tag(Optional(device.uniqueID))
                }
            }
            .pickerStyle(.inline)
            if on { Button("Swap Cameras") { CameraMenu.choose(chosen!.uniqueID, for: camera) } }
        }
    }

    /// Turning it on with no camera remembered, or one that is gone, uses the first other one that is on.
    private func toggle() {
        var config = camera.config
        let others = camera.devices.filter { $0.uniqueID != config.deviceID }
        if !config.secondOn, !others.contains(where: { $0.uniqueID == config.secondDeviceID }) {
            config.secondDeviceID = (others.first { !$0.isSuspended } ?? others.first)?.uniqueID
        }
        config.secondOn.toggle()
        camera.config = config
    }

    private func pick(_ id: String?) {
        var config = camera.config
        config.secondDeviceID = id
        config.secondOn = id != nil
        camera.config = config
    }
}

/// 9:16, 4:5, 3:4, 1:1, and the button that turns the frame on its side.
struct AspectPicker: View {
    @Binding var config: Config

    var body: some View {
        let landscape = config.landscape, square = config.aspect.isSquare
        HStack(spacing: 4) {
            ForEach(Aspect.allCases) { aspect in
                Button { config.aspect = aspect } label: {
                    Text(aspect.label(landscape: landscape))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(aspect == config.aspect ? Color.black : Color.secondary)
                        .background(aspect == config.aspect ? Color.white.opacity(0.9) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Button { if !square { config.landscape.toggle() } } label: {
                Image(systemName: landscape ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate")
                    .foregroundStyle(square ? Color.secondary.opacity(0.5) : Color.secondary)
                    .padding(.leading, 6)
            }
            .buttonStyle(.borderless)
            .imageScale(.large)
            .keyboardShortcut("r", modifiers: [])
            .help(square ? "A square has no orientation" : "Turn the frame to \(landscape ? "portrait" : "landscape") · R")
        }
    }
}

/// Stands the picture of a camera mounted sideways or upside down upright. Set on its own from the
/// first faces a camera sees; a click turns it a further 90°, a right-click picks one.
struct TurnButton: View {
    @ObservedObject var camera: Camera

    var body: some View {
        let turn = camera.rotation
        Button { camera.rotation = turn + 90 } label: {
            Image(systemName: "rotate.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(turn != 0 ? Color.black : Color.white)
                .frame(width: 28, height: 28)
                .background(turn != 0 ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.black.opacity(0.45)), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Turn the picture 90° clockwise, for a camera mounted on its side" + (turn != 0 ? " · now turned \(turn)°" : ""))
        .contextMenu {
            Picker("Camera Mounted", selection: Binding(get: { camera.rotation }, set: { camera.rotation = $0 })) {
                ForEach([0, 90, 180, 270], id: \.self) { Text($0 == 0 ? "Upright" : "Turn Picture \($0)° Clockwise").tag($0) }
            }
            .pickerStyle(.inline)
        }
    }
}

/// Opened from the format badge: the settings that change the file rather than the picture.
struct SettingsPanel: View {
    @ObservedObject var camera: Camera
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Camera Settings").font(.headline)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(.bottom, 6)
            row("Resolution", note: upscaled ? "Above \(camera.mode.nativeShort)p this camera's picture is upscaled." : nil) {
                Picker("Resolution", selection: $camera.config.resolution) {
                    ForEach(Resolution.allCases) { Text($0.label).tag($0) }
                }
            }
            if camera.config.mode == .video {
                Divider()
                row("Frame rate") {
                    Picker("Frame rate", selection: Binding(get: { camera.mode.rate }, set: { camera.config.frameRate = $0 })) {
                        ForEach(FrameRate.allCases.filter(camera.mode.supportedRates.contains)) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            Divider()
            toggle("Mirror", note: "Flip like a selfie camera.", isOn: $camera.config.mirrored)
            Divider()
            toggle("Grid", note: "Thirds on the preview. Never in photos or videos.", isOn: $camera.config.grid)
            Divider()
            toggle("Location", note: camera.config.saveLocation && camera.locator.denied
                   ? "Off in System Settings → Privacy & Security → Location Services."
                   : "Adds where photos and videos were taken.", isOn: $camera.config.saveLocation)
            Button { NSApp.terminate(nil) } label: {
                HStack {
                    Text("Quit Camera")
                    Spacer()
                    Text("⌘Q").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .controlSize(.small)
        .font(.callout)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .disabled(camera.isRecording)
    }

    private var upscaled: Bool { camera.mode.nativeShort > 0 && camera.config.resolution.rawValue > camera.mode.nativeShort }

    private func row(_ title: String, note: String? = nil, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title, note: note)
            control().pickerStyle(.segmented).labelsHidden()
        }
        .padding(.vertical, 7)
    }

    private func toggle(_ title: String, note: String, isOn: Binding<Bool>) -> some View {
        HStack {
            label(title, note: note)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.vertical, 7)
    }

    private func label(_ title: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).fixedSize()
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Over the bottom of the picture, so each change shows as it is made.
struct EffectsTray: View {
    @Binding var config: Config
    @Binding var ringLight: RingLight.Level
    @Binding var ringLightDisplays: String

    var body: some View {
        VStack(spacing: 8) {
            row("Portrait blur", icon: "camera.aperture", selection: $config.blur)
            row("Brighten", icon: "sun.max", selection: $config.brighten)
            row("Ring light", icon: "display", selection: $ringLight)
                .help(NSScreen.screens.count > 1 ? "Light your face from the edges of the screen · right-click to pick displays"
                                                 : "Light your face from the edges of the screen")
                .contextMenu {
                    if NSScreen.screens.count > 1 {
                        Section("Displays") {
                            ForEach(NSScreen.screens, id: \.displayID) { Toggle($0.localizedName, isOn: displayBinding($0)) }
                        }
                    }
                }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row<Level: CaseIterable & Hashable & RawRepresentable<String>>(
        _ title: String, icon: String, selection: Binding<Level>
    ) -> some View where Level.AllCases: RandomAccessCollection {
        HStack {
            Label(title, systemImage: icon).font(.callout).fixedSize()
            Spacer(minLength: 8)
            Picker(title, selection: selection) {
                ForEach(Level.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 150)
        }
    }

    private var chosenDisplays: Set<String> { Set(RingLight.screens(chosen: ringLightDisplays).map(\.displayID)) }

    private func displayBinding(_ screen: NSScreen) -> Binding<Bool> {
        Binding(
            get: { chosenDisplays.contains(screen.displayID) },
            set: { on in
                var chosen = chosenDisplays
                if on { chosen.insert(screen.displayID) } else { chosen.remove(screen.displayID) }
                // Unchecking the last display turns the light off rather than back to the main one.
                guard !chosen.isEmpty else { ringLight = .off; return }
                ringLightDisplays = chosen.sorted().joined(separator: ",")
                if ringLight == .off { ringLight = .soft }
            })
    }
}
