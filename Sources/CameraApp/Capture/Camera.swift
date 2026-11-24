import AVFoundation
import AppKit
import Combine
import CoreImage
import CoreLocation
import UniformTypeIdentifiers
import Vision

struct CameraMode: Equatable {
    var supportedRates: Set<FrameRate> = []
    /// The rate in use: the chosen one, or the nearest the camera has.
    var rate: FrameRate = .f30
    /// Real camera pixels on the short side behind the current aspect; larger outputs are upscaled.
    var nativeShort = 0
    /// The camera's picture once turned upright, before the crop.
    var source = CGSize.zero
}

/// The capture session and the one render path whose buffer feeds the preview, recordings and photos.
final class Camera: NSObject, ObservableObject {
    enum Access { case unknown, granted, denied }
    enum Feed: Equatable { case off, waiting, live, black, suspended, noCamera }

    @Published var config: Config { didSet { configChanged(from: oldValue) } }
    @Published private(set) var mode = CameraMode()
    @Published private(set) var access: Access = .unknown
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var mics: [AVCaptureDevice] = []
    @Published private(set) var feed: Feed = .off
    @Published private(set) var recordingSince: Date?
    @Published private(set) var errorMessage: String?

    let displayLayer = AVSampleBufferDisplayLayer()
    /// The microphone's loudness, kept apart from `Camera` so only the meter redraws with it.
    let micLevel = MicLevel()
    let locator = Locator()
    private var locatorChanges: AnyCancellable?
    /// Off for scripted captures; fixed at init because init can already switch cameras and save.
    let persists: Bool
    var isRecording: Bool { recordingSince != nil }
    var deviceName: String { devices.first { $0.uniqueID == config.deviceID }?.localizedName ?? "the camera" }

    /// A camera's `uniqueID` can change with the USB port (Cam Link 4K), its model and name don't.
    static func mountKey(_ device: AVCaptureDevice) -> String { "\(device.modelID) \(device.localizedName)" }
    private var mountKey: String? { devices.first { $0.uniqueID == config.deviceID }.map(Self.mountKey) }
    /// The current camera's clockwise turn, for one mounted sideways or upside down.
    var rotation: Int {
        get { mountKey.flatMap { config.rotations[$0] } ?? 0 }
        set { if let mountKey { config.rotations[mountKey] = ((newValue % 360) + 360) % 360 } }
    }

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    /// The second camera runs in its own session, so it can never stall or pause the main picture.
    private let insetSession = AVCaptureSession()
    private let insetOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    /// Session inputs and the camera's format are only touched on this queue.
    private let sessionQueue = DispatchQueue(label: "camera.session")
    /// Frames, audio samples, the render settings and the recorder are only touched on this queue.
    private let frameQueue = DispatchQueue(label: "camera.frames", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // Session queue state.
    private var appliedMode: (device: AVCaptureDevice, format: AVCaptureDevice.Format, duration: CMTime)?
    private var appliedInset: (device: AVCaptureDevice, format: AVCaptureDevice.Format, duration: CMTime)?
    /// A corner camera that couldn't be opened isn't tried again on every apply, only once it is picked anew.
    private var insetRefused: AVCaptureDevice?

    // Frame queue state.
    private struct Render: Equatable {
        var deviceID: String?; var size: CGSize; var mirrored: Bool; var rotation: Int
        var framing = 0.0
        /// The camera has no saved turn yet, so frames are checked for a face on its side.
        var findsMount = false
        /// Stops of exposure added, and the background blur radius in output pixels; 0 is off.
        var exposure = 0.0, blur = 0.0
        /// The second camera drawn in the corner, and its saved turn.
        var insetID: String?
        var insetRotation = 0
    }
    private var renderState = Render(deviceID: nil, size: .zero, mirrored: true, rotation: 0)
    private let segmentation: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private let segmentationSequence = VNSequenceRequestHandler()
    private var lastLevelReport = Date.distantPast
    private var lastMask: CIImage?
    private var askedForMic = false
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private var lastFrame: CVPixelBuffer?
    /// The second camera's latest picture at its corner size; drawn only while fresh, never frozen.
    private var insetFrame: CVPixelBuffer?
    private var insetFrameAt = Date.distantPast
    private var lastInsetReport = Date.distantPast
    /// A photo with the corner on, waiting for one picture of its own from each camera.
    private struct PhotoShot {
        var main: CVPixelBuffer?, second: CVPixelBuffer?
        let finish: (CVPixelBuffer?, CVPixelBuffer?) -> Void
    }
    private var photoShot: PhotoShot?
    private var insetPool: CVPixelBufferPool?
    private var insetPoolSize: CGSize = .zero
    private var recorder: Recorder?
    private var lastReport = Date.distantPast
    private var lastMountCheck = Date.distantPast
    private var checkingMount = false
    /// Turns read from faces on the mount queue; five in a row that agree decide.
    private var mountVotes: [Int] = []
    private let mountQueue = DispatchQueue(label: "camera.mount", qos: .utility)

    // Main queue state: when the frame queue last reported a frame, and since when frames have been black.
    private var lastFrameSeen = Date.distantPast
    private var lastInsetSeen = Date.distantPast
    /// The corner camera sent a picture within the last 1.5 s.
    var cornerLive: Bool { Date().timeIntervalSince(lastInsetSeen) < 1.5 }
    /// A dark room can read black for a moment, so the picture is called black only after 3 s of it.
    private var blackSince: Date?
    private var running = false
    /// stop() was asked for during a recording; honoured when the recording ends.
    private var stopWhenDone = false
    private var healthTimer: Timer?
    private var appliedDeviceID: String?
    /// The camera the person picked, kept while a stand-in is used because it is unplugged.
    private var chosenDeviceID: String?
    private var switchingAutomatically = false
    /// A Mac's own camera is suspended while its lid is closed: connected, but sending nothing.
    private var suspensionWatches: [NSKeyValueObservation] = []

    init(persists: Bool) {
        self.persists = persists
        config = Config.load()
        super.init()
        chosenDeviceID = config.deviceID
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        audioOutput.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        insetOutput.videoSettings = videoOutput.videoSettings
        insetOutput.alwaysDiscardsLateVideoFrames = true
        insetOutput.setSampleBufferDelegate(self, queue: frameQueue)
        if insetSession.canAddOutput(insetOutput) { insetSession.addOutput(insetOutput) }

        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshDevices() }
        }
        refreshDevices()
        // Camera Settings shows whether location is allowed; it observes the camera, not the locator.
        locatorChanges = locator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Configuration

    private func configChanged(from old: Config) {
        guard config != old else { return }
        // The output size and camera are fixed for the length of a recording.
        if isRecording && (config.outputSize != old.outputSize || config.deviceID != old.deviceID || config.rotations != old.rotations
                           || config.recordsSound != old.recordsSound || config.micID != old.micID) {
            config = old  // setting a property inside its own didSet does not re-enter didSet
            return
        }
        if config.deviceID != old.deviceID && !switchingAutomatically { chosenDeviceID = config.deviceID }
        if persists {
            var saved = config
            saved.deviceID = chosenDeviceID  // a stand-in camera is never remembered as the choice
            saved.save()
        }
        apply()
    }

    private func refreshDevices() {
        devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
        mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        // Turns saved by an older build under the port-specific ID move to the stable key.
        var rotations = config.rotations
        for device in devices {
            if let turn = rotations.removeValue(forKey: device.uniqueID), rotations[Self.mountKey(device)] == nil {
                rotations[Self.mountKey(device)] = turn
            }
        }
        if rotations != config.rotations { config.rotations = rotations }
        suspensionWatches = devices.map { device in
            device.observe(\.isSuspended) { [weak self] _, _ in DispatchQueue.main.async { self?.refreshDevices() } }
        }
        // Chosen, then current, then built-in, then any; suspended cameras last; never mid-recording.
        func pick(_ cameras: [AVCaptureDevice]) -> String? {
            [chosenDeviceID, config.deviceID].compactMap { $0 }.first { id in cameras.contains { $0.uniqueID == id } }
                ?? (cameras.first { $0.deviceType == .builtInWideAngleCamera } ?? cameras.first)?.uniqueID
        }
        let target = pick(devices.filter { !$0.isSuspended }) ?? pick(devices)
        if target != config.deviceID && !isRecording {
            switchingAutomatically = true
            config.deviceID = target  // didSet applies it
            switchingAutomatically = false
            return
        }
        apply()
    }

    private func apply() {
        let config = config
        let device = devices.first { $0.uniqueID == config.deviceID }
        let inset = config.secondOn ? devices.first { $0.uniqueID == config.secondDeviceID && $0 != device && !$0.isSuspended } : nil
        let render = Render(deviceID: device?.uniqueID, size: config.outputSize, mirrored: config.mirrored, rotation: rotation,
                            framing: config.framing,
                            findsMount: persists && mountKey.map { config.rotations[$0] == nil } == true,
                            exposure: config.brighten.stops, blur: config.blur.radius * Double(config.resolution.rawValue) / 1080,
                            insetID: inset?.uniqueID, insetRotation: inset.flatMap { config.rotations[Self.mountKey($0)] } ?? 0)
        updateMic()
        updateLocation()
        if device?.uniqueID != appliedDeviceID {
            appliedDeviceID = device?.uniqueID
            lastFrameSeen = .distantPast; blackSince = nil  // the new camera is live only once its own frames arrive
            updateFeed()
        }
        frameQueue.async {
            if render.size != self.renderState.size || render.deviceID != self.renderState.deviceID || render.rotation != self.renderState.rotation {
                self.lastFrame = nil  // a photo must never be a frame from before the change
            }
            if render.deviceID != self.renderState.deviceID { self.mountQueue.async { self.mountVotes = [] } }
            if render.insetID != self.renderState.insetID { self.insetFrame = nil }
            self.renderState = render
        }
        // The corner camera's own photo is full size, so its mode is picked for the output's short side.
        let running = running, insetShort = Int(min(render.size.width, render.size.height))
        // After the main camera's change is queued, so a swap never opens one camera in both sessions.
        defer { sessionQueue.async { self.setInset(inset, rate: config.frameRate, short: insetShort, running: running) } }

        guard let device else {
            mode = CameraMode()
            feed = .noCamera
            sessionQueue.async { self.setCamera(nil) }
            return
        }

        let rates = Set(FrameRate.allCases.filter { rate in
            device.formats.contains { $0.videoSupportedFrameRateRanges.contains(where: rate.fits) }
        })
        let rate = rates.contains(config.frameRate) ? config.frameRate
            : rates.min { abs($0.value - config.frameRate.value) < abs($1.value - config.frameRate.value) }
        let sideways = rotation % 180 != 0
        func score(_ f: AVCaptureDevice.Format) -> (Int, Int) {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let w = Int(sideways ? d.height : d.width), h = Int(sideways ? d.width : d.height)
            return (config.nativeShort(width: w, height: h), -w * h)
        }
        // The mode that keeps the most real pixels once turned and cropped.
        guard let rate, let format = device.formats
            .filter({ $0.videoSupportedFrameRateRanges.contains(where: rate.fits) })
            .max(by: { score($0) < score($1) }),
              let range = format.videoSupportedFrameRateRanges.first(where: rate.fits)
        else {
            mode = CameraMode()
            return report("\(device.localizedName) offers no video mode Camera can use")
        }
        // A duration outside the range is an uncatchable exception (Cam Link 4K's 30 fps isn't exactly 1/30).
        let duration = min(max(rate.frameDuration, range.minFrameDuration), range.maxFrameDuration)
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        mode = CameraMode(supportedRates: rates, rate: rate, nativeShort: score(format).0,
                          source: sideways ? CGSize(width: Int(d.height), height: Int(d.width)) : CGSize(width: Int(d.width), height: Int(d.height)))
        sessionQueue.async {
            self.setCamera(device)
            // Only a new mode is set again: dragging the framing applies many times a second.
            guard self.appliedMode.map({ $0.device != device || $0.format != format || $0.duration != duration }) ?? true else { return }
            self.appliedMode = (device, format, duration)
            self.applyMode()
        }
    }

    /// Session queue only.
    private func setCamera(_ device: AVCaptureDevice?) {
        let cameras = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.filter { $0.device.hasMediaType(.video) }
        guard cameras.first?.device != device else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        cameras.forEach { session.removeInput($0) }
        appliedMode = nil
        guard let device else { return }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CamError.message("\(device.localizedName) is in use by another app") }
            session.addInput(input)
            report(nil)
        } catch {
            report(error.localizedDescription)
        }
    }

    /// Session queue. Runs again after every start or reconfigure, which reset the format.
    private func applyMode() {
        guard let m = appliedMode,
              session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device == m.device }) else { return }
        do {
            try m.device.lockForConfiguration()
            m.device.activeFormat = m.format
            m.device.activeVideoMinFrameDuration = m.duration
            m.device.activeVideoMaxFrameDuration = m.duration
            m.device.unlockForConfiguration()
        } catch {
            report("Couldn't set up \(m.device.localizedName): \(error.localizedDescription)")
        }
    }

    /// Session queue. The second camera's smallest mode that fills the output's short side, at the chosen rate when it has it.
    private func setInset(_ device: AVCaptureDevice?, rate: FrameRate, short: Int, running: Bool) {
        let current = insetSession.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }.first
        if device != insetRefused { insetRefused = nil }
        if current != device && (device == nil || device != insetRefused) {
            insetSession.beginConfiguration()
            insetSession.inputs.forEach { insetSession.removeInput($0) }
            appliedInset = nil
            if let device {
                if let input = try? AVCaptureDeviceInput(device: device), insetSession.canAddInput(input) {
                    insetSession.addInput(input)
                } else {
                    insetRefused = device
                    report("\(device.localizedName) is in use by another app")
                }
            }
            insetSession.commitConfiguration()
        }
        guard let device, !insetSession.inputs.isEmpty else {
            if insetSession.isRunning { insetSession.stopRunning() }
            return
        }
        func dims(_ f: AVCaptureDevice.Format) -> (short: Int, area: Int) {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return (Int(min(d.width, d.height)), Int(d.width) * Int(d.height))
        }
        let atRate = device.formats.filter { $0.videoSupportedFrameRateRanges.contains(where: rate.fits) }
        let formats = atRate.isEmpty ? device.formats : atRate
        let big = formats.filter { dims($0).short >= short }
        guard let format = big.min(by: { dims($0).area < dims($1).area }) ?? formats.max(by: { dims($0).area < dims($1).area }),
              let range = format.videoSupportedFrameRateRanges.first(where: rate.fits) ?? format.videoSupportedFrameRateRanges.first
        else { return report("\(device.localizedName) offers no video mode Camera can use") }
        let duration = min(max(rate.frameDuration, range.minFrameDuration), range.maxFrameDuration)
        if appliedInset.map({ $0.device != device || $0.format != format || $0.duration != duration }) ?? true {
            appliedInset = (device, format, duration)
            applyInsetMode()
        }
        if running && !insetSession.isRunning {
            insetSession.startRunning()
            applyInsetMode()
        }
    }

    /// Session queue. Like `applyMode`, again after every start.
    private func applyInsetMode() {
        guard let m = appliedInset, insetSession.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device == m.device }) else { return }
        do {
            try m.device.lockForConfiguration()
            m.device.activeFormat = m.format
            m.device.activeVideoMinFrameDuration = m.duration
            m.device.activeVideoMaxFrameDuration = m.duration
            m.device.unlockForConfiguration()
        } catch {
            report("Couldn't set up \(m.device.localizedName): \(error.localizedDescription)")
        }
    }

    // MARK: Session

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            access = .granted
            stopWhenDone = false
            guard !running else { return }
            running = true
            lastFrameSeen = .distantPast; blackSince = nil
            updateFeed()
            updateMic()  // before starting, so the camera doesn't pause for it once the picture is up
            updateLocation()
            sessionQueue.async {
                self.session.startRunning()
                self.applyMode()
                if !self.insetSession.inputs.isEmpty {
                    self.insetSession.startRunning()
                    self.applyInsetMode()
                }
            }
            healthTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateFeed() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    self.access = ok ? .granted : .denied
                    if ok { self.start() }
                }
            }
        default:
            access = .denied
        }
    }

    func stop() {
        guard running else { return }
        guard !isRecording else { stopWhenDone = true; return }
        running = false
        healthTimer?.invalidate()
        healthTimer = nil
        feed = .off
        updateMic()
        updateLocation()
        sessionQueue.async {
            self.session.stopRunning()
            self.insetSession.stopRunning()
        }
        frameQueue.async { self.lastFrame = nil; self.insetFrame = nil }
    }

    /// Main queue. Judged from frames that arrive: a connected camera can send nothing or black.
    private func updateFeed() {
        guard running else { return }
        let next: Feed
        if let device = devices.first(where: { $0.uniqueID == config.deviceID }) {
            next = device.isSuspended ? .suspended
                : Date().timeIntervalSince(lastFrameSeen) > 1.5 ? .waiting
                : blackSince.map { Date().timeIntervalSince($0) >= 3 } == true ? .black : .live
        } else {
            next = .noCamera
        }
        guard feed != next else { return }
        // A reason a capture couldn't start, such as no picture yet, is stale once the picture is up.
        if next == .live { errorMessage = nil }
        feed = next
    }

    /// The chosen microphone, else the system default; nil when sound is off or not allowed.
    private var wantedMic: AVCaptureDevice? {
        guard config.recordsSound, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return nil }
        return mics.first { $0.uniqueID == config.micID } ?? AVCaptureDevice.default(for: .audio)
    }

    /// Main queue. In Video the mic stays in the session while the camera runs, for the level meter.
    private func updateMic() {
        guard !isRecording else { return }
        if running, config.recordsSound, !askedForMic, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            askedForMic = true
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.updateMic() } }
        }
        let mic = running ? wantedMic : nil
        if mic == nil { micLevel.value = 0 }
        sessionQueue.async { self.setMic(mic) }
    }

    private func capturedLocation() -> CLLocation? {
        guard config.saveLocation else { return nil }
        if let location = locator.recent { return location }
        report(locator.denied ? "Saved without location: allow Camera in System Settings → Privacy & Security → Location Services"
                              : "Saved without location: no fix yet")
        return nil
    }

    private func updateLocation() {
        if running && config.saveLocation { locator.start() } else { locator.stop() }
    }

    private func report(_ message: String?) {
        DispatchQueue.main.async { self.errorMessage = message }
    }

    // MARK: Capture

    /// File name tags, e.g. `cam-link-4k 9x16 1080p 30fps`.
    private func fileTags(video: Bool, name: String? = nil) -> [String] {
        // "Alex’s iPhone Camera" → "iphone": no owner's name in shared files, no "camera" on every one.
        let camera = (name ?? deviceName)
            .replacingOccurrences(of: #"^\S+[’']s\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+camera$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let fps = mode.rate.rawValue.replacingOccurrences(of: ".", with: "_") + "fps"
        return [camera.isEmpty ? "camera" : camera,
                config.aspectLabel.replacingOccurrences(of: ":", with: "x"),
                config.resolution.label.lowercased()] + (video ? [fps] : [])
    }

    private var notReady: String? {
        switch feed {
        // A black picture is shown as a hint only: a dark room or a covered lens is still a picture.
        case .live, .black: return nil
        case .suspended: return "\(deviceName): lid closed"
        case .noCamera: return "No camera connected"
        default: return "\(deviceName): no picture yet"
        }
    }

    /// With a camera in the corner, each camera saves its own full photo: two files, the main camera's first.
    func takePhoto(completion: @escaping ([URL]) -> Void) {
        if let notReady {
            report(notReady)
            return completion([])
        }
        let main = devices.first { $0.uniqueID == config.deviceID }
        let second = config.secondOn && cornerLive ? devices.first { $0.uniqueID == config.secondDeviceID && $0 != main } : nil
        let urls = [Library.newURL(ext: "jpg", tags: fileTags(video: false))]
            + (second.map { [Library.newURL(ext: "jpg", tags: fileTags(video: false, name: $0.localizedName))] } ?? [])
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        if let location = capturedLocation() { properties[kCGImagePropertyGPSDictionary] = location.exifGPS }
        func save(_ frames: [CVPixelBuffer?]) {
            var saved: [URL] = []
            for (frame, url) in zip(frames, urls) {
                guard let frame,
                      let cg = ciContext.createCGImage(CIImage(cvPixelBuffer: frame), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame)), format: .RGBA8, colorSpace: colorSpace),
                      let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
                else { continue }
                CGImageDestinationAddImage(dest, cg, properties as CFDictionary)
                if CGImageDestinationFinalize(dest) { saved.append(url) }
            }
            if frames.first.flatMap({ $0 }) == nil { report("No picture from the camera yet") }
            else if saved.count < urls.count { report(second.map { "Saved one photo: \($0.localizedName) sent no picture" } ?? "Couldn't save the photo") }
            DispatchQueue.main.async { completion(saved) }
        }
        frameQueue.async {
            guard second != nil, self.renderState.insetID == second?.uniqueID else { return save([self.lastFrame]) }
            self.finishPhoto()  // a photo still waiting saves what it has before the next one starts
            self.photoShot = PhotoShot(finish: { save([$0, $1]) })
            // Saves what arrived if a camera sends nothing in time.
            self.frameQueue.asyncAfter(deadline: .now() + 1) { self.finishPhoto() }
        }
    }

    /// Frame queue.
    private func finishPhoto() {
        guard let shot = photoShot else { return }
        photoShot = nil
        shot.finish(shot.main, shot.second)
    }

    /// Start and stop both hop session queue then frame queue, so a stop never overtakes its start.
    func startRecording() {
        guard !isRecording else { return }
        if let notReady { return report(notReady) }
        // Ask for the microphone before recording starts, so a pending prompt never holds a Stop.
        if config.recordsSound, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.startRecording() } }
            return
        }
        let url = Library.newURL(ext: "mp4", tags: fileTags(video: true))
        let size = config.outputSize, rate = mode.rate
        let location = capturedLocation()
        let mic = wantedMic
        let audio = mic != nil
        if config.recordsSound && !audio {
            report("Recording without sound: allow Camera in System Settings → Privacy & Security → Microphone")
        }
        recordingSince = Date()
        sessionQueue.async {
            // Joining pauses the camera, so it happens before the file starts.
            self.setMic(mic)
            self.frameQueue.async {
                do {
                    self.recorder = try Recorder(url: url, size: size, frameRate: rate, audio: audio, location: location)
                } catch {
                    self.report("Couldn't start recording: \(error.localizedDescription)")
                    DispatchQueue.main.async { self.recordingEnded() }
                }
            }
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard isRecording else { return completion(nil) }
        sessionQueue.async {
            var recorder: Recorder?
            self.frameQueue.sync {
                recorder = self.recorder
                self.recorder = nil
            }
            guard let recorder else {
                return DispatchQueue.main.async { self.recordingEnded(); completion(nil) }
            }
            recorder.finish { url in
                if url == nil { self.report(recorder.failure.map { "The recording couldn't be saved: \($0)" } ?? "No picture arrived from the camera") }
                DispatchQueue.main.async { self.recordingEnded(); completion(url) }
            }
        }
    }

    /// Main queue. The one place a recording ends; frozen settings and a pending stop catch up.
    private func recordingEnded() {
        recordingSince = nil
        refreshDevices()
        if stopWhenDone {
            stopWhenDone = false
            stop()
        }
    }

    /// Session queue. One session for sound and picture keeps them on one clock.
    private func setMic(_ mic: AVCaptureDevice?) {
        let inputs = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.filter { $0.device.hasMediaType(.audio) }
        guard inputs.map(\.device.uniqueID) != [mic?.uniqueID].compactMap({ $0 }) else { return }
        session.beginConfiguration()
        inputs.forEach { session.removeInput($0) }
        if let mic, let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
        applyMode()
    }
}

extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // A Continuity Camera's first frames can be minutes off the host clock.
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard abs((CMClockGetTime(CMClockGetHostTimeClock()) - time).seconds) < 1 else { return }
        if output === audioOutput {
            recorder?.append(audio: sampleBuffer)
            reportLevel(sampleBuffer)
            return
        }
        // A frame still in flight from the camera before a switch is not this camera's picture.
        let from = (connection.inputPorts.first?.input as? AVCaptureDeviceInput)?.device.uniqueID
        if output === insetOutput {
            guard from == renderState.insetID, let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            insetFrame = renderInset(source)
            if photoShot != nil && photoShot?.second == nil {
                photoShot?.second = render(source, second: true)
                if photoShot?.main != nil { finishPhoto() }
            }
            let now = Date()
            if now.timeIntervalSince(lastInsetReport) > 0.25 {
                lastInsetReport = now
                DispatchQueue.main.async { self.lastInsetSeen = now }
            }
            insetFrameAt = now
            return
        }
        guard from == renderState.deviceID, let source = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = render(source) else { return }
        lastFrame = frame
        if photoShot != nil && photoShot?.main == nil {
            photoShot?.main = render(source, corner: false)
            if photoShot?.second != nil { finishPhoto() }
        }
        recorder?.append(video: frame, at: time)
        show(frame, at: time)

        let now = Date()
        if renderState.findsMount && !checkingMount && now.timeIntervalSince(lastMountCheck) > 0.5 {
            lastMountCheck = now
            checkingMount = true
            let deviceID = renderState.deviceID
            mountQueue.async {
                self.findMount(source, deviceID: deviceID)
                self.frameQueue.async { self.checkingMount = false }
            }
        }
        if now.timeIntervalSince(lastReport) > 0.25 {
            lastReport = now
            let black = Self.isBlack(source)
            DispatchQueue.main.async {
                self.lastFrameSeen = now
                self.blackSince = black ? self.blackSince ?? now : nil
                self.updateFeed()
            }
        }
    }

    /// Frame queue. Loudness at about 20 Hz: 0 at -60 dBFS, 1 at full scale.
    private func reportLevel(_ sample: CMSampleBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelReport) > 0.05, let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var data: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &data) == noErr,
              let data, length >= 4 else { return }
        lastLevelReport = now
        let samples = UnsafeBufferPointer(start: UnsafeRawPointer(data).assumingMemoryBound(to: Float.self), count: length / 4)
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 60) / 60))
        DispatchQueue.main.async { self.micLevel.value = level }
    }

    /// No sampled point lit above 8 of 255. A camera that is off sends pure black; a dim room
    /// still has some point above that.
    private static func isBlack(_ buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        for gy in 1...16 {
            for gx in 1...16 {
                let p = base + (h * gy / 17) * stride + (w * gx / 17) * 4
                if max(p[0], p[1], p[2]) > 8 { return false }
            }
        }
        return true
    }

    /// Mirror, then turn, then cut the aspect, so a sideways camera is upright before the crop.
    private static func place(_ input: CIImage, mirrored: Bool, rotation: Int, size: CGSize, framing: Double) -> CIImage {
        var image = input
        if mirrored {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: image.extent.width, ty: 0))
        }
        switch rotation {
        case 90: image = image.oriented(.right)
        case 180: image = image.oriented(.down)
        case 270: image = image.oriented(.left)
        default: break
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        let crop = Config.crop(image.extent, ratio: size.width / size.height, framing: framing)
        let scale = size.width / crop.width
        return image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    /// The second camera's corner: the output's shape at under a third of its size, both sides even.
    static func insetSize(_ size: CGSize) -> CGSize {
        CGSize(width: (size.width * 0.15).rounded() * 2, height: (size.height * 0.15).rounded() * 2)
    }

    /// Frame queue. A buffer of `size` from `pool`, made again when the size changes.
    private func makeBuffer(_ size: CGSize, pool: inout CVPixelBufferPool?, poolSize: inout CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            poolSize = size
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }

    /// Frame queue. Rendered into its own small buffer, so the camera's buffer goes straight back to it.
    private func renderInset(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let s = renderState, size = Self.insetSize(s.size)
        guard size.width > 0, size.height > 0,
              let out = makeBuffer(size, pool: &insetPool, poolSize: &insetPoolSize) else { return nil }
        let image = Self.place(CIImage(cvPixelBuffer: source), mirrored: s.mirrored, rotation: s.insetRotation, size: size, framing: 0)
        ciContext.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        CVBufferSetAttachment(out, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        return out
    }

    /// The second camera in the bottom-right corner, rounded, with a thin light edge to set it apart.
    private static func withInset(_ inset: CIImage, over image: CIImage) -> CIImage {
        let short = min(image.extent.width, image.extent.height)
        let margin = (short * 0.04).rounded(), edge = max(2, (short * 0.004).rounded())
        let frame = inset.extent, radius = min(frame.width, frame.height) * 0.1
        func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
            CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: rect), "inputRadius": radius, "inputColor": color,
            ])?.outputImage ?? CIImage(color: color).cropped(to: rect)
        }
        let rounded = inset.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: frame),
            kCIInputMaskImageKey: roundedRect(frame, radius: radius, color: .white),
        ])
        let border = roundedRect(frame.insetBy(dx: -edge, dy: -edge), radius: radius + edge, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        // Core Image's y grows upward, so the bottom margin is the origin's y.
        let move = CGAffineTransform(translationX: image.extent.maxX - frame.width - margin, y: image.extent.minY + margin)
        return rounded.composited(over: border).transformed(by: move).composited(over: image).cropped(to: image.extent)
    }

    /// `second` renders the corner camera's own full picture, centred and without blur; `corner` draws the corner over the main one.
    private func render(_ source: CVPixelBuffer, second: Bool = false, corner: Bool = true) -> CVPixelBuffer? {
        let s = renderState
        let size = s.size
        guard size.width > 0, size.height > 0 else { return nil }
        var image = Self.place(CIImage(cvPixelBuffer: source), mirrored: s.mirrored, rotation: second ? s.insetRotation : s.rotation,
                               size: size, framing: second ? 0 : s.framing)
        if s.blur > 0 && !second {
            // A failed frame reuses the last mask, or blurs everything, so the room never shows sharp.
            if let mask = personMask(image) { lastMask = mask }
            let background = image.clampedToExtent().applyingGaussianBlur(sigma: s.blur).cropped(to: image.extent)
            image = lastMask.map { image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: $0,
            ]) } ?? background
        } else {
            lastMask = nil
        }
        // A second camera that stopped sending for a second leaves the corner rather than freezing in it.
        if corner && !second, s.insetID != nil, let inset = insetFrame, Date().timeIntervalSince(insetFrameAt) < 1 {
            image = Self.withInset(CIImage(cvPixelBuffer: inset), over: image)
        }
        if s.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.exposure])
        }

        guard let out = makeBuffer(size, pool: &pool, poolSize: &poolSize) else { return nil }
        ciContext.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        // Untagged, the preview layer shows these bytes in each display's own colors, oversaturated and banded.
        CVBufferSetAttachment(out, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return out
    }

    /// Mount queue. A face lying on its side says how the camera is mounted. Vision's roll is the
    /// clockwise turn that stands the raw picture upright; a tilted head (over 30° off a quarter turn) is no reading.
    private func findMount(_ source: CVPixelBuffer, deviceID: String?) {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        try? VNImageRequestHandler(cvPixelBuffer: source).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              face.confidence > 0.6, let roll = face.roll?.doubleValue else { return }
        let degrees = roll * 180 / .pi, quarter = (degrees / 90).rounded()
        guard abs(degrees - quarter * 90) < 30 else { return mountVotes = [] }
        mountVotes = Array((mountVotes + [(Int(quarter) * 90 % 360 + 360) % 360]).suffix(5))
        guard mountVotes.count == 5, Set(mountVotes).count == 1 else { return }
        let turn = mountVotes[0]
        mountVotes = []
        DispatchQueue.main.async {
            guard self.config.deviceID == deviceID, !self.isRecording,
                  let key = self.mountKey, self.config.rotations[key] == nil else { return }
            // The picture is mirrored before it is turned, and a mirror reverses the turn.
            self.rotation = self.config.mirrored ? 360 - turn : turn
        }
    }

    private func personMask(_ picture: CIImage) -> CIImage? {
        let extent = picture.extent
        guard (try? segmentationSequence.perform([segmentation], on: picture)) != nil,
              let mask = segmentation.results?.first?.pixelBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: mask)
        return image.transformed(by: CGAffineTransform(scaleX: extent.width / image.extent.width, y: extent.height / image.extent.height)
            .translatedBy(x: extent.minX, y: extent.minY))
    }

    private func show(_ frame: CVPixelBuffer, at time: CMTime) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}

enum CamError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

final class MicLevel: ObservableObject {
    @Published var value: Float = 0
}
