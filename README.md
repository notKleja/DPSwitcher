# DPSwitcher

A macOS menu bar utility that switches a monitor's input source between DisplayPort and USB-C via DDC/CI, with a fade-to-black + blur transition. Built as the macOS counterpart to a Windows tray app doing the same thing over `dxva2.dll`.

This doc explains the mechanism in enough detail to port the same behavior to a Windows clone (or any other platform).

## Hardware setup this was built for

- One external monitor, connected to a Windows PC via DisplayPort and to a Mac via USB-C (DisplayPort Alt Mode) simultaneously.
- VCP feature code `0x60` (input source, per VESA MCCS) values for this monitor:
  - DisplayPort = `15` (`0x0F`)
  - USB-C = `26` (`0x1A`)
- The monitor keeps listening for DDC/CI commands on **both** lines regardless of which input is currently active/displayed. This matters a lot (see "Detecting the switch back" below).

## Core mechanism: DDC/CI on Apple Silicon

Windows reaches DDC/CI via `dxva2.dll`'s `GetVCPFeatureAndVCPFeatureReply` / `SetVCPFeature`. macOS has no public equivalent, and the classic approach (`CGDisplayCreateImage`-adjacent `IOFramebuffer`-based tools like `ddcctl`) **does not work on Apple Silicon** — there's no `IOFramebuffer` service for the GPU anymore.

The mechanism that does work on Apple Silicon is a private IOKit path:

- `IOAVServiceCreateWithService` — wraps an IOKit `DCPAVServiceProxy` service (found via `IOServiceMatching("DCPAVServiceProxy")`, filtering for `Location == "External"`) into an `IOAVServiceRef`.
- `IOAVServiceWriteI2C(service, chipAddress: 0x37, offset: 0x51, data, len)` / `IOAVServiceReadI2C(...)` — send/receive raw DDC/CI I2C frames over that AV service.

This is exactly what [BetterDisplay](https://github.com/waydabber/BetterDisplay) and the CLI tool [`m1ddc`](https://github.com/waydabber/m1ddc) use internally (confirmed by inspecting BetterDisplay's linked frameworks and undefined symbols: `IOAVServiceCreateWithService`, `IOAVServiceReadI2C`, `IOAVServiceWriteI2C`, linked against `/System/Library/PrivateFrameworks/DisplayServices.framework` and `CoreDisplay.framework`).

**This app doesn't reimplement the DDC/CI protocol itself** — it shells out to the pre-built `m1ddc` CLI (`brew install m1ddc`), which already does it correctly:

```
m1ddc display 1 set input 15    # switch to DisplayPort
m1ddc display 1 set input 26    # switch to USB-C
m1ddc display 1 get input       # read the current VCP 0x60 value (undocumented but works)
```

A hand-rolled implementation of the DDC/CI "Set/Get VCP Feature" frame format (VESA MCCS, checksum = XOR of all bytes including a virtual destination-address byte) was attempted directly via `IOAVServiceWriteI2C`/`ReadI2C` early on, but produced unreliable/echoed reads. `m1ddc`'s implementation is proven and is what's actually used here.

## Detecting the "switch back" (the tricky part)

Switching the VCP 0x60 register **does not disconnect the physical USB-C link** — the cable stays connected, EDID stays present, and the monitor just stops actively scanning out the Mac's frame. This means:

- **`NSApplication.didChangeScreenParametersNotification` never fires** when the input source changes — from either direction (Mac-initiated or from the PC's own tray app). There's no OS-level "display reconnected" signal to hook into for a DDC-only input switch.
- The only reliable way to detect "we're back on USB-C" is **polling `m1ddc display 1 get input`** and checking for the current input value.

Reads are noisy at the I2C level — polling shows occasional garbage values (e.g. `0` or `1`) interleaved with the correct value, even while the input is stable. **Require 2+ consecutive matching reads** before trusting a state transition, or you'll get false triggers.

Each `m1ddc` subprocess call takes **~130-150ms**, almost entirely process-spawn/dynamic-linker overhead (loading `CoreDisplay`/`DisplayServices` frameworks), not the I2C transaction itself. Benchmarked directly:

```
call 1: 126.8ms -> 26
call 2: 131.4ms -> 26
...
call 10: 129.9ms -> 0   (noise)
```

Polling faster than that floor is pointless — a background-thread poll loop with an in-flight guard (skip a tick if the previous subprocess call hasn't returned yet) naturally runs at the achievable ~130ms cadence regardless of the timer interval set below that. A true low-latency version would need to replicate `m1ddc`'s in-process `IOAVServiceReadI2C` call instead of shelling out — not done here because our own from-scratch attempt at the read protocol wasn't reliable (see above).

## Visual transition (fade-to-black + blur)

Because the panel is OLED, a plain color fade would look like the screen "turning off" abruptly at black, so the transition blurs the desktop content while darkening it, then switches the input mid-black.

- **Live blur, no screenshot needed:** `NSVisualEffectView`'s live blur (used by most macOS blur effects) is driven by a private, per-instance `CABackdropLayer` that the system continuously re-manages — an externally-added `CABasicAnimation` on its blur filter's `inputRadius` gets silently overridden/ignored, so the radius can't actually be animated that way.
  - The fix: create your **own** `CABackdropLayer` directly (`NSClassFromString("CABackdropLayer")`, since it has no public header) with `windowServerAware = true` and a `groupName`. Attach your own `CAFilter` (also private, `NSClassFromString("CAFilter")`, created via `+[CAFilter filterWithType:@"gaussianBlur"]`) to its `filters` array. Because *you* own this filter instance, `CABasicAnimation(keyPath: "filters.gaussianBlur.inputRadius")` on the backdrop layer animates correctly and live-blurs whatever is behind the window across the whole window server (not just within one process).
  - Set `backdrop.scale = 1.0` for full-resolution sampling (the sample code that inspired this used `0.25` for a cheaper/softer blur).
- **Darkening:** a separate plain black `CALayer` on top, its `opacity` animated 0→1 in perfect sync (not staggered) with the blur radius animation — using a chained `colorBrightness` CAFilter on the same backdrop layer instead produced visible clipping/"burnt" artifacts near black, so a plain composited black layer is simpler and correct.
- **Timing:** a `CABasicAnimation` with an explicit `duration` and a `CAMediaTimingFunction(controlPoints:...)` cubic-bezier — not a `CASpringAnimation`, whose `settlingDuration` didn't match hand-computed physics parameters reliably in practice, making duration control unpredictable.
- **Screenshot avoided:** an earlier version captured a real screenshot and animated a `CIGaussianBlur` on it for a guaranteed-correct radius ramp, but any screen-capture API (even a single `screencapture` CLI call) triggers macOS's screen-recording indicator, which was visually unwanted. The live `CABackdropLayer` approach above gives the same animatable-radius blur without that.

## Menu bar UI

- `NSStatusItem` with an SF Symbol image (`NSImage(systemSymbolName:)`), forced to flat monochrome rendering via `NSImage.SymbolConfiguration(...).applying(.preferringMonochrome())` — the default rendering mode for some symbols is hierarchical (multi-opacity), which looks inconsistent in a menu bar icon.
- Double left-click: fade to black+blur → switch to DisplayPort → **stay covered and poll indefinitely** for the display coming back (since the user may switch back from the PC's side, not from this app). A single left-click does nothing.
- Right-click: a manual `NSMenu` with "Switch to DisplayPort" / "Switch to USB-C" (the latter covers instantly at full black+blur since there's nothing to show anyway, switches, then polls for confirmation before revealing).
- Click-to-reset: a `NSClickGestureRecognizer` on the overlay lets the user dismiss it manually if something goes wrong, cancelling all pending animation/poll work.

## Build and test

From the repository root:

```sh
swiftc DPSwitcher/StatusItemClickPolicy.swift DPSwitcher/main.swift \
  -o DPSwitcher/DPSwitcher.app/Contents/MacOS/DPSwitcher \
  -framework Cocoa -framework QuartzCore

swiftc DPSwitcher/StatusItemClickPolicy.swift Tests/StatusItemClickPolicyTests.swift \
  -o /tmp/StatusItemClickPolicyTests
/tmp/StatusItemClickPolicyTests
```

## Building a Windows equivalent

The Windows side already has the DDC/CI plumbing (`dxva2.dll`). What's portable from this doc:

1. **VCP polling for switch-back detection** — same problem applies: input switching doesn't trigger a device-change event, so poll `GetVCPFeatureAndVCPFeatureReply` for VCP 0x60 periodically, debounce with 2+ consecutive matching reads.
2. **Blur transition** — Windows has no `CABackdropLayer` equivalent, but Desktop Window Manager (DWM)/Acrylic (`DWM_BLURBEHIND`, or `Windows.UI.Composition`'s `CompositionBackdropBrush`/host backdrop brush) can live-blur behind a window, and its blur amount (via a Gaussian blur effect in a Composition pipeline) is directly animatable, so this constraint doesn't apply on Windows.
3. **Log everything** — a plain timestamped file logger (see this app's `log()` function) made every failure mode diagnosable without guessing; recommended for the Windows clone's testing phase too.
