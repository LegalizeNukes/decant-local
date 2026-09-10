# decant-local

Decant recovers editable layered `.icon` documents from compiled macOS app
icons. This version is a single self-contained script targeting macOS 26 and
27; no companion scripts need to be installed beside it.

## Requirements

- macOS 26 or 27
- Xcode Command Line Tools (`clang` and `xcrun assetutil`)
- Python 3

Decant reads private CoreUI objects, so a later macOS release may require new
compatibility work.

## Install

Download `decant`, then make it executable:

```zsh
chmod +x decant
```

## Usage

Pass either an app bundle or an `Assets.car` file:

```zsh
./decant "/Applications/Pages.app"
./decant "/path/to/Assets.car"
```

The resulting bundle is written to `~/Downloads/<App Name>.icon`.

## Diagnostics

Keep the complete work directory, including `extracted.json`, the
reconstruction report, recovered assets, and generated helper sources:

```zsh
DECANT_KEEP_WORK=1 ./decant "/Applications/Pages.app"
```

Require a clean coverage report:

```zsh
DECANT_STRICT=1 ./decant "/Applications/Pages.app"
```

Strict mode still writes the recovered icon but returns status `3` when a
fidelity warning remains.

Override automatic Icon Composer schema selection only when necessary:

```zsh
DECANT_FORMAT=26 ./decant "/path/to/App.app"
DECANT_FORMAT=27 ./decant "/path/to/App.app"
```

## What it preserves

- Group and layer structure and ordering
- Original SVG rendition data when CoreUI exposes it
- PNG layers and distinct light, dark, and tinted artwork
- Both `NSAppearance…` and `UIAppearance…` lookup families
- Canvas and layer fills, color spaces, gradients, opacity, and blend modes
- Placement, visibility, glass, lighting, translucency, blur, and shadows
- macOS 27 refractivity and specular-location metadata
- Semantic System Light and System Dark backgrounds

When original SVG bytes are unavailable, Decant uses CoreSVG's regenerated
representation and records that limitation in its reconstruction report.

An `Assets.car` is compiled output, so some authoring-only information may no
longer exist. Decant reports recoverable fidelity gaps instead of silently
claiming a lossless result.
