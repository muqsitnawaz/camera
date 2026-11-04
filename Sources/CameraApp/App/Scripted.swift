import AppKit

extension AppDelegate {
    /// `--list`, `--photo` or `--record <s>`: capture without UI, print the path, quit. Options are in SKILL.md.
    func runScripted() -> Bool {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        func fail(_ message: String) -> Never {
            print("error: \(message)")
            exit(1)
        }
        func option<T>(_ flag: String, _ expected: String, _ parse: (String) -> T?) -> T? {
            guard args.contains(flag) else { return nil }
            if let parsed = value(after: flag).flatMap(parse) { return parsed }
            fail("\(flag) takes \(expected)")
        }
        // A mistyped flag such as --phot must fail, not open the app or capture with defaults.
        let known: Set = ["--list", "--photo", "--record", "--aspect", "--res", "--fps", "--camera", "--mic", "--rotate", "--blur", "--brighten"]
        if let unknown = args.dropFirst().first(where: { $0.hasPrefix("--") && !known.contains($0) }) {
            fail("unknown option \(unknown); the options are \(known.sorted().joined(separator: " "))")
        }
        let name = { (flag: String) in option(flag, "part of a name from --list") { $0.isEmpty || $0.hasPrefix("--") ? nil : $0 } }
        if args.contains("--list") {
            print("cameras:")
            camera.devices.forEach { print("  \($0.localizedName)\($0.isSuspended ? " (off: lid closed)" : "")") }
            print("microphones:")
            camera.mics.forEach { print("  \($0.localizedName)") }
            exit(0)
        }
        let photo = args.contains("--photo")
        guard photo || args.contains("--record") else { return false }
        let seconds = option("--record", "a length in seconds, such as --record 5") { Double($0).flatMap { $0 > 0 && $0.isFinite ? $0 : nil } }
        if let (aspect, landscape) = option("--aspect", "9:16, 4:5, 3:4, 1:1, 16:9, 5:4 or 4:3", Aspect.parse) {
            camera.config.aspect = aspect
            camera.config.landscape = landscape
        }
        if let name = name("--camera") {
            let wanted = name.lowercased()
            let names = camera.devices.map { ($0, $0.localizedName.lowercased()) }
            guard let device = (names.first(where: { $0.1.hasPrefix(wanted) }) ?? names.first(where: { $0.1.contains(wanted) }))?.0 else {
                fail("no camera matching \(name); --list shows them")
            }
            camera.config.deviceID = device.uniqueID
        }
        if let name = name("--mic")?.lowercased() {
            guard let mic = camera.mics.first(where: { $0.localizedName.lowercased().contains(name) }) else {
                fail("no microphone matching \(name); --list shows them")
            }
            camera.config.micOn = true
            camera.config.micID = mic.uniqueID
        }
        if let degrees = option("--rotate", "0, 90, 180 or 270", { Int($0).flatMap { [0, 90, 180, 270].contains($0) ? $0 : nil } }) {
            camera.rotation = degrees
        }
        if let res = option("--res", "720, 1080, 1440 or 2160", { Int($0).flatMap(Resolution.init(rawValue:)) }) { camera.config.resolution = res }
        if let fps = option("--fps", "23.98, 24, 30 or 60", FrameRate.init(rawValue:)) { camera.config.frameRate = fps }
        if let blur = option("--blur", "soft or strong", { Blur(rawValue: $0).flatMap { $0 == .off ? nil : $0 } }) { camera.config.blur = blur }
        if let brighten = option("--brighten", "more or most", { Brighten(rawValue: $0).flatMap { $0 == .off ? nil : $0 } }) {
            camera.config.brighten = brighten
        }
        // No location prompt in a script, and the centred crop SKILL.md promises.
        camera.config.saveLocation = false
        camera.config.framing = 0
        camera.config.mode = photo ? .photo : .video

        func finish(_ url: URL?) {
            // After the main-queue work already pending, so a reason reported just before is printed.
            DispatchQueue.main.async { [camera] in
                print(url?.path ?? "error: \(camera.errorMessage ?? "nothing captured")")
                exit(url == nil ? 1 : 0)
            }
        }
        camera.start()
        // Up to 6 s for a live picture, then 1 s for exposure; no picture fails with the reason.
        let deadline = Date().addingTimeInterval(6)
        func act() {
            if photo {
                camera.takePhoto(completion: finish)
            } else if let seconds {
                camera.startRecording()
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [camera] in camera.stopRecording(completion: finish) }
            }
        }
        func poll() {
            if camera.feed == .live {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: act)
            } else if Date() > deadline {
                act()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
            }
        }
        poll()
        return true
    }
}
