import AVFoundation

/// A frame shape in its portrait form; `Config.landscape` turns 9:16 into 16:9.
enum Aspect: String, CaseIterable, Identifiable, Codable {
    case r9x16 = "9:16", r4x5 = "4:5", r3x4 = "3:4", r1x1 = "1:1"
    var id: String { rawValue }
    private var parts: (short: Int, long: Int) {
        let p = rawValue.split(separator: ":").compactMap { Int($0) }
        return (p[0], p[1])
    }
    var isSquare: Bool { self == .r1x1 }
    func label(landscape: Bool) -> String { landscape ? "\(parts.long):\(parts.short)" : rawValue }
    /// Width over height.
    func ratio(landscape: Bool) -> CGFloat {
        landscape ? CGFloat(parts.long) / CGFloat(parts.short) : CGFloat(parts.short) / CGFloat(parts.long)
    }

    static func parse(_ text: String) -> (Aspect, landscape: Bool)? {
        for aspect in allCases {
            if text == aspect.label(landscape: false) { return (aspect, false) }
            if text == aspect.label(landscape: true) { return (aspect, true) }
        }
        return nil
    }
}

enum CaptureMode: String, CaseIterable, Codable { case photo, video }

enum Resolution: Int, CaseIterable, Identifiable, Codable {
    case p720 = 720, p1080 = 1080, p1440 = 1440, p2160 = 2160
    var id: Int { rawValue }
    var label: String { self == .p2160 ? "4K" : "\(rawValue)p" }
    /// The short name on the preview's badge, as Apple's Camera writes it.
    var badge: String { self == .p1080 ? "HD" : label }
}

/// Background blur, with the person kept sharp.
enum Blur: String, CaseIterable, Identifiable, Codable {
    case off, soft, strong
    var id: Self { self }
    /// Radius in pixels at 1080p; larger outputs scale it.
    var radius: Double { [Self.off: 0, .soft: 10, .strong: 28][self]! }
}

enum Brighten: String, CaseIterable, Identifiable, Codable {
    case off, more, most
    var id: Self { self }
    /// Stops of exposure added.
    var stops: Double { [Self.off: 0, .more: 0.75, .most: 1.5][self]! }
}

enum FrameRate: String, CaseIterable, Identifiable, Codable {
    case f23_98 = "23.98", f24 = "24", f30 = "30", f60 = "60"
    var id: String { rawValue }
    var value: Double { self == .f23_98 ? 24_000.0 / 1001 : Double(rawValue)! }
    var frameDuration: CMTime { self == .f23_98 ? CMTime(value: 1001, timescale: 24_000) : CMTime(value: 1, timescale: CMTimeScale(value)) }

    func fits(_ range: AVFrameRateRange) -> Bool {
        range.minFrameRate <= value + 0.01 && range.maxFrameRate >= value - 0.01
    }
}

/// Everything the person chose, applied in one place: `Camera.apply`.
struct Config: Equatable, Codable {
    var deviceID: String?
    var aspect: Aspect = .r9x16
    var landscape = false
    var resolution: Resolution = .p1080
    var frameRate: FrameRate = .f30
    /// The picture is mirrored before it is turned, and a mirror reverses a turn, so turns flip with it.
    var mirrored = true { didSet { if mirrored != oldValue { rotations = rotations.mapValues { (360 - $0) % 360 } } } }
    var mode: CaptureMode = .photo
    var micOn = true
    /// The microphone to record from; nil is the system's default input.
    var micID: String?
    /// Clockwise turn per camera, keyed by `Camera.mountKey` so another USB port keeps it.
    /// A camera with no entry yet is turned upright from the faces it sees.
    var rotations: [String: Int] = [:]
    var blur: Blur = .off
    var brighten: Brighten = .off
    /// Writes where a capture was taken into the file. Off by default: files get shared.
    var saveLocation = false
    /// Rule-of-thirds lines over the preview; never in a saved file.
    var grid = false
    /// Where the crop sits along the side of the picture it doesn't fill: -1 is the left or top, 1 the right or bottom.
    var framing = 0.0

    /// Only a video records sound, so a photo never opens the microphone.
    var recordsSound: Bool { mode == .video && micOn }
    var aspectLabel: String { aspect.label(landscape: landscape) }
    var ratio: CGFloat { aspect.ratio(landscape: landscape) }

    /// Output size with the chosen resolution on the short side, both sides even for the encoder.
    var outputSize: CGSize {
        let short = resolution.rawValue
        let long = Int((CGFloat(short) * max(ratio, 1 / ratio) / 2).rounded()) * 2
        return ratio >= 1 ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
    }

    /// Short side of the largest region of a `width`×`height` frame this shape can be cut from.
    func nativeShort(width: Int, height: Int) -> Int {
        let w = CGFloat(width), h = CGFloat(height)
        let crop = w / h > ratio ? CGSize(width: h * ratio, height: h) : CGSize(width: w, height: w / ratio)
        return Int(min(crop.width, crop.height))
    }

    /// The region of an upright `extent` an output of `ratio` is cut from, slid along the spare side by `framing`.
    /// `extent` is in Core Image space, where y grows upward.
    static func crop(_ extent: CGRect, ratio: CGFloat, framing: Double) -> CGRect {
        let along = CGFloat(min(max(framing, -1), 1) + 1) / 2
        var crop = extent
        if extent.width / extent.height > ratio {
            crop.size.width = extent.height * ratio
            crop.origin.x = extent.minX + (extent.width - crop.width) * along
        } else {
            crop.size.height = extent.width / ratio
            crop.origin.y = extent.minY + (extent.height - crop.height) * (1 - along)
        }
        return crop
    }

    init() {}

    /// Decodes field by field so a config from an older build keeps what it can.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        if let v = try? c.decodeIfPresent(Aspect.self, forKey: .aspect) { aspect = v }
        if let wide = try? c.decodeIfPresent(Bool.self, forKey: .landscape) { landscape = wide }
        if let v = try? c.decodeIfPresent(Resolution.self, forKey: .resolution) { resolution = v }
        if let v = try? c.decodeIfPresent(FrameRate.self, forKey: .frameRate) { frameRate = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .mirrored) { mirrored = v }
        if let v = try? c.decodeIfPresent(CaptureMode.self, forKey: .mode) { mode = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .micOn) { micOn = v }
        micID = try? c.decodeIfPresent(String.self, forKey: .micID)
        if let v = try? c.decodeIfPresent([String: Int].self, forKey: .rotations) { rotations = v }
        if let v = try? c.decodeIfPresent(Blur.self, forKey: .blur) { blur = v }
        if let v = try? c.decodeIfPresent(Brighten.self, forKey: .brighten) { brighten = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .saveLocation) { saveLocation = v }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .grid) { grid = v }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .framing) { framing = v }
    }

    static func load() -> Config {
        UserDefaults.standard.data(forKey: "config").flatMap { try? JSONDecoder().decode(Config.self, from: $0) } ?? Config()
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "config") }
    }
}
