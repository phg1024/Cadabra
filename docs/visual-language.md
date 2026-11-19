# Visual language

How Cadabra looks, so every picture, icon and page reads as one family. The idea in one line: **your
voice, made into magic**. A sound wave goes in, something delightful comes out, on a pale stage that is the logo's own gradient, made big and soft.

![The palette, the mark and the illustrations](images/visual-language.png)

The same as a page: [visual-language.html](https://phg1024.github.io/Cadabra/visual-language.html).

## Colors

### Brand

| Name | Hex | Used for |
|---|---|---|
| Sky | `#47A3FB` | Top-left corner of the mark's tile |
| Indigo | `#546BFA` | Start of the brand gradient; middle of the mark's tile |
| Violet | `#9E52F2` | End of the brand gradient |
| Mark gradient | `#47A3FB → #546BFA → #9E52F2`, top-left to bottom-right | The app icon tile, the favicon, the site's logo glyph |
| Brand gradient | `#546BFA → #9E52F2`, top-left to bottom-right | Primary buttons, the headline accent |
| Accent | `#6A5CF5` | Links, focus rings, small UI accents on light backgrounds |
| Ink | `#17142B` | Text on light backgrounds |

### Illustration

| Name | Hex | Used for |
|---|---|---|
| Stage sky | `#D1E8FE` | Background, top-left corner of every illustration |
| Stage indigo | `#D4DAFE` | Background, the middle |
| Stage violet | `#E7D4FC` | Background, bottom-right corner |
| Clay purple | `#8B74E8` | The sound wave, and props that belong to Cadabra (keys, keyboards, windows) |
| Lilac | `#C9BCF5` | Secondary or faded parts: a noisy, misheard wave; shadows of purple things |
| Magic gold | `#F7C548` (edge `#E09A1F`) | Stars, sparkles, the corrected wave, the star on the wand |
| Wand black | `#2A2238` | The wand, the top hat, other dark objects |
| Cloud white | `#FFFFFF` | The bars in the icon, doves, cards, the robot's shell |

The stage is the mark's gradient made big and pale: the same three colors, each mixed with three
parts white, running diagonally from the top-left to the bottom-right.

A little of a natural color is fine where an object needs it (a yellow pencil, a pink eraser, a green
plant), never as a large area. No other background colors, no dark scenes.

### Site colors

The site's CSS variables follow the table: `--brand-1` indigo, `--brand-2` violet, `--brand` accent,
`--gold` `#E7A92A` (gold a little darker, so it reads as text on white). Dark mode keeps the same hues,
lighter: accent `#9B8CFF`, gold `#F5C451`.

## The mark

Six slim white sound bars of uneven height, the wave of the first Cadabra mark, centered; a straight
**Wand black** wand from the lower right, which may cross the bars a little, with a **Magic gold** star on its tip; a few gold stars and
dots around. On the **mark gradient** tile.

The same mark everywhere, at every size: the app icon, the menu bar, the mark inside the app, the
favicon and the site's nav. There is no simplified version (at menu-bar size the wand is kept at least
1.3 points wide so it still reads). The app icon, the menu bar and the Cadabra theme use the mark
gradient; inside the app, each of the other themes shows the same mark on its own accent colors.

The source of truth is code: `MagicMark` in `Sources/Cadabra/Components.swift` (`AppIconArt` renders
the app icon, `AppGlyph` the mark in the app and the menu bar). The site's SVGs copy its geometry.

## The recording bar

The bar at the bottom of the screen while you talk. In the Cadabra theme it follows the system:

- **Dark mode**: a dark bar (Ink at 92%), the live wave shading from Sky through Indigo to Violet bar by
  bar, white text, a gold star in place of the red dot.
- **Light mode**: the stage (the pale mark gradient) as the bar, a Clay purple wave, Ink text, the gold
  star.

The other themes keep their own bar. `Theme.forBar(dark:)` in `Sources/Cadabra/Theme.swift`.

## Illustrations

Blog thumbnails, the README banner, anything drawn rather than a screenshot.

- **Material**: soft 3D clay, matte with a gentle highlight, rounded edges. Nothing photographic,
  nothing glossy-plastic, no textures and no grain.
- **Light**: soft studio light from the upper left; soft contact shadows on the floor.
- **Stage**: the pale diagonal gradient above, smooth, sky blue at the top-left to violet at the bottom-right.
- **Story**: one idea per picture, read left to right. What you say comes in on the left (a **Clay
  purple** wave); what Cadabra makes of it comes out on the right (gold, white).
- **Never**: text or letters in the picture (models garble them), people or hands, logos of other
  products.
- **Connections are continuous**: where one thing flows into another (the wave into the wand, the
  light out of the key), they join with no gap, no kink and no offset.

### The elements

Reuse these instead of inventing new ones; when one appears in a new picture, give the model an
approved picture that has it as a reference ("the wave in image 2"), so it comes out the same.

| Element | How it looks |
|---|---|
| **The wave** (what you say) | A slim, smooth, matte clay tube in **Clay purple** `#8B74E8`, about 0.95% of the picture's width thick (12 px at 1280). Eight or nine waves, heights uneven like speech, as far below its center line as above. It runs left to right. |
| **The noisy wave** (what was misheard) | Dense, spiky, static-like noise in **Lilac** `#C9BCF5`, paler than the wave. |
| **The light** (what Cadabra makes of it) | A glowing line of light: a pale, almost white core inside a soft **Magic gold** glow. Never a solid gold tube. It starts exactly where the input arrives (on the key, at the end of the wave) and ends where it goes (the robot, the pencil's tip). |
| **The wand** | A perfectly straight, rigid **Wand black** rod with a white tip, never bent. The wave flows into its back end; its tip points into the hat. |
| **The top hat** | **Wand black**, with a **Violet** band. Out of it come gold clay stars and white doves. |
| **The pencil** | An ordinary yellow wooden pencil with a pink eraser. No face, no arms, no legs. |
| **The keyboard** | A whole compact keyboard: a clay purple body, pale keys. The agent key is one key glowing gold with a small white star on it, never one giant key. |
| **The robot** | White, a dark visor face, cyan eyes, pink cheeks, in a white app window with a purple title bar. |
| **Doves and stars** | White clay doves with spread wings; plump gold clay stars and small sparkles. |

### Sizes

| Asset | Generated at | Published as |
|---|---|---|
| Blog thumbnail | 1280×800 (16:10) | `docs/images/blog/<name>.jpg`, 960×600, JPEG quality 88, 4:4:4 |
| README banner, social preview | 1280×640 (2:1) | `docs/images/banner.jpg`, JPEG quality 90, 4:4:4 |
| App icon | Rendered from code | `build.sh` makes the `.icns` |
| Screenshots | The real app, light appearance | PNG in `docs/images/`, `-en` and `-zh` versions |

### Prompt

The thumbnails and the banner were made with a local image model (Qwen-Image). Start every prompt with
the style, then the scene:

> Cute 3D clay render, transparent background. Soft studio light from the upper left, soft contact shadows.
> Colors: clay purple #8B74E8 for the sound wave and props, lilac #C9BCF5 for faded parts, white, wand
> black #2A2238 for dark objects, magic gold #F7C548 for stars and sparkles. No text, no letters, no
> people, no hands.
>
> Scene: …

**The model can't hit exact colors** (it ignores hex codes and paints its own idea of "sky blue"), so the
stage is never left to it. Ask for the objects only, with `--background transparent`, and put them on
the stage with `tools/stage.py cut.png out.png`: it takes the stage from the master plates, adds a soft
violet shadow under the objects, and dithers the stage when it goes down to 8 bits so it doesn't show bands.

The master plates are in `docs/images/stage/`: `stage-16x10.png` and `stage-2x1.png`, 16 bits per
channel, so they have no steps; use them for anything else that sits on the stage (slides, mockups).
`tools/stage.py --plates` makes them again if the colors change. Save JPEGs with
`subsampling=0` (4:4:4) for the same reason.

**Redraw, don't patch.** To change a picture, draw the whole picture again, with the approved pictures
as references for the composition and for each element, rather than editing a part of it: edits drift
(a wave that should rise from a key comes from the middle of the keyboard) and editing the same picture
over and over adds grain.

**Check it, don't eyeball it.** After drawing, measure the wave's thickness and color against the
table above. `tools/clay_purple.py cut.png out.png` brings the wave in a cutout to exactly Clay purple,
keeping its shading.

## On the site

- The hero and the blog's header sit on the stage gradient, fading out downwards; alternate sections
  on a paler version of it.
- The headline's gradient words use the mark gradient.
- The blog cards show the picture at 16:10 next to the summary; keep each summary short enough (about
  60 Chinese characters, 160 English) that the card is no taller than the picture.
- The favicon and the nav glyph are the mark; the menu bar shows it in color.
