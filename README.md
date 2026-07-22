# cappan

**cappan** (活版) is a font rendering engine implemented in pure Zig. It provides library and tools.

<https://heriet.github.io/cappan/>

![medial-axis writing-order weighted](cappan_doc/content/guide/image/incremental-rendering/medial_axis_writing_weighted.png)

[Demo on browser](https://heriet.github.io/cappan/demo/)

- Most of this project was built with AI
- This is a personal learning and experimentation project — expect breaking changes. Not recommended for production use

## Features

CLI subcommands:

- `render` — render text to a single PNG image
- `animate` — render text as incremental animation (APNG or frame sequence), one character at a time
- `fonts` — list system fonts
- `subset` — subset a font to include only glyphs for given text
- `inspect` — inspect font metadata, validate tables, show coverage
- `svg` — convert text to an SVG file with vector paths
- `metrics` — show CSS font metrics and compare fonts
- `atlas` — generate an SDF/MSDF glyph atlas (PNG pages + metrics JSON)

Rendering:

- Default rasterizer is **analytical** (exact area coverage, not supersampling)
- **SDF / MSDF** signed-distance-field rendering and glyph **atlas** generation
- **Vertical** (vertical-rl) text layout
- **COLR v0 and v1** color glyphs
- **Variable fonts** (fvar/gvar/avar axes)
- **WOFF** and **WOFF2** containers
- **Stroke and fill** paint (multi-layer strokes, opacity, joins)
- **Arabic** (and other GSUB/GPOS-shaped scripts) contextual shaping
