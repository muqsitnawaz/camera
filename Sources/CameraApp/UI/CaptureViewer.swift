import AVKit
import SwiftUI

/// A photo or video shown in place of the live picture, laid out like Photos.
struct CaptureViewer: View {
    let url: URL
    let close: () -> Void
    let step: (Int) -> Void
    let trash: () -> Void
    @State private var player: AVPlayer?
    @State private var image: NSImage?

    private var isVideo: Bool { url.pathExtension.lowercased() == "mp4" }

    var body: some View {
        ZStack {
            Color.black
            if isVideo, let player {
                PlayerView(player: player)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    .help("Double-click to open in Preview")
            }
            VStack {
                topBar
                Spacer()
            }
            .padding(8)
            HStack {
                arrow("chevron.left", help: "Newer (←)", key: .leftArrow) { step(-1) }
                Spacer()
                arrow("chevron.right", help: "Older (→)", key: .rightArrow) { step(1) }
            }
            .padding(.horizontal, 8)
        }
        .task(id: url) {
            player?.pause()
            if isVideo {
                let p = AVPlayer(url: url)
                player = p
                image = nil
                p.play()
            } else {
                player = nil
                image = NSImage(contentsOf: url)
            }
        }
        .onDisappear { player?.pause() }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button(action: close) {
                Label("Camera", systemImage: "chevron.left").font(.caption.weight(.semibold)).overlayChip()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Back to the camera (Esc)")
            Spacer()
            VStack(spacing: 1) {
                Text(Self.day.string(from: taken)).font(.caption.weight(.semibold))
                Text(taken.formatted(date: .omitted, time: .shortened) + (isVideo ? " · Video" : "")).font(.caption2)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 3)
            Spacer()
            HStack(spacing: 6) {
                ShareLink(item: url) { circle("square.and.arrow.up") }
                    .buttonStyle(.plain)
                    .help("Share")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { circle("folder") }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                Button(action: trash) { circle("trash") }
                .buttonStyle(.plain)
                .help("Move to Trash")
            }
        }
    }

    private var taken: Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now }

    /// "Today", "Yesterday", or the date.
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.doesRelativeDateFormatting = true
        return f
    }()

    private func circle(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(.black.opacity(0.45), in: Circle())
            .contentShape(Circle())
    }

    private func arrow(_ icon: String, help: String, key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) { circle(icon) }
            .buttonStyle(.plain)
            .keyboardShortcut(key, modifiers: [])
            .help(help)
    }
}

/// SwiftUI's `VideoPlayer` aborts unless AVKit is linked, so this hosts `AVPlayerView` directly.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
