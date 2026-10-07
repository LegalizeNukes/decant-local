# Decant Local

**Recover layered, editable macOS Liquid Glass app icons directly from local asset catalogs.**

Decant Local is a local-first fork of [Decant](https://github.com/kylebshr/decant). Its main executable, **Decant 4**, extracts a macOS application's icon stack from `Assets.car` and reconstructs an `.icon` bundle for Apple's Icon Composer. It is intended for inspecting, preserving, and editing icons already installed on your Mac—without downloading an IPSW or installing a simulator runtime.

Unlike a flattened PNG export, the reconstruction aims to retain the icon's layer/group hierarchy, original SVG artwork when available, raster layers, appearance variants, and supported visual-effect metadata. **The result is editable, but exact fidelity is not guaranteed:** private CoreUI data is not always fully representable in an `.icon` document.

## Features

- **Single-file command:** `decant` includes its Objective-C extraction tools and Python icon builder, which are unpacked into a temporary directory at runtime. The other source files in the repository are not required for normal use.
- **Local inputs:** accepts an installed `.app` bundle or a direct path to an `Assets.car` file.
- **Automatic stack selection:** prefers the app's `CFBundleIconName`, then known icon-stack names, falling back to the first detected icon stack.
- **Editable output:** rebuilds the icon's layers, groups, supported effects, and light/dark/tinted appearance data instead of merely exporting a composite image.
- **Original SVG recovery:** makes a second pass to recover raw SVG rendition data when available, avoiding some errors introduced by regenerated SVGs, including missing clipping definitions.
- **macOS 26/27 schemas:** automatically determines the target `.icon` schema from available metadata, with a manual override when needed.
- **Fidelity reporting:** detects reconstruction uncertainties and provides optional retained work files, strict validation, and downloadable diagnostics.
- **Predictable output:** writes a single `.icon` bundle directly to `~/Downloads`, replacing an existing output with the same name.

## Requirements

- macOS with the relevant Liquid Glass icon and Icon Composer support (targeting the macOS 26 and 27 `.icon` formats).
- Apple's command-line developer tools, providing `clang` and `xcrun` (`xcrun assetutil` must be available).
- `python3` available on `PATH`.
- Read access to the app bundle or asset catalog being inspected.
- **Icon Composer** to open and edit the resulting `.icon` bundle.

The `decant` script compiles temporary extraction binaries using Apple's local frameworks. It does not require separate Python packages, the other repository source files, simulator downloads, or an IPSW for the normal workflow. The extraction relies on private CoreUI/CoreSVG behavior, so compatibility can vary across macOS releases.

## Installation

Download or clone this repository, then make the main script executable:

```sh
git clone https://github.com/LegalizeNukes/decant-local.git
cd decant-local
chmod +x decant
```

You only need the **`decant`** file to run the current standalone version. Keep the remaining repository files if you want to inspect or develop the constituent extraction/building code.

## Usage

Pass **one** installed application bundle:

```sh
./decant "/System/Applications/Calendar.app"
```

Or pass an asset catalog directly:

```sh
./decant "/path/to/Assets.car"
```

The result is saved as:

```text
~/Downloads/Calendar.icon
```

For a direct `Assets.car` input, the output is named after that file's basename (for example, `Assets.icon`). The output is an `.icon` **bundle**, not a PNG or ICNS file. Open it in Icon Composer to inspect and modify its layers and appearance variations.

The script displays extraction stages and the detected app name, icon stack, and output path. An existing output bundle with the same name is replaced when the new bundle has been built.

### Options and diagnostics

The script accepts these environment variables:

| Variable | Purpose |
| --- | --- |
| `DECANT_FORMAT=26` | Force the macOS 26 / Icon Composer v1 output schema. |
| `DECANT_FORMAT=27` | Force the macOS 27 / Icon Composer v2 output schema. |
| `DECANT_KEEP_WORK=1` | Preserve the temporary extraction/build directory and print its path. |
| `DECANT_DIAGNOSTICS=1` | Copy the extracted assets, metadata, reports, and raw-SVG pass into `~/Downloads/<Name> Decant Diagnostics/`. |
| `DECANT_STRICT=1` | Return a nonzero status (3) when fidelity warnings remain, rather than treating a possibly incomplete reconstruction as fully successful. |

Examples:

```sh
DECANT_DIAGNOSTICS=1 ./decant "/Applications/Example.app"
```

```sh
DECANT_FORMAT=27 DECANT_STRICT=1 ./decant "/Applications/Example.app"
```

The default format setting is automatic. Override it only when the detected schema is unsuitable, such as for an icon whose metadata does not clearly identify a version.

For command syntax or version information:

```sh
./decant --help
./decant --version
```

### macOS Shortcuts

A Shortcut that passes a selected `.app` path as its input can invoke the script through **Run Shell Script**. For example, with input passed as arguments:

```sh
"/path/to/decant-local/decant" "$1"
```

Use the actual full path to `decant` on your Mac. The Shortcut should pass a filesystem path to one `.app` or `Assets.car`; it should not pass a display name alone.

## How it works

1. **Inspect:** use `xcrun assetutil --info` to discover icon image stacks inside the local `Assets.car`.
2. **Select:** choose the likely main stack using bundle metadata and fallback names.
3. **Extract:** compile and run embedded Objective-C tools to recover the stack's layers, metadata, and usable image assets.
4. **Recover SVGs:** separately inspect rendition data for original SVG bytes and prefer those where available.
5. **Rebuild:** assemble `icon.json` and the asset hierarchy into an editable macOS 26/27 `.icon` bundle, recording reconstruction limitations.
6. **Deliver:** move the bundle into `~/Downloads` and delete temporary files unless diagnostic retention is enabled.

The reconstruction handles supported properties such as opacity, blend modes, shadows, translucency, specular effects, blur, color/fill data, and appearance-specific assets where these can be translated from the source catalog. It does **not** promise that every CoreUI effect or future private metadata field has a lossless representation in Icon Composer.

## Limitations

- **Not a generic icon converter.** The input must contain a suitable `IconImageStack` in an Apple asset catalog. Ordinary PNG, SVG, or ICNS files are not accepted directly.
- **Main stack only.** The default command reconstructs one selected icon stack, not every stack in the catalog. The selected stack is printed so you can verify it.
- **Private APIs.** Apple may change rendition structures, metadata, or Icon Composer's document schema between OS releases.
- **Best-effort fidelity.** Some effects, geometry, masks, or properties can remain imperfect or unsupported. Inspect the resulting bundle in Icon Composer, and use strict mode and diagnostics if fidelity matters.
- **Existing filenames are overwritten.** Move or rename a prior output if you need to preserve it before another extraction.

## Troubleshooting

**`Assets.car not found`** — The specified app may not store its catalog at `Contents/Resources/Assets.car`; check that path or supply an existing catalog directly.

**`no IconImageStack found`** — The catalog does not contain a recognized layered icon stack. Traditional icons and unrelated catalog assets cannot be reconstructed with this tool.

**`required command not found`** — Install Apple's command-line developer tools or make sure `clang`, `python3`, and `xcrun` are on `PATH`.

**Missing layers or incorrect effects** — Retry with `DECANT_DIAGNOSTICS=1` to retain extracted metadata and source assets. Try `DECANT_FORMAT=26` or `DECANT_FORMAT=27` if automatic schema selection is ambiguous; forcing the wrong schema will not repair missing source information.

**Need to inspect intermediate files** — Use `DECANT_KEEP_WORK=1` and look at the printed temporary directory. The normal run deletes that directory automatically.

## Credits and usage

Based on [kylebshr/decant](https://github.com/kylebshr/decant), adapted for local macOS application icon extraction and reconstruction.

Use the tool to inspect or edit app resources you are permitted to access. Extracted artwork remains subject to its original owner's rights; do not redistribute it without authorization.
