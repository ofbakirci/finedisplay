# FineDisplay

**Unlock the HiDPI modes macOS hides on your external display. Free, open source, one click.**

macOS builds "looks like 1920 × 1200 (rendered at 3840 × 2400)" modes for many external
displays and then hides them. FineDisplay shows those modes and switches to them. No virtual
displays, no mirroring, no system files, no reboot. It is the same native pipeline your
MacBook's built-in Retina display uses.

Made by [nousworks](https://nousworks.co) · [nousworks.co/finedisplay](https://nousworks.co/finedisplay)

## What you get

- Menu bar app: pick a mode per display. ★ marks the modes macOS hides.
- Remembers your choice per display. Re-applies it when the display reconnects or the Mac wakes.
- Optional launch at login.
- `finedisplay` command-line tool for scripts.
- Universal binary (Apple Silicon + Intel). macOS 13 Ventura or later. Tested on macOS 15 Sequoia (Apple Silicon).

## Install

1. Download `FineDisplay-x.y.z.zip` from [nousworks.co/finedisplay](https://nousworks.co/finedisplay) or the GitHub releases page.
2. Unzip. Move `FineDisplay.app` to `/Applications`.
3. Open it. On first launch macOS may say it "cannot verify" the app: open **System Settings → Privacy & Security**, scroll down, click **Open Anyway**.
4. Click the monitor icon in the menu bar. Pick a HiDPI mode for your external display.

The app is signed with a Developer ID. It is not sandboxed because it talks to WindowServer directly.

## Command line

The CLI ships inside the app at `FineDisplay.app/Contents/Resources/bin/finedisplay` and as a separate zip.

```bash
finedisplay list              # displays and their modes; ★ = hidden HiDPI mode
finedisplay set 2 1920x1200   # "looks like 1920×1200", rendered at 3840×2400, saved
finedisplay set 2 2048x1280 --hz 60
finedisplay apply             # re-apply saved choices now
finedisplay saved
finedisplay forget 2
```

## How it works

Every display has a mode table inside WindowServer. For a 2560 × 1600 external panel, macOS
generates HiDPI modes such as `1920 × 1200 @2x` and `2048 × 1280 @2x`, but flags them
`kDisplayModeValidForMirroringFlag` (0x00200000) and never returns them from the public API.
System Settings therefore only lists modes whose backing store is at most the panel size.

FineDisplay reads the full table with `CGSGetDisplayModeDescriptionOfLength` and switches with
`CGSConfigureDisplayMode` — private SkyLight calls, resolved at run time with `dlsym`. WindowServer
accepts the switch, renders the desktop at 2× and lets the GPU downscale to the panel. Nothing else
in the system is touched.

The same mechanism is what Apple's own display override files use for the 13" MacBook Air
(`/System/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-610/DisplayProductID-a040`
lists 3840 × 2400 for a 2560 × 1600 panel).

Details and the investigation log: [docs/how-it-works.md](docs/how-it-works.md).

## Build from source

```bash
git clone https://github.com/ofbakirci/finedisplay
cd finedisplay
swift build -c release
.build/release/finedisplay list
scripts/build-app.sh                       # ad-hoc signed FineDisplay.app in dist/
SIGN_ID="Developer ID Application: …" scripts/build-app.sh
```

Requires Xcode 15+ / Swift 5.9+.

## Limits and honesty

- Uses private API. Apple can change it. The app checks that the symbols exist and refuses to run otherwise.
- Only modes WindowServer already generated can be enabled. If a display's table has no hidden HiDPI entries, FineDisplay cannot invent them (a virtual-display tool such as BetterDisplay can).
- Rendering at 4096 × 2560 costs GPU. Apple Silicon does not notice; older Intel GPUs might.
- Changing the mode in System Settings overrides FineDisplay until the next reconnect. Pick the mode in FineDisplay to make it stick.

## Credits

- Icons: [koboyo](https://koboyo.com) hand-drawn icons (`monitor`, `monitor-2`, `sparkles`) — free for commercial use.
- Mode-description struct layout follows [displayplacer](https://github.com/jakehilborn/displayplacer).

## License

MIT — see [LICENSE](LICENSE).
