// Group identities and the comparison of two audit reports (audit.mjs --compare).
//
// A "group" is what the report lists as one row: the same problem on one or several pages. Its id
// is built from the fields that make two rows the same problem, never from counts or page lists.

/** category -> id of a group (or of a raw item, both carry the same fields) */
export const GROUP_ID = {
	contrast: (i) => `${i.kind}|${i.key}|${i.fg}|${i.bg}`,
	contrastUnknown: (i) => `${i.kind}|${i.key}`,
	ui: (i) => `${i.kind}|${i.key}|${i.fg}|${i.bg}`,
	leaks: (i) => `${i.prop}|${i.color}|${i.key}`,
	focus: (i) => i.key,
	focusWeak: (i) => `${i.key}|${i.changes.join()}`,
	focusLow: (i) => `${i.key}|${i.indicator}`,
	overflow: (i) => i.key,
	targets: (i) => i.key,
	errors: (i) => i.key,
};

/** the categories that are compared, in report order */
export const COMPARED = [
	["contrast", "Text contrast"],
	["ui", "Non-text contrast"],
	["leaks", "Foreign colours"],
	["focus", "Focus: no indicator"],
	["focusWeak", "Focus: colour/bg only"],
	["focusLow", "Focus: ring < 3:1"],
	["overflow", "H-overflow culprits"],
	["targets", "Touch targets < 24px"],
	["errors", "Console / request errors"],
];

const WHOLE = "all";

/**
 * Rows [theme, viewport, page, category, id, count] of a report. Reports written before the
 * fingerprints existed only have the groups (all pages and viewports merged): those become rows
 * with viewport and page "all", and `granular` is false.
 */
function rowsOf(report) {
	if (Array.isArray(report.fingerprints)) {
		return { rows: report.fingerprints, granular: true };
	}
	const rows = [];
	for (const [theme, cats] of Object.entries(report.groups ?? {})) {
		for (const [cat] of COMPARED) {
			for (const g of cats[cat] ?? []) {
				rows.push([theme, WHOLE, WHOLE, cat, GROUP_ID[cat](g), g.count]);
			}
		}
	}
	return { rows, granular: false };
}

const keyOf = (...parts) => parts.join("\u0000");

/**
 * @param {object} base baseline report (parsed audit.json)
 * @param {object} cur current report
 * @param {{top?: number, baseName?: string}} [opts]
 * @returns {{md: string, newGroups: number, fixedGroups: number, changedGroups: number,
 *   unchanged: boolean}}
 */
export function compareReports(base, cur, { top = 10, baseName = "baseline" } = {}) {
	const b = rowsOf(base);
	const c = rowsOf(cur);
	const granular = b.granular && c.granular;
	const notes = [];
	let baseRows = b.rows;
	let curRows = c.rows;
	if (!granular) {
		notes.push(
			"The baseline has no per-page fingerprints (written by an older audit.mjs): groups are compared per theme with all pages and viewports merged, and only the first 500 groups per category exist on either side.",
		);
		const collapse = (rows) =>
			rows.map(([theme, , , cat, id, count]) => [theme, WHOLE, WHOLE, cat, id, count]);
		baseRows = collapse(b.rows);
		curRows = collapse(c.rows);
	} else {
		// only runs that exist on both sides can be compared
		const runs = (rep) =>
			new Set(
				(rep.records ?? []).map((r) => keyOf(r.theme, r.viewport, r.page)).filter((k) => k !== ""),
			);
		const bruns = runs(base);
		const cruns = runs(cur);
		if (bruns.size && cruns.size) {
			const common = new Set([...bruns].filter((k) => cruns.has(k)));
			const dropped = bruns.size - common.size + (cruns.size - common.size);
			if (dropped > 0) {
				notes.push(
					`${bruns.size - common.size} baseline and ${cruns.size - common.size} current page runs (theme/viewport/page) exist on one side only and are left out; ${common.size} runs compared.`,
				);
			}
			const keep = (row) => common.has(keyOf(row[0], row[1], row[2]));
			baseRows = baseRows.filter(keep);
			curRows = curRows.filter(keep);
		}
	}

	// theme/viewport/category -> id -> count
	const tally = (rows) => {
		const out = new Map();
		for (const [theme, vp, , cat, id, count] of rows) {
			const k = keyOf(theme, vp, cat);
			const m = out.get(k) ?? new Map();
			m.set(id, (m.get(id) ?? 0) + count);
			out.set(k, m);
		}
		return out;
	};
	const bt = tally(baseRows);
	const ct = tally(curRows);
	const themes = Object.keys(cur.summary ?? {}).filter((t) => base.summary?.[t]);
	const viewports = granular
		? (cur.meta?.viewports ?? []).filter((v) => base.meta?.viewports?.includes(v))
		: [WHOLE];

	const lines = [];
	const details = [];
	let newGroups = 0;
	let fixedGroups = 0;
	let changedGroups = 0;
	let deltaTotal = 0;
	const sum = (m) => [...(m?.values() ?? [])].reduce((n, v) => n + v, 0);
	for (const theme of themes) {
		for (const vp of viewports) {
			for (const [cat, label] of COMPARED) {
				const k = keyOf(theme, vp, cat);
				const bm = bt.get(k) ?? new Map();
				const cm = ct.get(k) ?? new Map();
				if (bm.size === 0 && cm.size === 0) {
					continue;
				}
				const added = [...cm].filter(([id]) => !bm.has(id));
				const gone = [...bm].filter(([id]) => !cm.has(id));
				const both = [...cm].filter(([id]) => bm.has(id));
				const changed = both.filter(([id, n]) => n !== bm.get(id));
				const delta = sum(cm) - sum(bm);
				newGroups += added.length;
				fixedGroups += gone.length;
				changedGroups += changed.length;
				deltaTotal += delta;
				lines.push([
					theme,
					vp === WHOLE ? "all" : vp,
					label,
					added.length,
					gone.length,
					both.length - changed.length,
					changed.length,
					delta > 0 ? `+${delta}` : String(delta),
				]);
				const where = `${theme} / ${vp === WHOLE ? "all viewports" : vp} / ${label}`;
				const show = (title, list, fmt) => {
					if (list.length === 0) {
						return;
					}
					details.push(`- ${where}: ${title} (${list.length})`);
					for (const item of list.slice(0, top)) {
						details.push(`    - ${fmt(item)}`);
					}
					if (list.length > top) {
						details.push(`    - ... and ${list.length - top} more`);
					}
				};
				show("NEW", added, ([id, n]) => `\`${id}\` x${n}`);
				show("FIXED", gone, ([id, n]) => `\`${id}\` x${n}`);
				show("count changed", changed, ([id, n]) => `\`${id}\` ${bm.get(id)} -> ${n}`);
			}
		}
	}

	const unchanged = newGroups === 0 && fixedGroups === 0 && changedGroups === 0 && deltaTotal === 0;
	const md = [`## Comparison with ${baseName}`, ""];
	for (const note of notes) {
		md.push(`Note: ${note}`, "");
	}
	if (unchanged) {
		const total = lines.reduce((n, l) => n + l[5], 0);
		md.push(
			total === 0
				? `**No change**: no findings on either side for ${themes.join(", ")}.`
				: `**No change**: no new, fixed or changed groups in ${themes.join(", ")} (${total} groups unchanged).`,
			"",
		);
	} else {
		md.push(
			`**${newGroups} new, ${fixedGroups} fixed, ${changedGroups} with a different count**, total element delta ${deltaTotal > 0 ? "+" : ""}${deltaTotal}. Only categories with groups on either side are listed.`,
			"",
		);
	}
	if (lines.length) {
		const head = [
			"theme",
			"viewport",
			"category",
			"new",
			"fixed",
			"unchanged",
			"count changed",
			"element delta",
		];
		md.push(
			`| ${head.join(" | ")} |`,
			`| ${head.map(() => "---").join(" | ")} |`,
			...lines.map((l) => `| ${l.join(" | ")} |`),
			"",
		);
	}
	if (details.length) {
		md.push(...details, "");
	}
	return {
		md: md.join("\n"),
		newGroups,
		fixedGroups,
		changedGroups,
		unchanged,
	};
}
