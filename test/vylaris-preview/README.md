# Vylaris preview and screenshot harness

Renders the real Hestia templates (`web/templates/**`) without a Hestia backend and takes
screenshots of them with Playwright, so theme work can be verified visually.

```text
pages.json ──> render.php (PHP CLI, stub env + fixtures) ──> html/<theme>/<page>.html
                                                                  │
build-css.mjs ──> <css dir>/<theme>.min.css ──> shoot.mjs (static server + Playwright)
                                                                  │
                                                      <out>/<theme>/<viewport>/<page>.png
```

Nothing here touches `web/css/themes`, `package.json` or a running panel. The controllers
(`web/list|add|edit/**/index.php`) and all `v-*` binaries are never executed: `lib/bootstrap.php`
replaces the helpers that would shell out, and `fixtures/*.php` provide the arrays the controllers
would normally build from the `v-list-*` JSON.

## Run

```sh
# 1. build every theme from web/css/src/themes/*.css into a scratch directory
node test/vylaris-preview/build-css.mjs /tmp/css-harness

# 2. render all pages and take the screenshots
node test/vylaris-preview/shoot.mjs \
	--css /tmp/css-harness --themes vylaris,vylaris-dark,default \
	--viewports desktop,mobile --pages all --out /tmp/shots

# fast loop for one or two pages
node test/vylaris-preview/shoot.mjs --css /tmp/css-harness --themes vylaris \
	--viewports desktop --pages list-web,edit-web --out /tmp/shots
```

Other `shoot.mjs` options: `--pages group:list` (groups: `login`, `list`, `edit`, `add`, `server`,
`german`, `state`), `--full-page`, `--animations on|off` (default `off`: reduced motion plus zero
animation durations), `--concurrency N` (default 6), `--render-only` (PHP only, no browser, useful
to find template warnings), `--list`, `--manifest <file>`.

The summary table lists every page and theme. Anything but `ok` means PHP warnings (`php:`),
console errors (`js:`), failed requests such as a missing font or image (`req:`) or a failed
interaction step (`step:`); the details follow below the table and the exit code is 1.
`<out>/report.json` has the same data.

### Playwright

Playwright is not a dependency of the repo (and `package.json` must stay as it is). `shoot.mjs` first
tries `import('playwright')` and then looks in `NODE_PATH` and `npm root -g`, so a global install
works. In this sandbox that is `NODE_PATH=$(npm root -g)` (`/opt/node22/lib/node_modules`). Chromium
comes from `PLAYWRIGHT_BROWSERS_PATH` (`/opt/pw-browsers`).

### Build the page JavaScript first

The pages load `/js/dist/*` (Alpine, the bundle, Chart.js, xterm). That folder is a build output; run
`npm run build` once if `web/js/dist` is missing. This also rebuilds `web/css/themes`, which is why
the harness builds its own CSS instead.

## What a page entry looks like (`pages.json`)

```json
{
	"id": "state-delete-confirm-modal",
	"group": "state",
	"template": "list_web",
	"tab": "WEB",
	"fixture": "list_web",
	"variant": "",
	"mode": "app",
	"lang": "en",
	"get": { "domain": "example.org" },
	"session": { "userContext": "user" },
	"panel": { "admin": { "NOTIFICATIONS": "yes" } },
	"viewports": ["desktop"],
	"fakeSocket": false,
	"settle": 250,
	"steps": [
		{ "hover": ".js-unit >> nth=2" },
		{ "click": ".js-unit >> nth=2 >> a[href*='/delete/']" }
	]
}
```

| Field                  | Meaning                                                                                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `template`             | file in `web/templates/pages/` without `.php` (`login/login_1` for the login steps)                                                               |
| `mode`                 | `app` (header, top panel, page, footer), `login` (header, page, login footer), `standalone` (the page prints its own shell: server info, web log) |
| `fixture`              | name of the fixture function, defaults to the template name; `variant` is passed to it                                                            |
| `get`/`post`/`session` | request data and `$_SESSION` overrides (user context, policies, `look`, `DEBUG_MODE`, ...)                                                        |
| `panel`                | field overrides for the user records the stub `v-list-user` returns                                                                               |
| `lang`                 | `de` compiles `de_DE.UTF-8` into `<out>/.locale` with `localedef` and renders with the real `.mo`                                                 |
| `steps`                | Playwright steps before the screenshot, see below                                                                                                 |

Steps (one action per object, `only`/`skip` take `desktop` or `mobile`): `click` (+ `force`),
`hover`, `focus`, `blur`, `press`, `fill [sel, value]`, `type [sel, text]`, `select [sel, value]`,
`check`, `uncheck`, `wait` (ms), `waitFor` (visible), `scrollTo`, `eval` (JS), `clip` (screenshot
only this element). Selectors are Playwright selectors, so `.js-unit >> nth=2` works.

## Add a page

1. Find the template in `web/templates/pages/` and the controller that renders it
   (`web/list|add|edit/**/index.php`); the controller shows the variable names and array shapes.
2. Add a fixture function in `fixtures/*.php` that returns `['data' => ..., 'v_x' => ...]`
   (these become globals for the template). Use German and English strings, umlauts, long names,
   suspended rows and an empty state.
3. Add an entry to `pages.json`.
4. `node test/vylaris-preview/shoot.mjs --render-only --pages <id> --out /tmp/x --themes default`
   fails on every PHP warning or notice (`E_ALL`); fix the fixture until it is clean.

## Stubbed endpoints (`lib/server.mjs`)

`/list/notifications/` (data/notifications.json), `/delete/notification/`, `POST /list/rrd/ajax.php`
(deterministic chart data for the Task Monitor), Quick Install App thumbnails (placeholder SVG).
The web terminal uses a fake `WebSocket` (`fakeSocket: true`) that prints a sample prompt.

## Known limits

- It is a preview, not the panel: forms do not submit, links to other pages 404 (only asset
  requests are checked for 404s) and nothing reflects real server state.
- Fixtures mirror the controllers by reading them, they are not generated. If a controller changes
  its data shape the render fails with a PHP warning, that is intended.
- Not covered yet: `list_backup_detail_incremental`, `list_files_incremental` (restic snapshot
  detail and file browser) and `list_server_preview`.
- `state-alerts-all-variants` injects the alert markup with JavaScript because no real page shows
  `alert-success` and `alert-warning`; `alert-warning` has no rule in `base.css` at the moment.
- Native `<select>` dropdowns and browser validation bubbles are drawn by the browser and do not
  appear in screenshots.
- German text needs `localedef` and `/usr/share/i18n` (glibc locales). Without them the German pages
  render in English and the run reports it.
- Screenshots are viewport sized by default (`--full-page` for the whole page), 1440x900 and 390x844 at
  device scale factor 1, always with `prefers-color-scheme: light`.
- Hestia's real `$_SERVER` is never printed by the debug panel: `render.php` replaces it with fixed
  anonymous values.

## Audit

`audit.mjs` runs automated checks per page, theme and viewport:

- text and UI contrast (WCAG AA), foreign colours that do not belong to the active theme palette, focus indicators, horizontal overflow and touch target size on mobile, console errors and failed requests.

```bash
node test/vylaris-preview/build-css.mjs /tmp/css
node test/vylaris-preview/audit.mjs --css /tmp/css --themes vylaris,vylaris-dark --viewports desktop,mobile --pages all --out /tmp/audit/audit.json
```

The JSON file and a markdown summary (`audit.md`) are written next to `--out`. Use `--find-rule` to locate the stylesheet rule behind a reported element, and `--help` for all options. Only the default state of each page is audited (no hover or visited states), and images or blend modes are not modelled in the contrast check.

### Palette

The allowed colours are every static colour literal in `tokens.css` and `mode-<light|dark>.css`: hex with or without alpha (`#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`), `rgb()`/`rgba()` and `hsl()`/`hsla()` in comma or space syntax with any alpha. The loader scans all custom properties, there is no list of token names, so a new token (for example `--vy-danger-solid`) is part of the palette as soon as it is in a mode file. The comparison ignores alpha and uses the first token that owns a colour as its name, so two tokens with the same value show up once. Values that only the browser can evaluate (`color-mix()`, `oklch()`, `light-dark()`, ...) cannot be part of the palette; each one is printed as `palette warning` and written to the report, as is a colour token that exists in only one of the two mode files.

### Allowlisted

Known false positives are skipped inside the tool, never silently: the report has an "Allowlisted" section (and `allowlist` in the JSON, `audit.allowlisted` per page run) with the number of elements, pages and an example per theme, rule and check.

| Rule                     | Checks                     | What is skipped                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------ | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `xterm-helper-textarea`  | contrast, ui, leaks, focus | `textarea.xterm-helper-textarea`: the vendor keyboard sink of the web terminal, invisible and parked off-screen; the terminal draws its own caret.                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `visually-hidden`        | contrast, ui               | Elements that are invisible by design: `clip: rect()` / `clip-path` that leaves nothing, the 1x1 screen-reader-only pattern (`.u-hidden-visually`), cumulative opacity 0 (pointer events do not matter, nothing is painted), and boxes parked left of or above the page or, when absolutely positioned, past its end. Only the root of a hidden subtree is counted, its descendants are skipped. The example shows the reason. Not applied to foreign colours (a closed drawer still carries theme colours) nor to focus (a hidden native input stands in for a custom checkbox or switch). |
| `input-boundary-covered` | ui                         | A text field whose own boundary is below 3:1 but which is covered (at least 90% of its box) by a sibling `select` / `[role=combobox]`, or sits inside a `[role=combobox]` wrapper, that has a border of its own meeting 3:1 against its surroundings. Example: `input.form-control.list-editor`, a free-text input laid over a select that draws the field boundary. The example shows "covered by"; the JSON keeps the detail in `audit.ui.covered` (`coveredBy`, `overlap`, `coverRatio`).                                                                                                |

Add a new exception in `pageAudit` (`allowed()` or the `ui` section in `audit-lib.mjs`) and a row to this table; an exception that does not appear in the report does not exist.

### Compare two runs

```bash
# run the audit and diff it against an earlier report; the diff is part of audit.md and stdout
node test/vylaris-preview/audit.mjs --css /tmp/css --out /tmp/audit/new.json --compare /tmp/audit/old.json [--fail-on-new]

# diff two existing reports, no browser
node test/vylaris-preview/audit.mjs --compare /tmp/audit/old.json --against /tmp/audit/new.json
```

A group is one row of the report (same category, element and colours). The table has, per theme, viewport and category, the number of **new** groups (only in the current run), **fixed** groups (only in the baseline), **unchanged** groups, how many of those unchanged groups have a different element count, and the element delta. The groups follow below the table; "No change" means no group appeared, disappeared or changed its count. Only runs (theme, viewport, page) that exist in both reports are compared, and the note says how many were left out. `--fail-on-new` exits with 1 when there is a new group.

Reports written by this version carry per-page `fingerprints`. Older reports do not: they are compared per theme with pages and viewports merged (viewport column "all"), limited to the 500 groups per category those reports kept.

### Speed

The audit takes no screenshots; most of the time is browser work per page. `--concurrency` defaults to twice the CPU count (about 25% faster than 4 on a 4 core machine for the full set), `--skip focus,leaks` leaves the slowest sections out (they report 0), `--settle 60` shortens the wait after load, and the pre-rendered HTML in `<out dir>/html` is the only other output.

## Working on one partial in isolation

```bash
node test/vylaris-preview/build-css.mjs /tmp/css --isolate topbar-menu
```

Builds the themes from a private copy of `web/css/src` in which every `web/css/src/themes/vylaris/*.css` partial except the named ones is reset to its last committed version. Several people can then edit different partials at the same time without a half-written file breaking the others' builds.
