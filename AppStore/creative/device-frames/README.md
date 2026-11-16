# Official Apple device frames

The marketing renderer uses Apple's unmodified Silver portrait device bezels,
scaled proportionally, upright and fully visible. They are licensed Apple
Design Resources, not covered by this repository's MIT license. Standalone
Apple PNGs are intentionally ignored by Git.

Download the Photoshop/PNG packages from
https://developer.apple.com/design/resources/#product-bezels and accept Apple's
Design Resources license. Copy these PNGs into this directory:

- `Bezel-iPhone-18.dmg` → `PNG/iPhone 18 Pro/iPhone 18 Pro - Silver - Portrait.png`
  as `iphone-18-pro-silver.png` (1350 × 2760).
- `Bezel-iPad-Pro-(M5).dmg` → `PNG/iPad Pro (M5) 13" - Silver - Portrait.png`
  as `ipad-pro-m5-silver.png` (2300 × 3000).

The screenshot display openings are 1206 × 2622 at (72, 69) for iPhone and
2064 × 2752 at (118, 124) for iPad. The renderer embeds actual app captures
beneath these frames. Do not alter the frames or add shadows to them.

Run from the repository root:

```sh
swift Tools/store-assets/render.swift
```
