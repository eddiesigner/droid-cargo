# DroidCargo

Native macOS app for moving files between a Mac and Android phones.

## Requirements

- macOS 26+
- Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Android Platform Tools: installed by the app on first launch (from
  Google), or an existing Homebrew / Android Studio copy
- On the phone: USB debugging enabled, USB mode set to File transfer

## Build

```bash
xcodegen generate
open DroidCargo.xcodeproj
```

Package tests:

```bash
cd Packages/DroidCargoKit && swift test
```

## Architecture

Each layer talks only to the one below it.

```
App (SwiftUI views, AppModel/BrowserModel)
  └─ CargoServices   DeviceService, FileService, TransferService,
                     ThumbnailService, PreviewService, PhotoImportService
       └─ DeviceKit  DeviceTransport / DeviceSession protocols, models
            └─ ADBKit  adb server client (host + sync protocol over TCP 5037)
```

- `ADBKit` speaks the adb wire protocol directly instead of spawning `adb`
  per command: one socket per operation, 64-bit sizes (`LIS2`/`STA2`),
  batched `DATA` packets.
- Transfers count all files first (accurate progress), run a few files in
  parallel, write to hidden temp files, verify size, then rename into place.
  Transient errors retry on a fresh connection, waiting up to 20 s for an
  unplugged phone to return.

## Performance notes

- File list and icon grid are `NSTableView` / `NSCollectionView`: cells are
  reused and SwiftUI never diffs thousands of rows.
- Photo thumbnails read only the first 64 KB (the camera's embedded preview).
  Videos read the first 4 MB and last 2 MB into a sparse file.
- Device benchmarks: `DROIDCARGO_DEVICE_TESTS=1 swift test -c release`.
- Open a folder at launch: `open DroidCargo.app --args -openPath <path>`.
- Preview the first-launch install screen with a fake install (no download):
  `open DroidCargo.app --args -simulateMissingTools YES`.
- Installer test (downloads ~16 MB):
  `DROIDCARGO_NETWORK_TESTS=1 swift test --filter PlatformToolsInstallerTests`.

## Status

- [x] ADB transport
- [ ] MTP transport (no USB debugging needed)
- [x] One-click Platform Tools install
- [ ] Developer ID signing
