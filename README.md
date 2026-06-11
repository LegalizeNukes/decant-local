# decant

**Decant** reverse-engineers Apple's "Liquid Glass" app icons (the iOS/macOS 26+ `.icon` format) back into an editable `.icon` bundle you can open in Icon Composer — pouring a sealed, compiled icon back out into editable source. It reads the *compiled* icon straight out of an installed iOS simulator runtime (or a mounted IPSW) using the private CoreUI framework, recovers every layer (vector SVG / raster PNG) and its full material treatment — blend mode, opacity, translucency, specular, shadow, blur, refraction, glass, per-appearance (light/dark/tinted) fills, layer transforms, and the canvas background — then reassembles a faithful `icon.json` + `Assets/` folder. Every export is verified by re-compiling it with `actool`.

It was built by reverse-engineering and then **round-trip–calibrated**: for each property the rebuilt icon is recompiled and re-extracted, and the values are diffed against Apple's original until they match exactly.

## Quick start

```sh
git clone https://github.com/kylebshr/decant
cd decant
./decant             # export ALL runtime icons → ./icons/
./decant --list      # list every extractable icon in your iOS runtime
./decant Maps        # just one → ./Maps.icon, then: open Maps.icon
```

The runtime location is discovered automatically — you only need an iOS 26+ simulator installed in the standard place (Xcode › Settings › Components). The extractor binary is compiled on first run.

## Simulator or IPSW?

By default decant reads icons out of your installed **iOS simulator runtime**, which is the easy path and all you need for the great majority of system apps (Maps, Photos, Safari, Settings, Weather, …). No download, no mounting.

But Apple *thins* a handful of apps out of the simulator — their icons simply aren't in the runtime. The notable ones are **App Store** and **Podcasts**, plus some others that ship only on device. For those, the icon lives in an **IPSW** (the device restore image) instead. Point decant at a mounted IPSW with `--root` to pull them — and in fact to export *everything* a real device ships, including apps the simulator omits.

So: reach for an IPSW when you want an app the simulator doesn't have (App Store, Podcasts, …) or a complete device-accurate set; otherwise the simulator path is simpler and faster.

### Extracting from an IPSW

Mount the IPSW's filesystem with [blacktop's `ipsw`](https://github.com/blacktop/ipsw) tool (`brew install blacktop/tap/ipsw`), which decrypts it and keeps it mounted while it runs:

```sh
ipsw mount fs MyDevice_27.0_Restore.ipsw      # prints a /tmp/NNN.dmg.mount path; leave running
```

Then in another shell, point decant at that mountpoint:

```sh
./decant --root /tmp/NNN.dmg.mount --list     # list every app in the image
./decant --root /tmp/NNN.dmg.mount AppStore   # one icon → ./AppStore.icon
./decant --root /tmp/NNN.dmg.mount            # export ALL → ./icons/
```

Press Ctrl-C on the `ipsw mount` when you're done to unmount. `--root` takes any mounted iOS filesystem; decant looks in `private/var/staged_system_apps`, `System/Applications`, and `Applications`.

## Usage

```
./decant                                # export ALL → ./icons
./decant --all [outdir]                 # export ALL → outdir
./decant --list                         # list available icons + stack names
./decant <AppName|path> [Stack] [out.icon] [--preview]
./decant --root <mountdir> …            # source from a mounted IPSW (see above)
```

`AppName` is a system app by name (`Maps`, `Photos`, `Safari`, `Settings`, …), resolved automatically inside the newest installed iOS simulator runtime; common friendly names are aliased to their real bundles (Safari→MobileSafari, Settings→Preferences, Messages→MobileSMS, Calendar→MobileCal, Wallet→Passbook), and `--list` shows the exact bundle names. Alternatively pass an explicit `Assets.car` / `.app` / `.framework` / `.bundle` path. `Stack` is the icon stack name (default `AppIcon`; Safari and Passwords use `AppIconUpdated`, Settings uses `Settings`). `out.icon` defaults to `./<name>.icon`. Add `--preview` to also write a flattened `<name>-preview.png` (off by default). `--root <dir>` sources icons from a mounted iOS filesystem (e.g. an IPSW mounted with `ipsw mount fs`) instead of the simulator runtime, and combines with `--list`, an `<AppName>`, or nothing (export all) — see [Simulator or IPSW?](#simulator-or-ipsw) above.

```sh
./decant Photos
./decant Safari AppIconUpdated
./decant Settings Settings ~/Desktop/Settings.icon --preview
./decant /path/to/Assets.car AppIcon ~/Desktop/My.icon   # explicit path
```

## Requirements

macOS with Xcode 26+ command-line tools (`clang`, `actool`, `assetutil`) and `python3`, plus an installed iOS 26+ simulator runtime. The extractor runs *inside* the simulator via `simctl spawn`, because iOS 26 added refraction and specular-placement to CoreUI's icon model and an older host CoreUI can't report those fields. Without an iOS 26+ runtime the tool falls back to host extraction and warns that refraction / specular-location may be missing. (The simulator is still needed even when sourcing from an IPSW with `--root` — the IPSW only supplies the compiled catalogs; the extraction itself runs in the simulator for full iOS 26 fidelity.) Extracting from an IPSW additionally needs [blacktop's `ipsw`](https://github.com/blacktop/ipsw) (`brew install blacktop/tap/ipsw`) to decrypt and mount it.

## Files

`decant` is the entry point: it discovers the runtime (or uses the `--root` mounted filesystem), resolves the app, extracts, assembles, and validates. `icon-extract.m` is the CoreUI-based extractor (built for the iOS simulator and run inside it) that writes `extracted.json` plus the layer assets. `build-icon.py` is the assembler that turns `extracted.json` + assets into `icon.json` + `Assets/`. Running `./decant` with no args generates every extractable icon into `icons/`, which is gitignored — regenerate anytime, and nothing of Apple's gets committed.

## How it works

It discovers the newest installed iOS simulator runtime root via `simctl`, opens the app's `Assets.car` with `CUICatalog`, and requests the icon stack per appearance (light / dark / tinted). It walks the `CUINamedIconLayerStack → CUINamedIconLayerGroup → layer` tree, reading each object's properties/ivars and saving each layer's artwork (`CGSVGDocument` → `.svg`, `CGImage` → `.png`). It then reassembles `icon.json`, mapping runtime enums back to the authoring vocabulary (calibrated against a known Icon Composer source): `blendMode` (CGBlendMode) → `normal`/`soft-light`/`hard-light`/`plus-lighter`/…, `shadowStyle` `0`→`none` and `3`→`neutral`, `specularPlacement` `1`→`inside` and `2`→`outside`, `refractionStrength`/`refractionHeight` → `refractivity.strength`/`depth`, per-layer `hasLightingEffects` → `glass`, the leading stack gradient → the canvas `fill`, and any per-appearance differences → `*-specializations`. Finally it validates by recompiling with `actool`.

## Fidelity

These are recovered exactly, each round-trip–verified against Apple's original: layer artwork (vector SVG / raster PNG), z-order, and layer transforms (`position` = scale + translation, for offset/overflowing layers); blend modes, opacity, glass, fills (solid / 2-stop gradient) and the resolved per-appearance colors; group material — blur, translucency, specular with inside/outside placement, shadow, lighting, and refractivity (strength + depth); the canvas background (the icon's authored leading stack gradient) per appearance as a solid, `automatic-gradient`, or 2-stop `linear-gradient`; and per-appearance everything — any layer or group property that differs across light/dark/tinted is emitted as `<key>-specializations` (e.g. Photos blends `multiply` in light, `hard-light` in dark, `plus-lighter` when tinted).

A few subtleties are handled explicitly. Z-order: the compiled stack stores groups *and* layers back-to-front while the `.icon` format lists them front-to-back, so both are reversed. Glass drives refraction: a group's refraction/specular only render on layers whose `glass` (= `hasLightingEffects`) is true. Artwork-colored layers: a layer with no light/dark fill uses its own SVG colors, and a tinted-only override is emitted *without* a base value so it doesn't recolor light/dark. Dropped layers: a layer that is `opacity 0` in the base appearance but visible in another (e.g. App Store's `1.light`) keeps its dark/tinted `opacity-specializations` so actool doesn't discard it.

Two things are inferred or lossy: `refractivity.enabled` is inferred from nonzero strength/depth (the compiler zeroes both when refraction is authored-but-disabled), and a `linear-gradient` must have exactly 2 stops, so a single stop becomes a `solid` and 3+ stops are approximated by first+last (rare).

## Limits & gotchas

The icon must actually be present in the source. Some apps are *thinned* in the simulator (no embedded icon) — notably App Store and Podcasts — so they can't be extracted from a simulator; mount an **IPSW** with `--root` to get them (see [Simulator or IPSW?](#simulator-or-ipsw)). There is also a hard limit of four visible groups: `actool` rejects app icons with more than four, yet Apple's own iCloud icon uses eight, since system icons skip the public validation that third-party developers are held to. decant still **exports** such icons (it's a valid editable bundle that opens in Icon Composer) but marks them *not validated by actool* (`⚠`) — so iCloud comes out, it just can't be recompiled as a standard third-party `.icon`. A `--list` may also show stack names other than `AppIcon` (e.g. Music's `AppIcon-iOS`); pass the right stack for those, since the all-export only tries the common `AppIcon`/`AppIconUpdated` names. Finally, the flattened `--preview` PNG is a plain composite; the live glass/refraction is applied by the on-device renderer, so open the bundle in Icon Composer (or on device) to see the real effect.

## Legal / scope

Uses Apple private frameworks (CoreUI, CoreSVG) for research and interop on your own machine. Don't ship the compiled binaries, and don't redistribute extracted Apple artwork — recreate your own.
