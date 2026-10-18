# Screen Mirror (iOS)

An iPhone/iPad app that mirrors your screen to smart TVs and web browsers, and casts photos,
videos and web video links to a TV. It's in the style of "Screen Mirroring – Smart View TV".

## Features

| Feature | How it works |
| --- | --- |
| **Screen mirroring to a smart TV** | A ReplayKit broadcast extension captures the screen, encodes H.264 and serves live HLS (`/live.m3u8`). The app then tells the TV to play that stream over DLNA/UPnP. |
| **Screen mirroring to a browser** | The same extension serves a low-latency MJPEG stream. Open `http://<phone-ip>:8080` on any TV browser, computer or tablet. |
| **Photos** | Pick photos and swipe through them. Each one is re-encoded as an upright 1080p JPEG and shown on the TV. |
| **Videos** | Pick a video. It's converted to H.264 MP4, which almost every TV can play, then streamed with seeking support. Play, pause, stop and volume work from the phone. |
| **Web video** | Paste a direct `.mp4` / `.m3u8` / image / audio link and the TV plays it straight from the web. |
| **TV discovery** | SSDP search for UPnP `MediaRenderer` / `AVTransport` devices: most Samsung, LG, Sony, Philips, Panasonic, Hisense and TCL TVs, plus many Android TV boxes and Xbox. |

## Layout

```
ScreenMirror/
├── project.yml                 XcodeGen spec (app + broadcast extension, App Group)
├── App/                        SwiftUI app
│   ├── AppModel.swift          State, TV casting, talks to the extension
│   ├── Services/               SSDP discovery, DLNA SOAP control, media HTTP server, media prep
│   └── Views/                  Home, Mirror, Photos, Videos, Web Video, Settings, Help
├── BroadcastExtension/         ReplayKit upload extension
│   ├── SampleHandler.swift     Gets screen frames and runs the HTTP server on :8080
│   ├── FrameProcessor.swift    Rotates and letterboxes frames to a fixed 16:9 size (VideoToolbox)
│   ├── HLSSegmenter.swift      AVAssetWriter → 1 s fMP4 HLS segments, kept in memory
│   └── MJPEGBroadcaster.swift  JPEG stream for browsers
└── Shared/                     Used by both targets: HTTP server, settings, Darwin notifications
```

The app and the extension share settings through an App Group. They signal each other
(started, ready, finished, stop) with Darwin notifications.

## Build & run

Requirements: Xcode 15 or later, iOS 16 or later, and a **real device**. ReplayKit broadcasts and
local-network casting don't work in the Simulator.

```bash
brew install xcodegen
cd ScreenMirror
xcodegen generate
open ScreenMirror.xcodeproj
```

Before the first run on a device:

1. In `project.yml`, set `DEVELOPMENT_TEAM`, `APP_BUNDLE_ID` and `APP_GROUP_ID` to your own values,
   then run `xcodegen generate` again.
2. In your Apple Developer account, register the App Group and enable it for both App IDs.
   With automatic signing, Xcode usually handles this.
3. **Multicast entitlement.** TV discovery sends SSDP multicast. Since iOS 14 this needs the
   `com.apple.developer.networking.multicast` entitlement, which you
   [request from Apple](https://developer.apple.com/contact/request/networking-multicast).
   Until Apple approves it, either:
   - remove that entitlement from `project.yml` and use **Web Browser** mirroring, which needs
     no discovery, or
   - test with a development profile once the entitlement has been granted.

CI builds the project for the Simulator on every push. See
`.github/workflows/screenmirror-ios.yml`.

## Known limitations / next steps

- **Delay on TVs:** TVs buffer HLS before they start playing, so expect about 3–6 s of delay.
  Browser mode is close to real time.
- **No audio while mirroring:** only video is streamed. Adding app audio means encoding the
  `.audioApp` sample buffers to AAC as a second track in `HLSSegmenter`.
- **TV compatibility:** some older TVs can't play fMP4 HLS. An MPEG-TS segmenter would cover them.
- **Chromecast / Roku / Fire TV** use their own protocols, not DLNA. They could be added with the
  Google Cast SDK, Roku ECP and so on.
- **Background casting:** the photo/video server lives in the app, so iOS may suspend it in the
  background. Screen mirroring keeps running in the background because it lives in the extension.
- **Monetisation** (subscriptions, paywall, ads) like the original app isn't included.
