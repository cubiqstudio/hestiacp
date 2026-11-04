# VylarisSpace

Private fork of [HestiaCP](https://github.com/hestiacp/hestiacp) by VylarisGroupEurope.

## License

HestiaCP is licensed under **GPL-3.0-or-later**. This fork stays under the same license.

- The `LICENSE` file and the copyright notices of the original authors stay in place.
- Own changes are also released under GPL-3.0-or-later.
- The source code has to be made available only if the fork (or a build of it) is passed on to third parties. Private use on your own servers does not require publication.
- Naming: the product is shown as "VylarisSpace". "Hestia" and its logo are not used in the UI of this fork. Mentions in source code, license headers and credits remain.

## Phase 0 decisions

| Topic         | Decision                                                            |
| ------------- | ------------------------------------------------------------------- |
| Product name  | VylarisSpace                                                        |
| Themes        | `vylaris` (light) and `vylaris-dark` (dark)                         |
| Base approach | Theme override on top of `default.css`, no edits to upstream themes |
| Fonts         | Self-hosted only (no external CDNs, GDPR friendly)                  |
| Accessibility | WCAG 2.2 AA contrast for text and UI components                     |

## Logos

Source files live in `web/images/vylaris/` (trimmed, transparent PNG).

| File                     | Content                                   | Use on            |
| ------------------------ | ----------------------------------------- | ----------------- |
| `logo-full-on-light.png` | Mark + "Vylaris Group Europe", black text | light backgrounds |
| `logo-full-on-dark.png`  | Same, white text                          | dark backgrounds  |
| `logo-mark-on-light.png` | Mark only, black part                     | light backgrounds |
| `logo-mark-on-dark.png`  | Mark only, white part                     | dark backgrounds  |

The supplied files named "Dark" contain black parts and are therefore meant for light backgrounds. The files named "Light" contain white parts and are meant for dark backgrounds. They are mapped by content, not by file name.

## Brand colors (sampled from the logo)

| Token       | Value     | Origin                                     |
| ----------- | --------- | ------------------------------------------ |
| `brand-300` | `#3e9afa` | top of the V gradient                      |
| `brand-400` | `#3792f7` | V gradient / "Group"                       |
| `brand-500` | `#2679f5` | V gradient (main brand blue)               |
| `brand-600` | `#1f64e0` | interactive blue (buttons, links on light) |
| `brand-700` | `#0e52d1` | "Europe"                                   |
| `brand-800` | `#0a49c1` | "Europe" (dark end)                        |
| `ink`       | `#000000` | wordmark                                   |

`brand-500` is the pure logo blue. White text on it only reaches 4.09:1, so filled buttons use `brand-600` (5.31:1).

## Semantic palette

| Role                            | Light theme | Dark theme |
| ------------------------------- | ----------- | ---------- |
| Background                      | `#f6f8fb`   | `#0b0e14`  |
| Surface                         | `#ffffff`   | `#121722`  |
| Surface raised                  | `#ffffff`   | `#181f2c`  |
| Border                          | `#e3e8ef`   | `#232c3c`  |
| Text                            | `#1b2433`   | `#e6eaf2`  |
| Text muted                      | `#5b6678`   | `#98a2b5`  |
| Primary                         | `#1f64e0`   | `#3792f7`  |
| Primary on dark surface (links) | n/a         | `#5aa9fa`  |
| Success                         | `#15803d`   | `#34d399`  |
| Warning                         | `#b45309`   | `#fbbf24`  |
| Danger                          | `#b91c1c`   | `#f87171`  |
| Info                            | `#1f64e0`   | `#5aa9fa`  |

Measured contrast (WCAG): text on background 15.6:1 (light) and 16.0:1 (dark); muted text 5.5:1 and 7.0:1; primary link on dark 6.1:1 to 7.3:1; white on `brand-600` 5.3:1.

## Architecture of the themes

- `default.css` is always loaded first, a theme file is loaded on top (`web/templates/includes/css.php`).
- `web/css/src/themes/*.css` is built to `web/css/themes/*.min.css` by `npm run build`.
- Shared Vylaris code lives in the subfolder `web/css/src/themes/vylaris/` (not built as an entry on its own) and is imported by `vylaris.css` and `vylaris-dark.css`.
