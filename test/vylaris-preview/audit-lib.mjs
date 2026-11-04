// Building blocks of audit.mjs.
//
//   colorLib()   colour maths, runs in Node AND is injected into the page (it must stay
//                self-contained: it is serialised with Function.prototype.toString)
//   pageAudit()  the in-page audit (contrast, foreign colours, focus, responsive), same rule
//   loadPalette  reads the Vylaris token files and returns the allowed colours
import fs from "node:fs";
import path from "node:path";

/**
 * Colour helpers. Returns an object of functions. Colours are {r, g, b, a} with r/g/b 0..255 and a 0..1.
 * Self-contained on purpose (no imports, no outer references).
 */
export function colorLib() {
	const NAMED = {
		white: [255, 255, 255, 1],
		black: [0, 0, 0, 1],
		transparent: [0, 0, 0, 0],
	};
	let ctx = null;

	function fromCanvas(str) {
		if (typeof document === "undefined") {
			return null;
		}
		ctx ??= document.createElement("canvas").getContext("2d", { willReadFrequently: true });
		// an invalid string leaves fillStyle untouched: probe with two different sentinels
		ctx.fillStyle = "#010203";
		ctx.fillStyle = str;
		const first = ctx.fillStyle;
		ctx.fillStyle = "#040506";
		ctx.fillStyle = str;
		if (first !== ctx.fillStyle) {
			return null;
		}
		ctx.clearRect(0, 0, 1, 1);
		ctx.fillRect(0, 0, 1, 1);
		const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data;
		return { r, g, b, a: a / 255 };
	}

	function num(token, scale) {
		return token.endsWith("%")
			? (Number.parseFloat(token) / 100) * scale
			: Number.parseFloat(token);
	}

	/** @returns {{r:number,g:number,b:number,a:number}|null} */
	function parse(input) {
		if (input == null) {
			return null;
		}
		const str = String(input).trim().toLowerCase();
		if (NAMED[str]) {
			const [r, g, b, a] = NAMED[str];
			return { r, g, b, a };
		}
		let m = str.match(/^#([0-9a-f]+)$/);
		if (m && [3, 4, 6, 8].includes(m[1].length)) {
			let h = m[1];
			if (h.length <= 4) {
				h = [...h].map((c) => c + c).join("");
			}
			const v = (i) => Number.parseInt(h.slice(i, i + 2), 16);
			return { r: v(0), g: v(2), b: v(4), a: h.length === 8 ? v(6) / 255 : 1 };
		}
		m = str.match(/^rgba?\(([^)]*)\)$/);
		if (m) {
			const t = m[1].split(/[\s,/]+/).filter(Boolean);
			if (t.length >= 3 && !t.slice(0, 3).some((x) => x === "none" || x.startsWith("var"))) {
				return {
					r: Math.round(num(t[0], 255)),
					g: Math.round(num(t[1], 255)),
					b: Math.round(num(t[2], 255)),
					a: t[3] === undefined ? 1 : num(t[3], 1),
				};
			}
		}
		m = str.match(/^color\(srgb\s+([^)]*)\)$/);
		if (m) {
			const t = m[1].split(/[\s/]+/).filter(Boolean);
			if (t.length >= 3) {
				return {
					r: Math.round(num(t[0], 1) * 255),
					g: Math.round(num(t[1], 1) * 255),
					b: Math.round(num(t[2], 1) * 255),
					a: t[3] === undefined ? 1 : num(t[3], 1),
				};
			}
		}
		return fromCanvas(str);
	}

	/** fg over bg, general (bg may be translucent too) */
	function over(fg, bg) {
		const a = fg.a + bg.a * (1 - fg.a);
		if (a <= 0) {
			return { r: 0, g: 0, b: 0, a: 0 };
		}
		const mix = (f, b) => (f * fg.a + b * bg.a * (1 - fg.a)) / a;
		return { r: mix(fg.r, bg.r), g: mix(fg.g, bg.g), b: mix(fg.b, bg.b), a };
	}

	function luminance(c) {
		const lin = (v) => {
			const s = v / 255;
			return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
		};
		return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
	}

	/** WCAG contrast ratio of two opaque colours */
	function ratio(a, b) {
		const l1 = luminance(a);
		const l2 = luminance(b);
		return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
	}

	function toLab(c) {
		const lin = (v) => {
			const s = v / 255;
			return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
		};
		const r = lin(c.r);
		const g = lin(c.g);
		const b = lin(c.b);
		const x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047;
		const y = 0.2126729 * r + 0.7151522 * g + 0.072175 * b;
		const z = (0.0193339 * r + 0.119192 * g + 0.9503041 * b) / 1.08883;
		const f = (t) => (t > 216 / 24389 ? Math.cbrt(t) : ((24389 / 27) * t + 16) / 116);
		const fx = f(x);
		const fy = f(y);
		const fz = f(z);
		return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
	}

	/** CIEDE2000 between two Lab triples */
	function deltaE(l1, l2) {
		const rad = Math.PI / 180;
		const [L1, a1, b1] = l1;
		const [L2, a2, b2] = l2;
		const C1 = Math.hypot(a1, b1);
		const C2 = Math.hypot(a2, b2);
		const Cm = (C1 + C2) / 2;
		const G = 0.5 * (1 - Math.sqrt(Cm ** 7 / (Cm ** 7 + 25 ** 7)));
		const ap1 = (1 + G) * a1;
		const ap2 = (1 + G) * a2;
		const Cp1 = Math.hypot(ap1, b1);
		const Cp2 = Math.hypot(ap2, b2);
		const hp = (b, ap) => {
			if (b === 0 && ap === 0) {
				return 0;
			}
			const h = Math.atan2(b, ap) / rad;
			return h < 0 ? h + 360 : h;
		};
		const hp1 = hp(b1, ap1);
		const hp2 = hp(b2, ap2);
		const dLp = L2 - L1;
		const dCp = Cp2 - Cp1;
		let dhp = 0;
		if (Cp1 * Cp2 !== 0) {
			dhp = hp2 - hp1;
			if (dhp > 180) {
				dhp -= 360;
			} else if (dhp < -180) {
				dhp += 360;
			}
		}
		const dHp = 2 * Math.sqrt(Cp1 * Cp2) * Math.sin((dhp * rad) / 2);
		const Lpm = (L1 + L2) / 2;
		const Cpm = (Cp1 + Cp2) / 2;
		let hpm = hp1 + hp2;
		if (Cp1 * Cp2 !== 0) {
			if (Math.abs(hp1 - hp2) > 180) {
				hpm += hp1 + hp2 < 360 ? 360 : -360;
			}
			hpm /= 2;
		}
		const T =
			1 -
			0.17 * Math.cos((hpm - 30) * rad) +
			0.24 * Math.cos(2 * hpm * rad) +
			0.32 * Math.cos((3 * hpm + 6) * rad) -
			0.2 * Math.cos((4 * hpm - 63) * rad);
		const dTheta = 30 * Math.exp(-(((hpm - 275) / 25) ** 2));
		const Rc = 2 * Math.sqrt(Cpm ** 7 / (Cpm ** 7 + 25 ** 7));
		const Sl = 1 + (0.015 * (Lpm - 50) ** 2) / Math.sqrt(20 + (Lpm - 50) ** 2);
		const Sc = 1 + 0.045 * Cpm;
		const Sh = 1 + 0.015 * Cpm * T;
		const Rt = -Math.sin(2 * dTheta * rad) * Rc;
		return Math.sqrt(
			(dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2 + Rt * (dCp / Sc) * (dHp / Sh),
		);
	}

	const h2 = (v) =>
		Math.round(Math.min(255, Math.max(0, v)))
			.toString(16)
			.padStart(2, "0");
	/** #rrggbb, or #rrggbbaa when translucent */
	function hex(c) {
		return `#${h2(c.r)}${h2(c.g)}${h2(c.b)}${c.a < 0.999 ? h2(c.a * 255) : ""}`;
	}

	return { parse, over, luminance, ratio, toLab, deltaE, hex };
}

/**
 * Colour tokens of the Vylaris theme for one mode: every colour literal in tokens.css and
 * mode-<mode>.css (hex, rgb(), rgba()) with the custom property it belongs to.
 * @returns {{name: string, hex: string, rgb: number[], lab: number[]}[]}
 */
export function loadPalette(dir, mode) {
	const C = colorLib();
	const files = ["tokens.css", `mode-${mode}.css`];
	const seen = new Map();
	for (const file of files) {
		const full = path.join(dir, file);
		if (!fs.existsSync(full)) {
			throw new Error(`palette file missing: ${full}`);
		}
		const css = fs.readFileSync(full, "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
		for (const decl of css.matchAll(/(--[\w-]+)\s*:\s*([^;]+);/g)) {
			const [, name, value] = decl;
			for (const lit of value.matchAll(/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|hsla?\([^)]*\)/g)) {
				const c = C.parse(lit[0]);
				if (!c) {
					continue;
				}
				const key = `${Math.round(c.r)},${Math.round(c.g)},${Math.round(c.b)}`;
				if (!seen.has(key)) {
					seen.set(key, {
						name,
						hex: C.hex({ ...c, a: 1 }),
						rgb: [c.r, c.g, c.b],
						lab: C.toLab(c),
					});
				}
			}
		}
	}
	for (const [name, value] of [
		["white", [255, 255, 255]],
		["black", [0, 0, 0]],
	]) {
		const key = value.join(",");
		if (!seen.has(key)) {
			const c = { r: value[0], g: value[1], b: value[2], a: 1 };
			seen.set(key, { name, hex: C.hex(c), rgb: value, lab: C.toLab(c) });
		}
	}
	return [...seen.values()];
}

/**
 * The audit, evaluated inside the page (Playwright page.evaluate). Requires window.__vy = colorLib().
 * Everything it needs lives inside this function.
 *
 * @param {{palette: {name: string, hex: string, lab: number[]}[], tolerance: number, mobile: boolean,
 *   maxItems: number}} opts
 */
export function pageAudit(opts) {
	const C = window.__vy;
	const { palette, tolerance, mobile, maxItems } = opts;
	const root = document.documentElement;
	const vw = root.clientWidth;

	// ---- generic helpers ---------------------------------------------------------------------
	const csCache = new WeakMap();
	const cs = (el) => {
		let s = csCache.get(el);
		if (!s) {
			s = getComputedStyle(el);
			csCache.set(el, s);
		}
		return s;
	};
	const classesOf = (el) =>
		(typeof el.className === "string" ? el.className : (el.getAttribute("class") ?? ""))
			.split(/\s+/)
			.filter(Boolean);
	const keyOf = (el) => {
		const cls = classesOf(el)
			.filter((c) => !/^(x-|ng-)/.test(c))
			.slice(0, 4);
		return el.localName + cls.map((c) => `.${c}`).join("");
	};
	const selPath = (el) => {
		const parts = [];
		let n = el;
		while (n && n !== document.body && n !== root && parts.length < 4) {
			parts.unshift(keyOf(n) + (n.id && n === el ? `#${n.id}` : ""));
			n = n.parentElement;
		}
		if (n && n !== document.body && n !== root) {
			parts.unshift("...");
		}
		return parts.join(" > ");
	};
	const snippet = (text) => text.replace(/\s+/g, " ").trim().slice(0, 60);
	const at = (el) => {
		const r = el.getBoundingClientRect();
		return [
			Math.round(r.left + scrollX),
			Math.round(r.top + scrollY),
			Math.round(r.width),
			Math.round(r.height),
		];
	};
	const SKIP_TAGS = new Set([
		"script",
		"style",
		"noscript",
		"template",
		"head",
		"title",
		"meta",
		"link",
	]);

	const opacityCache = new WeakMap();
	const cumOpacity = (el) => {
		if (!el || el === document) {
			return 1;
		}
		let v = opacityCache.get(el);
		if (v === undefined) {
			v = Number.parseFloat(cs(el).opacity) * cumOpacity(el.parentElement);
			opacityCache.set(el, v);
		}
		return v;
	};
	const collapsedCache = new WeakMap();
	/** an ancestor that clips its content and has no area (closed accordion, max-height: 0) */
	const collapsedAbove = (el) => {
		const p = el.parentElement;
		if (!p) {
			return false;
		}
		let v = collapsedCache.get(p);
		if (v === undefined) {
			const s = cs(p);
			const r = p.getBoundingClientRect();
			const clips = s.overflowX !== "visible" || s.overflowY !== "visible";
			v =
				(clips &&
					s.display !== "contents" &&
					s.display !== "inline" &&
					(r.width < 1 || r.height < 1)) ||
				collapsedAbove(p);
			collapsedCache.set(p, v);
		}
		return v;
	};
	/** inside a closed <details> (other than its <summary>): laid out by the engine but not shown */
	const inClosedDetails = (el) => {
		const summary = el.closest("summary");
		for (
			let d = el.closest("details:not([open])");
			d;
			d = d.parentElement?.closest("details:not([open])")
		) {
			if (!(summary && summary.parentElement === d)) {
				return true;
			}
		}
		return false;
	};
	const rendered = (el) => {
		const s = cs(el);
		if (s.display === "none" || inClosedDetails(el)) {
			return false;
		}
		return s.display === "contents" || el.getClientRects().length > 0;
	};
	/** painted, not transparent, not collapsed, not parked off the left / top edge */
	const isVisible = (el, allowTiny = false) => {
		if (
			!rendered(el) ||
			cs(el).visibility !== "visible" ||
			cumOpacity(el) < 0.02 ||
			collapsedAbove(el)
		) {
			return false;
		}
		const r = el.getBoundingClientRect();
		if (r.width <= 0 || r.height <= 0) {
			return false;
		}
		if (!allowTiny && r.width <= 1 && r.height <= 1) {
			return false;
		}
		return r.right + scrollX > 0 && r.bottom + scrollY > 0;
	};
	const isDisabled = (el) =>
		el.matches(":disabled") ||
		el.closest("[aria-disabled='true'],[inert]") !== null ||
		classesOf(el).includes("disabled");
	const ICON_SELECTOR = ".fa, .fas, .far, .fab, .fa-solid, .fa-regular, .fa-brands, [class*='fa-']";
	const isIcon = (el) => el.matches(ICON_SELECTOR) && !el.matches("svg *");
	const hasOwnText = (el) =>
		[...el.childNodes].some((n) => n.nodeType === 3 && n.nodeValue.trim() !== "");

	// ---- background resolution (contrast) ----------------------------------------------------
	const layerCache = new WeakMap();
	const splitTop = (str) => {
		const out = [];
		let depth = 0;
		let cur = "";
		for (const ch of str) {
			if (ch === "(") {
				depth++;
			} else if (ch === ")") {
				depth--;
			}
			if (ch === "," && depth === 0) {
				out.push(cur.trim());
				cur = "";
			} else {
				cur += ch;
			}
		}
		if (cur.trim()) {
			out.push(cur.trim());
		}
		return out;
	};
	const COLOR_RE =
		/rgba?\([^)]*\)|(?:lab|lch|oklab|oklch|hsla?|color)\([^)]*\)|#[0-9a-fA-F]{3,8}\b|\btransparent\b/g;
	/** paint layers of one element, top to bottom. Each layer: [first, last] colour candidates */
	const layersOf = (el) => {
		let v = layerCache.get(el);
		if (v) {
			return v;
		}
		const s = cs(el);
		const layers = [];
		let unknown = false;
		const bi = s.backgroundImage;
		if (bi && bi !== "none") {
			for (const [i, part] of splitTop(bi).entries()) {
				if (/gradient\(/.test(part)) {
					const stops = (part.match(COLOR_RE) ?? []).map((c) => C.parse(c)).filter(Boolean);
					if (stops.length === 0) {
						unknown = true;
					} else {
						layers.push({
							ends: [stops[0], stops[stops.length - 1]],
							linear: /^linear-gradient\(/.test(part) ? part : null,
						});
					}
				} else if (part !== "none") {
					// a small non-repeating picture (select arrow, icon) does not cover the text
					const repeats = splitTop(s.backgroundRepeat);
					const sizes = splitTop(s.backgroundSize);
					const repeat = repeats[i % repeats.length];
					const size = sizes[i % sizes.length];
					if (!(repeat === "no-repeat" && !/cover|contain|100%/.test(size))) {
						unknown = true;
					}
				}
			}
		}
		const bg = C.parse(s.backgroundColor);
		if (bg && bg.a > 0) {
			layers.push({ ends: [bg], linear: null });
		}
		v = { layers, unknown };
		layerCache.set(el, v);
		return v;
	};
	const canvas = (() => {
		const scheme = cs(root).colorScheme;
		return /\bdark\b/.test(scheme) && !/\blight\b/.test(scheme)
			? { r: 18, g: 18, b: 18, a: 1 }
			: { r: 255, g: 255, b: 255, a: 1 };
	})();
	const flatten = (stack, base) => {
		// stack: top -> bottom
		let acc = base;
		for (let i = stack.length - 1; i >= 0; i--) {
			acc = acc ? C.over(stack[i], acc) : stack[i];
		}
		return acc;
	};
	/**
	 * Colours of a linear-gradient() that lie under `target` (a viewport rect): the colour at both ends of
	 * the stretch the rect covers plus every stop in between. null when the gradient cannot be
	 * evaluated (corner keywords, rad/turn angles, colour hints): callers fall back to first / last stop.
	 */
	const linearCandidates = (str, owner, target) => {
		const parts = splitTop(str.slice(str.indexOf("(") + 1, str.lastIndexOf(")")));
		let angle = 180;
		if (!/^(rgba?|hsla?|lab|lch|oklab|oklch|color|#|transparent)/.test(parts[0])) {
			const m = parts[0].match(/^(-?[\d.]+)deg$/);
			const dir = { "to top": 0, "to right": 90, "to bottom": 180, "to left": 270 }[parts[0]];
			if (m) {
				angle = Number.parseFloat(m[1]);
			} else if (dir !== undefined) {
				angle = dir;
			} else {
				return null;
			}
			parts.shift();
		}
		const box = owner.getBoundingClientRect();
		const rad = (angle * Math.PI) / 180;
		const dx = Math.sin(rad);
		const dy = -Math.cos(rad);
		const len = Math.abs(box.width * dx) + Math.abs(box.height * dy);
		if (len < 1) {
			return null;
		}
		let stops = [];
		for (const part of parts) {
			const lit = part.match(COLOR_RE);
			const c = lit && C.parse(lit[0]);
			if (!c || lit.length !== 1) {
				return null;
			}
			const pos = part
				.replace(lit[0], "")
				.split(/\s+/)
				.filter(Boolean)
				.map((p) =>
					p.endsWith("%")
						? Number.parseFloat(p) / 100
						: p.endsWith("px")
							? Number.parseFloat(p) / len
							: Number.NaN,
				);
			if (pos.some(Number.isNaN)) {
				return null;
			}
			if (pos.length === 0) {
				stops.push({ c, pos: null });
			} else {
				for (const p of pos) {
					stops.push({ c, pos: p });
				}
			}
		}
		if (stops.length < 2) {
			return null;
		}
		stops[0].pos ??= 0;
		stops[stops.length - 1].pos ??= 1;
		let prev = stops[0].pos;
		for (let i = 1; i < stops.length; i++) {
			if (stops[i].pos !== null) {
				stops[i].pos = Math.max(stops[i].pos, prev);
				prev = stops[i].pos;
			}
		}
		for (let i = 1; i < stops.length - 1; i++) {
			if (stops[i].pos === null) {
				let j = i;
				while (stops[j].pos === null) {
					j++;
				}
				const a = stops[i - 1].pos;
				const step = (stops[j].pos - a) / (j - i + 1);
				for (let k = i; k < j; k++) {
					stops[k].pos = a + step * (k - i + 1);
				}
			}
		}
		stops = stops.filter((x) => x.pos !== null);
		const at = (t) => {
			if (t <= stops[0].pos) {
				return stops[0].c;
			}
			for (let i = 1; i < stops.length; i++) {
				if (t <= stops[i].pos) {
					const a = stops[i - 1];
					const b = stops[i];
					const f = b.pos === a.pos ? 1 : (t - a.pos) / (b.pos - a.pos);
					const mix = (x, y) => x + (y - x) * f;
					return {
						r: mix(a.c.r, b.c.r),
						g: mix(a.c.g, b.c.g),
						b: mix(a.c.b, b.c.b),
						a: mix(a.c.a, b.c.a),
					};
				}
			}
			return stops[stops.length - 1].c;
		};
		// the part of the target that lies inside the gradient box
		const x0 = Math.max(target.left, box.left);
		const x1 = Math.min(target.right, box.right);
		const y0 = Math.max(target.top, box.top);
		const y1 = Math.min(target.bottom, box.bottom);
		const corners =
			x1 >= x0 && y1 >= y0
				? [
						[x0, y0],
						[x1, y0],
						[x0, y1],
						[x1, y1],
					]
				: [
						[target.left, target.top],
						[target.right, target.bottom],
					];
		const cx = box.left + box.width / 2;
		const cy = box.top + box.height / 2;
		const ts = corners.map(([x, y]) => ((x - cx) * dx + (y - cy) * dy) / len + 0.5);
		const lo = Math.min(...ts);
		const hi = Math.max(...ts);
		return [at(lo), ...stops.filter((x) => x.pos > lo && x.pos < hi).map((x) => x.c), at(hi)];
	};
	/**
	 * Real fg and bg colours behind/at `el`: walks the ancestors, composites every layer in paint order
	 * and applies opacity groups. Two variants: gradients sampled at their first / last stop.
	 * @returns {{variants: {fg: object|null, bg: object}[], unknown: boolean}}
	 */
	const resolve = (el, fgColor, target = el.getBoundingClientRect()) => {
		let unknown = false;
		// per node: its layers as candidate colour lists + opacity
		const chain = [];
		for (let n = el; n; n = n.parentElement) {
			const { layers, unknown: u } = layersOf(n);
			if (u) {
				unknown = true;
			}
			chain.push({
				cands: layers.map(
					(l) => (l.linear ? linearCandidates(l.linear, n, target) : null) ?? l.ends,
				),
				opacity: Number.parseFloat(cs(n).opacity),
			});
		}
		const count = Math.min(8, Math.max(1, ...chain.flatMap((c) => c.cands.map((x) => x.length))));
		const variants = Array.from({ length: count }, (_, vi) => {
			let F = fgColor ? [fgColor] : [];
			let B = [];
			for (const { cands, opacity } of chain) {
				for (const list of cands) {
					const c = list[Math.min(vi, list.length - 1)];
					F.push(c);
					B.push(c);
				}
				if (opacity < 1) {
					const collapse = (stack) => {
						const flat = flatten(stack, null);
						return flat ? [{ ...flat, a: flat.a * opacity }] : [];
					};
					F = collapse(F);
					B = collapse(B);
				}
			}
			return { fg: fgColor ? flatten(F, canvas) : null, bg: flatten(B, canvas) };
		});
		return { variants, unknown };
	};
	const worstRatio = (pairs) => {
		let worst = null;
		for (const { fg, bg } of pairs) {
			const r = C.ratio(fg, bg);
			if (!worst || r < worst.ratio) {
				worst = { ratio: r, fg, bg };
			}
		}
		return worst;
	};

	// ---- 1. contrast --------------------------------------------------------------------------
	const mk = () => ({ items: [], total: 0 });
	const record = (list, item) => {
		list.total++;
		if (list.items.length < maxItems) {
			list.items.push(item);
		}
	};

	const contrast = { fails: mk(), unknown: mk(), checked: 0, exempt: 0 };
	const ui = { fails: mk(), checked: 0 };

	/** union of the line boxes of the element's own text (the whole box when it has none) */
	const textRect = (el) => {
		const range = document.createRange();
		let rect = null;
		for (const n of el.childNodes) {
			if (n.nodeType === 3 && n.nodeValue.trim() !== "") {
				range.selectNodeContents(n);
				for (const r of range.getClientRects()) {
					rect = rect
						? {
								left: Math.min(rect.left, r.left),
								top: Math.min(rect.top, r.top),
								right: Math.max(rect.right, r.right),
								bottom: Math.max(rect.bottom, r.bottom),
							}
						: { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
				}
			}
		}
		return rect ?? el.getBoundingClientRect();
	};
	const checkText = (el, text, kind, colorOverride) => {
		const s = cs(el);
		const raw =
			colorOverride ??
			C.parse(el instanceof SVGElement ? s.fill : s.webkitTextFillColor || s.color);
		if (!raw || raw.a === 0) {
			return;
		}
		if (isDisabled(el)) {
			contrast.exempt++;
			return;
		}
		contrast.checked++;
		const { variants, unknown } = resolve(el, raw, textRect(el));
		const size = Number.parseFloat(s.fontSize);
		const weight = Number.parseInt(s.fontWeight, 10) || 400;
		const large = size >= 24 || (size >= 18.66 && weight >= 700);
		const required = large ? 3 : 4.5;
		const base = {
			kind,
			sel: selPath(el),
			key: keyOf(el),
			text: snippet(text),
			size: Math.round(size * 10) / 10,
			weight,
			large,
			at: at(el),
		};
		if (unknown) {
			// a url() background image or an unparsable gradient: no honest answer
			record(contrast.unknown, { ...base, fg: C.hex(raw) });
			return;
		}
		const w = worstRatio(variants);
		if (w.ratio < required) {
			record(contrast.fails, {
				...base,
				ratio: Math.round(w.ratio * 100) / 100,
				required,
				fg: C.hex(w.fg),
				bg: C.hex(w.bg),
				css: s.color,
			});
		}
	};

	const NO_TEXT_PARENT = new Set(["option", "optgroup", "select", "textarea", "datalist"]);
	const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
	const textByEl = new Map();
	for (let n = walker.nextNode(); n; n = walker.nextNode()) {
		const el = n.parentElement;
		if (
			!el ||
			n.nodeValue.trim() === "" ||
			SKIP_TAGS.has(el.localName) ||
			NO_TEXT_PARENT.has(el.localName)
		) {
			continue;
		}
		textByEl.set(el, `${textByEl.get(el) ?? ""} ${n.nodeValue}`);
	}
	for (const [el, text] of textByEl) {
		if (isVisible(el)) {
			checkText(el, text, "text");
		}
	}
	// form controls: value / selected option / placeholder text
	const TEXTUAL_INPUT =
		"input:not([type=hidden],[type=checkbox],[type=radio],[type=range],[type=color],[type=file],[type=image])";
	for (const el of document.querySelectorAll(`${TEXTUAL_INPUT}, textarea, select`)) {
		if (!isVisible(el)) {
			continue;
		}
		let shown = el.value ?? "";
		if (el.localName === "select") {
			shown = el.selectedOptions?.[0]?.textContent ?? "";
		}
		if (shown.trim() !== "" && !["submit", "button", "reset"].includes(el.type)) {
			checkText(el, shown, "control-value");
		} else if (["submit", "button", "reset"].includes(el.type) && shown.trim() !== "") {
			checkText(el, shown, "control-value");
		}
		if (el.placeholder && (el.value ?? "") === "") {
			checkText(
				el,
				el.placeholder,
				"placeholder",
				C.parse(getComputedStyle(el, "::placeholder").color),
			);
		}
	}

	// ---- non-text contrast (>= 3:1) -----------------------------------------------------------
	const uiCheck = (el, kind, value, extra) => {
		ui.checked++;
		if (value.ratio < 3) {
			record(ui.fails, {
				kind,
				sel: selPath(el),
				key: keyOf(el),
				ratio: Math.round(value.ratio * 100) / 100,
				required: 3,
				fg: C.hex(value.fg),
				bg: C.hex(value.bg),
				at: at(el),
				...extra,
			});
		}
	};
	// icon glyphs (Font Awesome)
	for (const el of document.querySelectorAll(ICON_SELECTOR)) {
		if (el.matches("svg *") || !isVisible(el) || isDisabled(el) || hasOwnText(el)) {
			continue;
		}
		const c = C.parse(cs(el).color);
		if (!c || c.a === 0) {
			continue;
		}
		const { variants, unknown } = resolve(el, c);
		if (!unknown) {
			uiCheck(el, "icon", worstRatio(variants), { text: el.className.toString().slice(0, 50) });
		}
	}
	// text field borders (or, without a border, the field fill against its surroundings)
	const FIELDS =
		"input:not([type=hidden],[type=checkbox],[type=radio],[type=submit],[type=button],[type=reset],[type=image],[type=file],[type=range],[type=color]), select, textarea";
	for (const el of document.querySelectorAll(FIELDS)) {
		if (!isVisible(el) || isDisabled(el) || !el.parentElement) {
			continue;
		}
		const s = cs(el);
		const parent = resolve(el.parentElement, null);
		const own = resolve(el, null);
		if (own.unknown || parent.unknown) {
			continue;
		}
		const sides = ["Top", "Right", "Bottom", "Left"]
			.map((d) => ({
				w: Number.parseFloat(s[`border${d}Width`]),
				style: s[`border${d}Style`],
				c: C.parse(s[`border${d}Color`]),
			}))
			.filter((x) => x.w >= 1 && x.style !== "none" && x.style !== "hidden" && x.c && x.c.a > 0);
		const pairs = parent.variants.map((pv, i) => {
			const fill = own.variants[i].bg;
			let best = { ratio: C.ratio(fill, pv.bg), fg: fill, bg: pv.bg, what: "fill" };
			for (const side of sides) {
				const stroke = C.over(side.c, fill);
				const r = C.ratio(stroke, pv.bg);
				if (best.what === "fill" || r > best.ratio) {
					best = { ratio: r, fg: stroke, bg: pv.bg, what: "border" };
				}
			}
			return best;
		});
		const w = pairs.reduce((a, b) => (b.ratio < a.ratio ? b : a));
		uiCheck(el, w.what === "border" ? "input-border" : "input-boundary", w, {
			text: el.type || el.localName,
		});
	}

	// ---- 2. foreign colours -------------------------------------------------------------------
	const leakMap = new Map();
	const foreignCache = new Map();
	/** nearest palette entry when the colour is NOT allowed, null when it is allowed */
	const foreign = (c) => {
		if (!c || c.a < 0.004) {
			return null;
		}
		const id = `${Math.round(c.r)},${Math.round(c.g)},${Math.round(c.b)}`;
		if (foreignCache.has(id)) {
			return foreignCache.get(id);
		}
		const lab = C.toLab(c);
		let best = null;
		for (const p of palette) {
			const d = C.deltaE(lab, p.lab);
			if (!best || d < best.d) {
				best = { name: p.name, hex: p.hex, d };
			}
		}
		const result = best && best.d < tolerance ? null : best;
		foreignCache.set(id, result);
		return result;
	};
	let leakChecked = 0;
	const leak = (el, prop, c, extra = {}) => {
		const near = foreign(c);
		leakChecked++;
		if (!near) {
			return;
		}
		const key = keyOf(el) + (extra.pseudo ?? "");
		const id = `${prop}|${C.hex(c)}|${key}`;
		let g = leakMap.get(id);
		if (!g) {
			g = {
				prop,
				color: C.hex(c),
				key,
				nearest: near.name,
				nearestHex: near.hex,
				deltaE: Math.round(near.d * 10) / 10,
				count: 0,
				examples: [],
				...(extra.origin ? { origin: extra.origin } : {}),
			};
			leakMap.set(id, g);
		}
		g.count++;
		if (g.examples.length < 3) {
			g.examples.push({
				sel: selPath(el) + (extra.pseudo ?? ""),
				text: snippet(el.textContent ?? "").slice(0, 40),
				at: at(el),
			});
		}
	};
	const colorsIn = (str) =>
		str && str !== "none" ? (str.match(COLOR_RE) ?? []).map((x) => C.parse(x)).filter(Boolean) : [];
	const SVG_SHAPES = new Set([
		"path",
		"circle",
		"rect",
		"line",
		"polyline",
		"polygon",
		"ellipse",
		"text",
		"tspan",
		"stop",
	]);
	/** nearest element (self or ancestor) that sets a different color than its parent: where to look in the CSS */
	const colorOrigin = (el) => {
		let n = el;
		while (n.parentElement && cs(n).color === cs(n.parentElement).color) {
			n = n.parentElement;
		}
		return n === el ? undefined : keyOf(n);
	};
	const sideNames = ["Top", "Right", "Bottom", "Left"];
	for (const el of [root, ...document.body.querySelectorAll("*")]) {
		if (SKIP_TAGS.has(el.localName) || !rendered(el)) {
			continue;
		}
		const s = cs(el);
		const icon = isIcon(el);
		const svgShape = el instanceof SVGElement && SVG_SHAPES.has(el.localName);
		if (svgShape) {
			for (const prop of ["fill", "stroke"]) {
				for (const c of colorsIn(s[prop])) {
					leak(el, prop, c);
				}
			}
			if (el.localName === "stop") {
				for (const c of colorsIn(s.stopColor)) {
					leak(el, "stop-color", c);
				}
			}
			continue;
		}
		if (el instanceof SVGElement && el.localName !== "svg") {
			continue;
		}
		if (hasOwnText(el) || icon || el.matches("input,select,textarea,button")) {
			leak(el, "color", C.parse(s.webkitTextFillColor || s.color), { origin: colorOrigin(el) });
		}
		leak(el, "background-color", C.parse(s.backgroundColor));
		for (const c of colorsIn(s.backgroundImage)) {
			leak(el, "background-image", c);
		}
		const borders = new Set();
		for (const d of sideNames) {
			const w = Number.parseFloat(s[`border${d}Width`]);
			const st = s[`border${d}Style`];
			if (w > 0 && st !== "none" && st !== "hidden") {
				borders.add(s[`border${d}Color`]);
			}
		}
		for (const b of borders) {
			leak(el, "border-color", C.parse(b));
		}
		if (
			Number.parseFloat(s.outlineWidth) > 0 &&
			s.outlineStyle !== "none" &&
			s.outlineStyle !== "auto"
		) {
			leak(el, "outline-color", C.parse(s.outlineColor));
		}
		for (const c of colorsIn(s.boxShadow)) {
			leak(el, "box-shadow", c);
		}
		for (const c of colorsIn(s.textShadow)) {
			leak(el, "text-shadow", c);
		}
		if (s.accentColor !== "auto") {
			leak(el, "accent-color", C.parse(s.accentColor));
		}
		if (!icon) {
			for (const pseudo of ["::before", "::after"]) {
				const ps = getComputedStyle(el, pseudo);
				if (ps.content === "none" || ps.content === "normal" || ps.display === "none") {
					continue;
				}
				const textual = ps.content !== '""' && ps.content !== "''";
				if (textual && ps.color !== s.color) {
					leak(el, "color", C.parse(ps.color), { pseudo });
				}
				leak(el, "background-color", C.parse(ps.backgroundColor), { pseudo });
				for (const c of colorsIn(ps.backgroundImage)) {
					leak(el, "background-image", c, { pseudo });
				}
				if (Number.parseFloat(ps.borderTopWidth) > 0 && ps.borderTopStyle !== "none") {
					leak(el, "border-color", C.parse(ps.borderTopColor), { pseudo });
				}
			}
		}
		if (el.matches("input,textarea") && (el.placeholder ?? "") !== "") {
			leak(el, "placeholder-color", C.parse(getComputedStyle(el, "::placeholder").color));
		}
	}
	const leaks = [...leakMap.values()].sort((a, b) => b.count - a.count);

	// ---- 4. responsive ------------------------------------------------------------------------
	const responsive = {
		viewport: vw,
		scrollWidth: root.scrollWidth,
		clientWidth: root.clientWidth,
		docOverflow: root.scrollWidth > root.clientWidth + 1,
		culprits: mk(),
		targets: { checked: 0, fails: mk(), exempt: 0 },
	};
	{
		const clippedX = (el) => {
			for (let n = el.parentElement; n && n !== document.body && n !== root; n = n.parentElement) {
				const s = cs(n);
				if (s.overflowX !== "visible") {
					const r = n.getBoundingClientRect();
					if (r.right <= vw + 1 && r.width > 0) {
						return true;
					}
				}
				if (s.position === "fixed") {
					return true;
				}
			}
			return cs(el).position === "fixed";
		};
		const offenders = new Set();
		for (const el of document.body.querySelectorAll("*")) {
			if (SKIP_TAGS.has(el.localName) || !rendered(el) || cs(el).visibility === "hidden") {
				continue;
			}
			const r = el.getBoundingClientRect();
			if (r.width < 1 || r.height < 1) {
				continue;
			}
			const wide = r.width > vw + 1;
			const beyond = r.right > vw + 1 && r.left < vw;
			if (!(wide || beyond) || clippedX(el) || collapsedAbove(el)) {
				continue;
			}
			let nested = false;
			for (let n = el.parentElement; n; n = n.parentElement) {
				if (offenders.has(n)) {
					nested = true;
					break;
				}
			}
			if (nested) {
				continue;
			}
			offenders.add(el);
			record(responsive.culprits, {
				sel: selPath(el),
				key: keyOf(el),
				width: Math.round(r.width),
				right: Math.round(r.right),
				wide,
				at: at(el),
			});
		}

		if (mobile) {
			const TARGETS =
				"a[href], button, input:not([type=hidden]), select, textarea, summary, [role=button], [role=link], [role=checkbox], [role=switch], [role=tab], [role=menuitem], [tabindex]:not([tabindex='-1'])";
			const items = [];
			for (const el of document.querySelectorAll(TARGETS)) {
				if (
					!rendered(el) ||
					cs(el).visibility !== "visible" ||
					collapsedAbove(el) ||
					isDisabled(el)
				) {
					continue;
				}
				let r = el.getBoundingClientRect();
				let viaLabel = false;
				if (el.matches("input[type=checkbox],input[type=radio]")) {
					// the label is part of the click area
					const labelRects = [...(el.labels ?? [])]
						.filter((l) => isVisible(l))
						.map((l) => l.getBoundingClientRect());
					const biggest = labelRects.reduce(
						(a, b) => (b.width * b.height > a.width * a.height ? b : a),
						r,
					);
					if (labelRects.length && biggest !== r) {
						r = biggest;
						viaLabel = true;
					} else if (labelRects.length) {
						// the input itself is the bigger area
					} else if (cumOpacity(el) < 0.02 || r.width <= 1) {
						continue;
					}
				} else if (cumOpacity(el) < 0.02 || r.width <= 1 || r.height <= 1) {
					continue;
				}
				if (r.right + scrollX <= 0 || r.left >= root.scrollWidth || r.bottom + scrollY <= 0) {
					continue;
				}
				items.push({ el, r, viaLabel, small: r.width < 23.99 || r.height < 23.99 });
			}
			responsive.targets.checked = items.length;
			const rectDist = (px, py, r) =>
				Math.hypot(Math.max(r.left - px, 0, px - r.right), Math.max(r.top - py, 0, py - r.bottom));
			for (const t of items) {
				if (!t.small) {
					continue;
				}
				const inline =
					t.el.localName === "a" &&
					cs(t.el).display === "inline" &&
					t.el.parentElement &&
					(t.el.parentElement.textContent ?? "").trim().length -
						(t.el.textContent ?? "").trim().length >
						3;
				if (inline) {
					responsive.targets.exempt++;
					continue;
				}
				const cx = t.r.left + t.r.width / 2;
				const cy = t.r.top + t.r.height / 2;
				const crowded = items.some((o) => {
					if (o === t || o.el.contains(t.el) || t.el.contains(o.el)) {
						return false;
					}
					if (o.small) {
						return (
							Math.hypot(cx - (o.r.left + o.r.width / 2), cy - (o.r.top + o.r.height / 2)) < 24
						);
					}
					return rectDist(cx, cy, o.r) < 12;
				});
				if (!crowded) {
					// WCAG 2.2 SC 2.5.8 spacing exception
					responsive.targets.exempt++;
					continue;
				}
				record(responsive.targets.fails, {
					sel: selPath(t.el),
					key: keyOf(t.el),
					via: t.viaLabel ? "label" : undefined,
					w: Math.round(t.r.width * 10) / 10,
					h: Math.round(t.r.height * 10) / 10,
					text: snippet(
						t.el.textContent ||
							t.el.getAttribute("aria-label") ||
							t.el.title ||
							t.el.className.toString(),
					),
					at: at(t.el),
				});
			}
		}
	}

	// ---- 3. focus (last: it changes document state) ------------------------------------------
	const focus = {
		checked: 0,
		fails: mk(),
		weak: mk(),
		lowContrast: mk(),
		uaDefault: 0,
		notFocusVisible: 0,
		notFocusable: 0,
	};
	{
		const FOCUSABLE =
			"a[href], area[href], button, input:not([type=hidden]), select, textarea, summary, [tabindex], [contenteditable]:not([contenteditable=false])";
		const snap = (el) => {
			const s = getComputedStyle(el);
			const pseudo = ["::before", "::after"]
				.map((p) => {
					const ps = getComputedStyle(el, p);
					return [
						ps.content,
						ps.display,
						ps.backgroundColor,
						ps.borderTopWidth,
						ps.borderTopColor,
						ps.transform,
						ps.width,
						ps.height,
						ps.boxShadow,
					].join(" ");
				})
				.join("|");
			return {
				outline: [s.outlineStyle, s.outlineWidth, s.outlineColor, s.outlineOffset].join(" "),
				outlineStyle: s.outlineStyle,
				outlineWidth: Number.parseFloat(s.outlineWidth),
				outlineColor: s.outlineColor,
				shadow: s.boxShadow,
				border: sideNames
					.map((d) => `${s[`border${d}Width`]} ${s[`border${d}Style`]} ${s[`border${d}Color`]}`)
					.join("|"),
				borderColor: s.borderBottomColor,
				bg: `${s.backgroundColor} ${s.backgroundImage}`,
				bgColor: s.backgroundColor,
				color: `${s.color} ${s.webkitTextFillColor}`,
				deco: `${s.textDecorationLine} ${s.textDecorationColor} ${s.textDecorationThickness}`,
				transform: `${s.transform} ${s.opacity} ${s.filter}`,
				pseudo,
			};
		};
		const hidden = (el) =>
			cumOpacity(el) < 0.02 ||
			el.getBoundingClientRect().width < 4 ||
			el.getBoundingClientRect().height < 4;
		const targetsOf = (el) => {
			if (!hidden(el)) {
				return [el];
			}
			// visually hidden input (custom checkbox / switch): the sibling or label has to show the focus
			// (the input itself is invisible, its own outline does not count)
			return [
				...(el.labels ?? []),
				el.parentElement,
				el.nextElementSibling,
				el.previousElementSibling,
			].filter((x, i, arr) => x && arr.indexOf(x) === i);
		};
		const opaque = (str, backdrop) => {
			const c = C.parse(str);
			return c ? C.over(c, backdrop) : null;
		};
		const list = [...document.querySelectorAll(FOCUSABLE)].filter(
			(el) =>
				el.tabIndex >= 0 &&
				// xterm.js parks an invisible textarea for keyboard input, the terminal draws its own cursor
				!el.matches(".xterm-helper-textarea") &&
				!isDisabled(el) &&
				rendered(el) &&
				cs(el).visibility === "visible" &&
				!collapsedAbove(el),
		);
		for (const el of list) {
			const targets = targetsOf(el);
			if (document.activeElement && document.activeElement !== document.body) {
				document.activeElement.blur();
			}
			const before = targets.map(snap);
			el.focus({ preventScroll: true, focusVisible: true });
			if (document.activeElement !== el) {
				// the engine refused the focus (inert, clipped away, closed popup): nothing to judge
				focus.notFocusable++;
				continue;
			}
			const fv = el.matches(":focus-visible");
			if (!fv) {
				focus.notFocusVisible++;
			}
			const after = targets.map(snap);
			focus.checked++;
			const strong = [];
			const weakKinds = [];
			let indicator = null;
			targets.forEach((t, i) => {
				const a = before[i];
				const b = after[i];
				const bgBehind = resolve(t.parentElement ?? t, null).variants;
				if (a.outline !== b.outline) {
					if (b.outlineStyle === "auto") {
						focus.uaDefault++;
						strong.push("outline:auto");
					} else if (
						b.outlineStyle !== "none" &&
						b.outlineStyle !== "hidden" &&
						b.outlineWidth > 0
					) {
						const c = C.parse(b.outlineColor);
						if (c && c.a > 0) {
							strong.push("outline");
							indicator = bgBehind.map((v) => C.ratio(C.over(c, v.bg), v.bg));
						}
					}
				}
				if (a.shadow !== b.shadow && b.shadow !== "none") {
					const fresh = colorsIn(b.shadow).filter((c) => c.a > 0.2);
					if (fresh.length) {
						strong.push("box-shadow");
						indicator ??= bgBehind.map((v) =>
							Math.min(...fresh.map((c) => C.ratio(C.over(c, v.bg), v.bg))),
						);
					}
				}
				if (a.border !== b.border) {
					const ca = opaque(a.borderColor, canvas);
					const cb = opaque(b.borderColor, canvas);
					if (ca && cb && C.ratio(ca, cb) >= 1.5) {
						strong.push("border");
						indicator ??= bgBehind.map((v) => C.ratio(C.over(C.parse(b.borderColor), v.bg), v.bg));
					} else {
						weakKinds.push("border (subtle)");
					}
				}
				if (a.deco !== b.deco && /underline|overline|line-through/.test(b.deco)) {
					strong.push("text-decoration");
				}
				if (a.pseudo !== b.pseudo) {
					strong.push("pseudo-element");
				}
				if (a.bg !== b.bg) {
					weakKinds.push("background");
				}
				if (a.color !== b.color) {
					weakKinds.push("color");
				}
				if (a.transform !== b.transform) {
					weakKinds.push("transform/opacity");
				}
			});
			const info = {
				sel: selPath(el),
				key: keyOf(el),
				text: snippet(
					el.textContent ||
						el.getAttribute("aria-label") ||
						[...(el.labels ?? [])].map((l) => l.textContent).join(" ") ||
						el.placeholder ||
						el.type ||
						"",
				),
				focusVisible: fv,
				hiddenInput: hidden(el),
				at: at(el),
			};
			if (strong.length === 0 && weakKinds.length === 0) {
				record(focus.fails, info);
			} else if (strong.length === 0) {
				record(focus.weak, { ...info, changes: [...new Set(weakKinds)] });
			} else if (
				indicator &&
				Math.min(...indicator) < 3 &&
				!strong.includes("outline:auto") &&
				strong.length === 1
			) {
				record(focus.lowContrast, {
					...info,
					indicator: strong[0],
					ratio: Math.round(Math.min(...indicator) * 100) / 100,
				});
			}
		}
		if (document.activeElement && document.activeElement !== document.body) {
			document.activeElement.blur();
		}
	}

	return { contrast, ui, leaks, leakChecked, focus, responsive };
}
