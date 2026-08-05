# TouchSynthesis

On-device iOS touch automation and screen streaming. A client on the local network connects over TCP to see the screen and drive the device. No Mac, no jailbreak, no WebDriverAgent.

## How It Works

The app is a **self-runner**: it plays both the IDE (DTX to `testmanagerd`) and the test runner (XCTest via `dlopen`) in one process. That's what removes the need for WDA — on iOS 26, AMFI strips all environment variables from processes launched via AppService, so `XCTestSessionIdentifier` never survives to a separately-spawned runner. Setting it on ourselves with `setenv` does survive.

### Setup path (once, ~60s)

1. **VPN loopback** — LocalDevVPN maps `10.7.0.0 ↔ 10.7.0.1`, giving a network path to our own `lockdownd`
2. **Lockdown** — TCP to `10.7.0.1:62078`, TLS session from the pairing record
3. **Heartbeat** — marco/polo keepalive on a background thread; keeps the DDI mounted
4. **CDTunnel** — `StartService(CoreDeviceProxy)` → RemoteServiceDiscovery → developer services
5. **DTX** — two connections to `com.apple.dt.testmanagerd.remote` through an RSD proxy: control session + test session. The lockdown-based `testmanagerd` services don't exist on iOS 26, so the RSD path is required.
6. **XCTest** — `dlopen` XCTest.framework, then the `XCTRunnerDaemonSession` XPC handshake (~50s on first call)
7. **`enableAutomationModeWithError:`** — triggers the iOS passcode prompt; on entry, the "Automation Running" overlay appears

Call *only* `enableAutomationModeWithError:` here. `finishInitializationForUIAutomation`, `requestAutomationSessionForTestTargetWithPID:`, and `_XCT_enableAutomationModeWithReply:` all tear the overlay back down within a second.

### Hot path (per event)

Once automation is enabled, the tunnel is out of the loop entirely:

- **Touch** — build an `XCPointerEventPath` (geometry + timing), wrap it in an `XCSynthesizedEventRecord`, call `synthesizeWithError:`. Synchronous and in-process. A `daemonProxy._XCT_synthesizeEvent:` fallback exists but carries a ~5s quiescence wait per event, so it is not the path normally taken.
- **Screenshot** — `daemonProxy._XCT_requestScreenshot:` over the already-open testmanagerd XPC session, requesting JPEG directly. ~15-25 FPS. Falls back to RemoteServer/ScreenshotClient over a fresh CDTunnel per frame after five consecutive failures.

Every gesture is those same two objects, differing only in how the path is drawn: a tap is a touch-down plus `liftUpAtOffset:0.125`; a swipe adds interpolated `moveToPoint:atOffset:` steps; a pinch is two paths in one record; keyboard input swaps `initForTouchAtPoint:` for `initForTextInput`. Hardware buttons (home, volume) go through `XCUIDevice.pressButton:` instead. An IOKit HID path is wired up as a last resort but does not deliver system-wide touches without additional entitlements.

## Remote Control Protocol

TCP on port 8347, length-prefixed JSON.

- **Screenshot streaming** — `{"action":"startStream","params":{"quality":0.3}}` begins a continuous stream of length-prefixed JPEG frames (4-byte big-endian length + data). `TCP_NODELAY` is on.
- **Touch relay** — clients stream `touchBegan`/`touchMoved`/`touchEnded` as the finger moves. The server accumulates every point with its timing and, on `touchEnded`, replays the whole trajectory as one continuous `XCPointerEventPath` rather than a burst of taps.
- **Fire-and-forget** — touch and gesture commands return success immediately and synthesize in the background, keeping round-trip latency off the critical path.

## Prerequisites

- iOS 26+ (tested on iPhone 13 Pro, iOS 26.3)
- DDI mounted + VPN loopback, via LocalDevVPN or similar
- A pairing record from a trusted Mac (`/var/db/lockdown/` or Xcode)
- Rust toolchain, to build the idevice FFI library

## Build

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen), Xcode 16+, and [Rust](https://rustup.rs/).

```bash
git clone --recursive <repo-url> && cd TouchSynthesis
rustup target add aarch64-apple-ios
./scripts/build-idevice.sh          # cross-compile idevice FFI
xcodegen generate
xcodebuild -project TouchSynthesis.xcodeproj -scheme TouchSynthesis \
  -sdk iphoneos -allowProvisioningUpdates build
```

## Usage

1. Open LocalDevVPN (DDI mount + VPN loopback)
2. Launch TouchSynthesis and import the pairing record (first run only)
3. Tap **Start UI Automation**, wait ~60s, and enter the passcode when prompted
4. Tap **Start Server** to open the TCP listener on 8347, then connect a client
5. **Stop UI Automation** tears everything down — hold the volume buttons if the overlay lingers

## Layout

| Path | Contents |
|---|---|
| `TestManager/` | `TestManagerClient` (DTX RPC to testmanagerd), `SelfRunner` (orchestration) |
| `TouchSynthesizer/` | XCTest dlopen, event construction, synthesis, screenshots, IOKit HID |
| `DTX/` | Connection, message codec, channel multiplexing, auxiliary encoding |
| `Lockdown/` | TCP + TLS lockdownd client |
| `RemoteControl/` | TCP server, command dispatch, streaming, touch accumulation |
| `idevice/` | ObjC wrapper over the Rust FFI: CDTunnel, heartbeat, RSD proxies |
| `App/`, `Model/`, `Util/` | UI, pairing record parsing, logging, background keepalive |

Build artifacts (`idevice.h`, `libidevice_ffi.a`) land in `idevice/`; the upstream submodule is in `vendor/idevice`.

## Credits

- [idevice](https://github.com/jkcoxson/idevice) — Rust library for lockdownd, CoreDevice tunnel, heartbeat, screenshots
- [StikDebug](https://github.com/StephenDev0/StikDebug) — source of the heartbeat + fresh-CDTunnel-per-operation pattern
- XCTest private API (`XCSynthesizedEventRecord`, `XCPointerEventPath`, `XCTRunnerDaemonSession`) and Apple's DTX protocol, implemented from scratch
