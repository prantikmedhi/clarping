# Clarping brand assets

Clarping = larp + clauding: one Mac, several Claude identities, switched from the menu bar.
The mark has to say "a Claude-ish spark" and "two identities" at once, stay warm and cozy,
and still read at 16 px in Finder and 18 pt in the menu bar.

## Files

| File | What it is |
|---|---|
| `icon-1024.png` | Final app icon, 1024 x 1024, macOS grid: 824 px squircle body centred with a 100 px margin, baked-in drop shadow, transparent outside the tile. |
| `icon-1024.svg` | Source the PNG is rendered from (Chrome headless). Edit this if you want to tweak colours or lighting. |
| `menubar-glyph.svg` | Monochrome template glyph, 18 x 18 pt viewBox, one `<path>`, black on transparent. |
| `menubar-glyph.pdf` | Same path as a vector PDF (18 x 18 pt MediaBox), for an asset catalog with "Render As: Template Image". |
| `concept-orbit.png` | Alternate concept B. |
| `concept-masquerade.png` | Alternate concept C. |
| `concept-twin-glass.png` | Alternate concept D (GPT image render). |

## Recommended: Split Spark (`icon-1024.png`)

A chubby four-point spark with rounded tips, divided by one soft S-shaped cut into two halves:
clay on top, deeper terracotta below. It is still one spark at a glance (and the same
silhouette the menu bar already uses), but the S-cut says two identities sharing one seat,
and the curve gives a little sense of rotation, of one half handing over to the other.
The cut is a gentle S rather than a straight slash, so it reads as "two" and never as
"broken".

Why this one:

- **Small sizes.** The silhouette is a single compact shape. At 16 px it is a clean
  two-tone spark; from 32 px the split is visible. The template glyph keeps a 1.35 pt gap,
  so the split survives in the menu bar.
- **One mark everywhere.** The app icon and the menu bar glyph share the same geometry.
  The other concepts need a different simplification for the menu bar.
- **Original.** Four rounded, pillowy points with a full body. It is not the many-rayed
  Claude/Anthropic starburst and not the thin, sharp-tipped "AI sparkle". The S-split is the
  distinctive part.
- **Cozy and professional.** Cream tile, clay glaze, one soft light from the top left,
  Liquid Glass rim light on the tile and the pieces, no gimmicks.

## Alternates

**B. Orbit (`concept-orbit.png`).** A smaller clay spark circled by two tapered swooshes,
one cream and one clay, chasing each other around it: two accounts taking turns, and a nod
to the usage ring the menu bar draws around the spark. On a warm charcoal tile it is the
most "pro tool" of the set and stands out in a light Dock. It is the busiest at 16 px, and
the arcs can read as a generic refresh icon.

**C. Masquerade (`concept-masquerade.png`).** A cream spark wearing a charcoal domino mask
on a clay tile: the "larp" in Clarping, said literally. The most playful and memorable,
but the mask turns into a dark bar below 32 px, and it leans more toward a joke than a
utility.

**D. Twin Glass (`concept-twin-glass.png`).** Two sparks overlapping on the diagonal: a
solid terracotta one behind, a frosted clay-tinted glass one in front, with the overlap
showing through. The most literal "two identities" and the most Liquid Glass of the set.
At small sizes the two shapes merge into one blob with a lighter corner.

## Palette

| Role | Hex |
|---|---|
| Cream (brand) | `#F5F0E8` |
| Clay (brand) | `#D97757` |
| Terracotta (brand) | `#C96442` |
| Deep terracotta (lower half, flat) | `#A9502F` |
| Warm charcoal | `#2C2521` (light `#4A3F39`) |
| Icon tile gradient, cream | `#FCF9F3` to `#EDE3D4` |
| Upper half gradient | `#E58E6C` to `#CF6A47` |
| Lower half gradient | `#BE5B3A` to `#9C4528` |
| Contact shadow tint | `#5A3A26` |
| Charcoal tile (concept B) | `#423833` to `#25201D` |
| Clay tile (concept C) | `#E28A69` to `#C25D3C` |

## Geometry

All marks are built from explicit Bezier geometry, not traced from generated images.

- Spark: tip radius R; each tip is a circular arc of radius 0.12 R; edges leave the tip at
  15 degrees off-axis with handles 0.46 R long. The waist is about 0.55 R.
- Split: one cubic S through the centre along the NW to SE diagonal (half-length 0.8 R,
  bend 0.5 R), cut 0.08 R wide in the icon and 0.16 R in the glyph, cut corners rounded
  at 0.03 R (icon) and 0.05 R (glyph).
- Icon: R = 285 px in the 1024 canvas (the mark spans about 69 % of the tile). The tile is a
  superellipse (n = 5) approximating Apple's continuous-corner shape.
- Glyph: R = 8.4 pt in an 18 pt box.

## How it was made

1. **Research (pinmuse).** Pinterest moodboards for `liquid glass app icon` and
   `terracotta minimal logo mark`. What carried over: a thick tile with a bright top rim
   and short soft shadow; one glossy object per icon; tone-on-tone clay; interlocking
   two-part marks; restraint (the rainbow "glass" packs were what to avoid).
2. **Image model.** pinmuse has no image provider configured on this machine (no
   `OPENAI_API_KEY` and so on), so per the pinmuse skill's fallback, GPT image generation
   ran through the Codex CLI's built-in image tool (ChatGPT sign-in, no API key handled).
   Two renders were made, each with a flat render of the vector mark attached as a shape
   reference. The Twin Glass render is `concept-twin-glass.png` (resized from 1254 to 1024 px;
   it has an opaque background). The Split Spark render was only a material study. Its cut
   came out straighter, its tips changed shape, and it has an opaque background and a thick 3D
   slab, so the shipped icon is the vector render instead. That render matches the menu bar
   glyph exactly and sits on the macOS grid.
3. **Vectors.** Every mark is explicit geometry written in Python (skia-pathops for
   the boolean cuts), rendered with Chrome headless, and checked at 1024, 128, 64, 32 and
   16 px on light and dark backgrounds. The menu bar glyph PDF is written by a small
   CoreGraphics script from the same path.

### Generation prompts

Pinterest research (pinmuse): `pinmuse moodboard "liquid glass app icon" -n 24` and
`pinmuse moodboard "terracotta minimal logo mark" -n 24`.

Image model: GPT image generation through `codex exec` (model `gpt-5.6-terra`, OpenAI provider),
with the flat vector render attached via `-i`.

Split Spark material study (reference: flat render of the vector mark):

```text
macOS app icon, Apple macOS 26 Tahoe "Liquid Glass" style, square 1024x1024 canvas with a transparent-looking plain very light warm-grey background. One rounded-square squircle tile (continuous corners) occupying the central 80% of the canvas, warm cream (#F5F0E8) with a faint top-to-bottom gradient, a crisp bright specular rim along its top edge and a soft, short drop shadow beneath it.
Centred on the tile: the exact mark from the attached reference image, kept faithful in silhouette and proportions: a chubby four-pointed spark with rounded tips, divided by one gentle S-shaped cream gap into two halves; upper-right half clay orange (#D97757), lower-left half deeper terracotta (#A9502F). Render the two halves as thick, softly glossy glass-ceramic pieces: subtle inner rim light on their top edges, gentle body gradient, a soft contact shadow on the tile. Restrained and premium, like a first-party Apple icon. Mark spans about 60% of the tile.
No text, no letters, no emoji, no extra objects, no rainbow or iridescent colours, no sparkles or particles, no background scenery.
```

Twin Glass (reference: the vector render of concept D; output is `concept-twin-glass.png`):

```text
macOS app icon, Apple macOS 26 Tahoe "Liquid Glass" style, square 1024x1024, plain very light warm-grey background. One rounded-square squircle tile (continuous corners) occupying the central 80% of the canvas, warm cream (#F5F0E8) with a faint gradient, bright specular rim along its top edge, short soft drop shadow.
On the tile, faithful to the attached reference's layout: two chubby four-pointed sparks with rounded tips, overlapping diagonally. The back spark (lower right) is solid deep terracotta (#A9502F) glazed ceramic. The front spark (upper left) is a thick piece of frosted, slightly clay-tinted Liquid Glass: translucent, refracting and softening the terracotta spark where they overlap, with a crisp bright specular edge along its upper rim. Restrained, premium, first-party Apple quality, mark spans about 60% of the tile.
No text, no letters, no emoji, no extra objects, no rainbow or iridescent colours, no sparkles or particles, no scenery.
```

