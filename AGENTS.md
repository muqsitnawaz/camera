# Camera: notes for coding agents

Camera is a macOS 14+ menu-bar camera in Swift: a SwiftPM executable packaged into an app
by `scripts/build.sh` (no Xcode project). To *use* the app from an agent, read
[`skills/camera/SKILL.md`](skills/camera/SKILL.md). This file is for changing it.

## Layout

| File | Owns |
|---|---|
| `Sources/CameraApp/App/main.swift` | The menu-bar item, popover and quit handling |
| `Sources/CameraApp/App/Scripted.swift` | Command-line capture: `--list`, `--photo`, `--record` |
| `Sources/CameraApp/Capture/Config.swift` | `Config` and its value types: mode, aspect, resolution, frame rate, blur, brighten |
| `Sources/CameraApp/Capture/Camera.swift` | The capture session, rendering and effects, the feed state, photos, the mic level |
| `Sources/CameraApp/Capture/Recorder.swift` | Writing the H.264/AAC `.mp4` |
| `Sources/CameraApp/Capture/Library.swift` | `~/Pictures/Camera`: file names, the recent-captures list |
| `Sources/CameraApp/Capture/Location.swift` | Location for the Location setting, and its EXIF and ISO 6709 forms |
| `Sources/CameraApp/UI/ContentView.swift` | The popover: preview and its overlays, aspect and mode, shutter row, strip |
| `Sources/CameraApp/UI/Controls.swift` | The camera menu, aspect picker, Camera Settings panel and effects tray |
| `Sources/CameraApp/UI/CaptureViewer.swift` | Viewing a photo or playing a video in place, laid out like Photos |
| `Sources/CameraApp/UI/Components.swift` | Shutter, level meter, recording badge, thumbnail, preview layer |
| `Sources/CameraApp/UI/RingLight.swift` | The screen-edge ring light windows |
| `scripts/` | `build.sh` (universal, signed), `install.sh`, `test.sh`, `release.sh`, `make-icon.swift` |

## Invariants

Each of these fixed a real bug. Keep them when changing the code.

- **One config, one apply.** Every setting lives in `Config`, and `Camera.apply()` is the only
  place the session, format and render state are brought in line with it. Add a setting as a
  `Config` field, never as a separate property with its own update path.
- **One buffer for everything.** Each frame is mirrored, then rotated, then cropped and scaled
  once (`render`), then the background blur and brightening are applied. The person mask comes
  from the upright, cropped picture. The preview, the recording and photos all use that buffer,
  so what you see is what is saved. The crop slides along the side it doesn't fill by
  `Config.framing` (`Config.crop`, shared with the drag and its map); scripted runs centre it.
  Dragging applies many times a second, so `apply()` sets the camera's format again only when it
  changes.
- **Frame duration is clamped to the format's range.** An out-of-range duration raises an
  Objective-C exception Swift can't catch (this crashed on the Cam Link 4K). Set the format and
  durations again after `startRunning()` and after the mic joins, because both reset them.
- **The microphone is in the session whenever the camera runs in Video with sound on**
  (`Config.recordsSound`, `updateMic`), so its level shows before recording. Photo never opens it.
  It joins before `startRunning()` when the popover opens in Video. Switching from Photo to Video
  adds it to the running session, which pauses the picture for under a second. It never changes
  during a recording.
- **One gesture rule in the UI.** A click turns an on/off control on or off; a right-click shows
  its choices (`.contextMenu`), and picking one also turns the control on. Settings that change
  the file live in Camera Settings (the format badge); effects that change the picture live in
  the effects tray, over the picture.
- **Location is off by default** and is only written when the person turns on Location:
  EXIF GPS in photos, an ISO 6709 `location` tag in videos. Scripted runs never save it.
- **Timestamps.** Samples more than 1 s off the host clock are dropped (a Continuity Camera's
  first frames can be minutes off), and video and audio appends must strictly increase.
- **A camera's turn is keyed by model and name** (`Camera.mountKey`), never its `uniqueID`, which
  changes with the USB port on a Cam Link 4K. A camera with no saved turn is turned from Vision's
  face roll: five agreeing readings, within 30° of a quarter turn. Any saved turn, even upright,
  stops the detection, and scripted runs never detect. A turn applies after the mirror, so turning
  Mirror on or off flips every saved turn (`Config.mirrored`). Two identical cameras share a turn.
- **The feed state comes from frames that actually arrive.** It is live, waiting, black,
  suspended (lid closed) or no camera. A black picture is a hint and still captures: no sampled
  point above 8 of 255 for 3 s in a row, so a dim room never reads as black.
- **A stand-in camera is never saved.** If the chosen camera is unplugged or suspended, another
  stands in, and the chosen one comes back when it reappears.
- **Command-line captures never persist.** `Camera(persists:)` is fixed at init, because init
  itself can switch cameras and save.
- **Fail closed.** An unknown command-line option or an invalid value is an error naming the
  valid ones, never a capture with defaults.

## Verify on real hardware

Builds prove nothing about a camera app. Before calling a change done:

```sh
./scripts/build.sh                      # universal app in build/
./scripts/test.sh [camera]              # real captures: sizes, frame rates, sound (needs ffprobe)
build/Camera.app/Contents/MacOS/Camera --list
```

`test.sh` writes into `~/Pictures/Camera`; move what it made to the Trash afterwards. For
a UI change, look at the popover itself: open it from the menu bar and take a screenshot.
Cameras are shared hardware, so a capture fails or stutters while another app holds the same
camera. Check that before blaming the code.

## Release

Bump `CFBundleShortVersionString` in `Resources/Info.plist`, merge to `main`, then, from a clean
checkout of `main`:

```sh
APPLE_ID=… APPLE_TEAM_ID=… APPLE_APP_SPECIFIC_PASSWORD=… ./scripts/release.sh notes.md
```

It builds with a secure timestamp, notarizes, staples, and publishes `v<version>` on GitHub.
The images in `docs/` show the real popover with a synthetic picture; never put a real camera
capture or anyone's screen in the repo. `docs/design/index.html` is the interactive design
prototype the README links to, served by GitHub Pages from `docs/`.
