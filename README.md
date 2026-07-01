# decant-local

## Purpose

`decant-local` extracts the main macOS Liquid Glass application icon from an installed `.app` bundle and rebuilds it as an editable `.icon` bundle that can be opened in Apple's Icon Composer.

This project is intended for local inspection, preservation, and icon editing workflows on your own Mac. It is a local-first adaptation of the original `decant` idea: instead of relying on simulator or IPSW assets, it reads the installed app's local `Assets.car`, extracts the main icon stack, rebuilds the icon structure, and writes the final `.icon` directly to `~/Downloads`.

The default behavior is intentionally narrow:

- Extract one main app icon.
- Write one final `.icon` file.
- Do not export every random icon stack in the asset catalog.
- Do not place the final output inside a folder.
- Prefer original raw SVG data when available, so complex vector layers survive better.

## Quick Start

Put the project files in a folder, for example:

```zsh
/Users/yourname/Documents/Decant
```

Make the scripts executable:

```zsh
cd "/Users/yourname/Documents/Decant"
chmod +x decant decant-rawsvg-overlay.zsh
```

Run it on an installed app:

```zsh
./decant "/Applications/Pixelmator Pro Creator Studio.app"
```

The output is written directly to Downloads:

```text
~/Downloads/Pixelmator Pro Creator Studio.icon
```

Open the result:

```zsh
open "$HOME/Downloads/Pixelmator Pro Creator Studio.icon"
```

For a macOS Shortcut that receives an app as input, use:

```zsh
cd "/Users/yourname/Documents/Decant"
zsh ./decant "$1"
```

## Usage

Basic usage:

```zsh
./decant "/Applications/App Name.app"
```

Output naming:

```text
/Users/yourname/Downloads/App Name.icon
```

The app name is taken from the `.app` bundle name. For example:

```zsh
./decant "/System/Applications/Calendar.app"
```

creates:

```text
~/Downloads/Calendar.icon
```

The script automatically tries to identify the main app icon stack. In normal modern app bundles this is usually `AppIcon`, but some apps use a custom icon stack name. `decant-local` checks the app's asset catalog metadata and uses the most likely main icon stack.

The extraction flow is:

```text
.app bundle
  -> Contents/Resources/Assets.car
  -> main icon stack
  -> normal CoreUI extraction
  -> raw SVG overlay pass
  -> editable .icon bundle in Downloads
```

The raw SVG overlay pass is always part of the main workflow. It exists because some advanced SVG layers are damaged when exported through CoreSVG's regenerated SVG path. When original SVG bytes are available in the private rendition data, `decant-local` overlays those original SVG files onto the normal extraction before building the final `.icon`.

## Requirements

`decant-local` is designed for macOS and expects Apple's local icon/rendering frameworks to be present.

Required:

- macOS with Liquid Glass `.icon` / Icon Composer-era icon support.
- Apple Command Line Tools.
- `clang`.
- `python3`.
- `xcrun assetutil`.
- Local read access to the target app's `.app` bundle.
- The project files:
  - `decant`
  - `build-icon.py`
  - `icon-extract.m`
  - `decant-rawsvg-overlay.zsh`

Recommended:

- Apple's Icon Composer app to open and inspect the resulting `.icon` bundle.
- Running from Terminal or a macOS Shortcut that passes the `.app` path as an argument.

Not required:

- Full Xcode installation, for the basic extraction path.
- iOS Simulator runtime.
- IPSW downloads.
- `actool` validation.

## What Changed

Compared with the original broader Decant-style workflow, `decant-local` is simplified and focused on local main-app-icon extraction.

Changed behavior:

- Removed the default emphasis on exporting every icon stack.
- Removed the normal need to pass a stack name manually.
- Removed the final output folder behavior for normal use.
- Final output is always a single `.icon` bundle in `~/Downloads`.
- Main icon stack detection is automatic.
- Raw SVG overlay is part of the default extraction path.
- Existing output `.icon` bundles are cleared before rebuilding, avoiding stale asset files.
- The workflow is designed around installed macOS apps, not simulator/IPSW asset sources.

Raw SVG overlay change:

Some apps include advanced vector layers where CoreSVG's `CGSVGDocumentWriteToURL` export can produce incomplete SVGs. In affected icons, the exported SVG may reference clip paths but omit the actual `<clipPath>` definitions, causing visible rectangles, broken masks, or incorrect layer rendering in Icon Composer.

`decant-local` handles this by doing a second local pass over the same icon stack and extracting original SVG bytes from `_CUIThemeSVGRendition.rawData` when available. Those original SVG files are then overlaid onto the normal extraction before `build-icon.py` creates the final `.icon` bundle.

This keeps the icon layered and editable. It does not flatten the icon, delete layers, or convert SVG layers to PNG as a workaround.

## Legal and Practice Notes

Use this for local inspection and personal editing of app resources already on your Mac. Do not redistribute extracted artwork unless you have the rights to do so.

This relies on private Apple CoreUI/CoreSVG behavior, so output may vary by macOS version. Always inspect the resulting `.icon` in Icon Composer.
