import AVFoundation
import SwiftUI

struct ShutterButton: View {
    let mode: CaptureMode
    let recording: Bool
    /// While a capture is shown, the shutter only brings the live picture back.
    let returnsToCamera: Bool
    /// During a timer's countdown the shutter cancels it.
    var counting = false
    let action: () -> Void

    var body: some View {
        let stops = recording || counting
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.primary.opacity(0.8), lineWidth: 3).frame(width: 56, height: 56)
                RoundedRectangle(cornerRadius: stops ? 5 : 23)
                    .fill(returnsToCamera ? Color.gray.opacity(0.5) : mode == .photo ? Color.white : Color.red)
                    .frame(width: stops ? 22 : 46, height: stops ? 22 : 46)
                    .shadow(color: .black.opacity(0.2), radius: 1)
            }
            .contentShape(Circle())
            .animation(.spring(duration: 0.25), value: stops)
        }
        .buttonStyle(.plain)
        .help(returnsToCamera ? "Back to the camera (Space)" : counting ? "Cancel the timer (Space)"
              : mode == .photo ? "Take photo (Space)" : recording ? "Stop recording (Space)" : "Start recording (Space)")
    }
}

extension View {
    /// The dark capsule that labels and buttons on the picture sit in.
    func overlayChip() -> some View {
        padding(.horizontal, 9).padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
            .foregroundStyle(.white)
            .contentShape(Capsule())
    }
}

struct LevelMeter: View {
    @ObservedObject var level: MicLevel
    var body: some View {
        let value = CGFloat(level.value)
        Capsule()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: 4, height: 18)
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(value > 0.85 ? Color.yellow : Color.green)
                    .frame(width: 4, height: max(2, 18 * value))
                    .animation(.linear(duration: 0.08), value: value)
            }
            .help("Microphone level")
    }
}

struct RecordingBadge: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let s = max(0, Int(context.date.timeIntervalSince(since)))
            HStack(spacing: 5) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(String(format: "%02d:%02d", s / 60, s % 60)).font(.caption.monospacedDigit().weight(.semibold))
            }
            .overlayChip()
        }
    }
}

struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            if url.pathExtension.lowercased() == "mp4" {
                Image(systemName: "video.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .padding(4)
                    .shadow(radius: 2)
            }
        }
        .help(url.lastPathComponent)
        .task(id: url) { image = await Library.thumbnail(for: url, size: 96) }
    }
}

struct PreviewView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> LayerHost {
        let view = LayerHost(picture: layer)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ nsView: LayerHost, context: Context) {}

    /// The popover and the window each have a preview but share one picture layer: whichever is shown holds it.
    final class LayerHost: NSView {
        let picture: CALayer
        init(picture: CALayer) { self.picture = picture; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, picture.superlayer !== layer else { return }
            layer?.addSublayer(picture)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.sublayers?.forEach { $0.frame = bounds }
            CATransaction.commit()
        }
    }
}

/// Where the crop sits on the camera's whole picture, shown while it is dragged.
struct FrameMap: View {
    let source: CGSize
    /// In Core Image space, where y grows upward.
    let crop: CGRect

    var body: some View {
        let scale = 92 / max(source.width, source.height)
        let window = CGRect(x: crop.minX * scale, y: (source.height - crop.maxY) * scale,
                            width: crop.width * scale, height: crop.height * scale)
        RoundedRectangle(cornerRadius: 5)
            .fill(.black.opacity(0.45))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.5), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.yellow.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.yellow, lineWidth: 1.5))
                    .frame(width: window.width, height: window.height)
                    .offset(x: window.minX, y: window.minY)
            }
            .frame(width: source.width * scale, height: source.height * scale)
    }
}

/// Rule-of-thirds lines over the preview.
struct ThirdsGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3, y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.black.opacity(0.25)), lineWidth: 2)
            context.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
