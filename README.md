# DroidCargo

Native macOS app for moving files between a Mac and Android phones.

## Requirements

- macOS 26+
- Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Android Platform Tools (`brew install android-platform-tools`)
- On the phone: USB debugging enabled

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

## Status

- [x] ADB transport
- [ ] MTP transport (no USB debugging needed)
- [ ] Video thumbnails without full download
- [ ] Bundled adb, Developer ID signing
