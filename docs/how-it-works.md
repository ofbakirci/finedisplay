# How FineDisplay works

Written after the investigation on 2026-08-18/19. Test rig: MacBook Pro 16" (M1 Pro),
macOS 15.7.3 Sequoia (24G419), Arzopa Z1RC 16" 2560 × 1600 over the Mac's HDMI port.

## The symptom

System Settings for the Arzopa offers HiDPI ("Retina") modes only up to `1280 × 800 @2x`
(backing 2560 × 1600 = the panel). The MacBook's own panel (3024 × 1964) offers
`1800 × 1169 @2x` (backing 3600 × 2338), larger than the panel. That is supersampling: render
big, let the GPU scale down. Apple ships it for its own panels and for 4K+ displays, and
withholds it from most sub-4K externals.

## What is really in the mode table

`CGDisplayCopyAllDisplayModes` returned 46 modes for the Arzopa with a gap in the IDs
(0–24, then 34–54). Asking WindowServer directly with the private
`CGSGetNumberOfDisplayModes` / `CGSGetDisplayModeDescriptionOfLength` returned 55 modes.
The missing nine:

| mode | looks like | backing | flags |
|-----:|-----------:|--------:|------:|
| 25 | 1024 × 768 | 2048 × 1536 | 0x00200001 |
| 26 | 1280 × 960 | 2560 × 1920 | 0x00200001 |
| 27 | 1344 × 840 | 2688 × 1680 | 0x00200001 |
| 28 | 1344 × 1008 | 2688 × 2016 | 0x00200001 |
| 29 | 1600 × 1000 | 3200 × 2000 | 0x00200001 |
| 30 | 1600 × 1200 | 3200 × 2400 | 0x00200001 |
| 31 | **1920 × 1200** | **3840 × 2400** | 0x00200001 |
| 32 | **2048 × 1280** | **4096 × 2560** | 0x00200001 |
| 33 | 2560 × 1600 | 5120 × 3200 | 0x00200001 |

Bit 0x1 is `kDisplayModeValidFlag`. Bit 0x00200000 is `kDisplayModeValidForMirroringFlag`.
WindowServer built the modes, marked them "for mirroring", and the public API filters them.
Modes macOS lists have flags 0x1 or 0x02000001 (native). The tail entries (34–54) carry
0x40000000 and are duplicate low-resolution variants; FineDisplay ignores them.

The built-in panel's supersampled modes carry plain 0x1. Same generator, different flag.

## The switch

```c
CGDisplayConfigRef cfg;
CGBeginDisplayConfiguration(&cfg);
CGSConfigureDisplayMode(cfg, displayID, 31);        // SkyLight, private
CGCompleteDisplayConfiguration(cfg, kCGConfigurePermanently);
```

WindowServer accepted mode 31 immediately. `CGDisplayCopyDisplayMode` then reported
1920 × 1200 pt, 3840 × 2400 px, 60 Hz, ioFlags 0x200003. `system_profiler` showed
"Resolution: 3840 x 2400, UI Looks like: 1920 x 1200 @ 60.00Hz". A screenshot of the display
was 3840 × 2400. Mode 32 (2048 × 1280 @2x) worked the same way.

`kCGConfigurePermanently` made WindowServer write `Wide 2048 / High 1280 / Scale 2` for the
display's UUID into `com.apple.windowserver.displays.plist` (both `/Library/Preferences` and
`~/Library/Preferences/ByHost`). Whether WindowServer restores a mirroring-flagged mode by
itself on reconnect is not guaranteed, so FineDisplay also re-applies the saved choice on
`kCGDisplayAddFlag` / `kCGDisplayEnabledFlag` and after wake.

## Why this is the same thing Apple does

`/System/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-610/DisplayProductID-a040`
(13" MacBook Air, 2560 × 1600 panel) contains a `scale-resolutions` array with
3840 × 2400, 3360 × 2100, 2880 × 1800, 2560 × 1600, 2048 × 1280. Entries end with
`00000001 00200000` or `00000009 00a00000` — the same 0x00200000 / 0x00800000
(`kDisplayModeValidForHiResFlag`) bits. Sequoia's `CoreDisplay` and `SkyLight` binaries still
contain the strings `scale-resolutions`, `scale-resolutions-4k`, `target-default-ppmm`,
`default-resolution`, `edid-patches`, and the search paths
`/Library/Displays/Contents/Resources/Overrides`, `/AppleInternal/AppleDisplays/...`,
`/System/Library/Displays/...`. So the classic override-plist route also exists on Apple
Silicon; FineDisplay does not need it because the modes are already there.

## Other private symbols in the neighbourhood

`SkyLight` `GenerateModeListForDisplay` (Mode.mm) logs each mode with flags named
`link, scaler, unsupported, mirror-only, safe-aperture, always show, VRR, native, safe,
offline, default, fullscreen, hires, fake_vfm`, and reads `maximumSourceWidth/Height`
limits from the display link. Keys seen next to it: `DisplayDPICutoff`, `MinScaleFactor`,
`MaxScaleFactor`, `DisplaySupportsDynamicGeometry`. Useful if a future macOS stops
generating the modes and they must be coaxed out via the override plist instead.

## Struct layout used

Same as displayplacer's `modes_D4` (0xD4 bytes requested, 0xDC buffer):
mode @0, flags @4, width @8, height @12, depth @16, bytesPerRow @20, refresh (u16) @0xBE,
density (float) @0xD0. Verified on macOS 15.7.3.
