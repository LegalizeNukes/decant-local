# decant-local

Extracts an installed macOS app's layered icon and rebuilds it as an editable
`.icon` bundle for Apple Icon Composer. It supports icons compiled for both
macOS 26 and macOS 27.

The finished icon is saved directly to:

```text
~/Downloads/App Name.icon
```

## Requirements

- macOS 26 or 27
- Python 3
- Apple Command Line Tools (`xcode-select --install`)
- Icon Composer, if you want to open or edit the result

Full Xcode, an iOS Simulator, and IPSW downloads are not required.

## Setup

Download or clone the repository, then make the three scripts executable:

```zsh
cd /path/to/decant-local
chmod +x decant build-icon.py decant-rawsvg-overlay.zsh
```

## Terminal usage

Pass an installed app to `decant`:

```zsh
./decant "/Applications/Example.app"
```

The main icon stack is selected automatically and the result is written to
`~/Downloads/Example.icon`.

## Shortcut usage

The repository includes `Extract Icon.shortcut`, a Finder Quick Action for
passing `.app` bundles to Decant.

1. Keep the repository at `~/Documents/Terminal/Decant`.
2. Double-click `Extract Icon.shortcut` and add it to Shortcuts.
3. In Finder, right-click an app and select **Quick Actions > Extract Icon**.

## macOS 26 and 27

Format detection is automatic. Decant preserves macOS 26 `system-light` fills
and macOS 27 appearance fills, group transforms, refractivity, specular
placement, and newer vector rendition formats.

For an unusually simple icon that contains no version-specific metadata, you
can force the output format:

```zsh
DECANT_FORMAT=26 ./decant "/Applications/Example.app"
DECANT_FORMAT=27 ./decant "/Applications/Example.app"
```

## Notes

- Existing output with the same name is replaced.
- Original SVG rendition data is preferred when available.
- Decant uses private Apple CoreUI/CoreSVG behavior, so inspect the result in
  Icon Composer after extraction.
- Only extract or redistribute artwork you have permission to use.
