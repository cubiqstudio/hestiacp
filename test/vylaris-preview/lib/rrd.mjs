// Deterministic sample data for POST /list/rrd/ajax.php (Task Monitor charts).
const END = 1767268800; // fixed "now" so charts look the same on every run

const PERIODS = {
	daily: { step: 300, rows: 288 },
	weekly: { step: 1800, rows: 336 },
	monthly: { step: 7200, rows: 360 },
	yearly: { step: 86400, rows: 365 },
	biennially: { step: 172800, rows: 365 },
	triennially: { step: 259200, rows: 365 },
};

const SERVICES = {
	la: {
		unit: "Points",
		legend: ["1 min", "5 min", "15 min"],
		base: [0.5, 0.45, 0.4],
		amp: [0.5, 0.3, 0.2],
	},
	mem: {
		unit: "Mbytes",
		legend: ["Used", "Cached", "Free"],
		base: [3100, 4000, 800],
		amp: [500, 300, 400],
	},
	apache2: { unit: "Connections", legend: ["Connections"], base: [40], amp: [25] },
	nginx: { unit: "Connections", legend: ["Connections"], base: [120], amp: [60] },
	mail: { unit: "Queue Size", legend: ["Queue"], base: [6], amp: [5] },
	ssh: { unit: "Connections", legend: ["Connections"], base: [2], amp: [2] },
	net: { unit: "KBytes", legend: ["Incoming", "Outgoing"], base: [900, 1400], amp: [600, 900] },
	db: { unit: "Queries", legend: ["Queries"], base: [140], amp: [90] },
};

function lcg(seed) {
	let s = seed;
	return () => {
		s = (s * 1664525 + 1013904223) % 4294967296;
		return s / 4294967296;
	};
}

export function rrdResponse(service, period) {
	const conf = PERIODS[period] ?? PERIODS.daily;
	const key = service.startsWith("net_")
		? "net"
		: service.startsWith("mysql_") || service.startsWith("pgsql_")
			? "db"
			: service;
	const spec = SERVICES[key] ?? SERVICES.la;
	const rand = lcg([...service].reduce((a, c) => a + c.charCodeAt(0), 7));
	const data = [];
	for (let i = 0; i < conf.rows; i++) {
		data.push(
			spec.base.map((base, series) => {
				const wave = Math.sin((i / conf.rows) * Math.PI * 4 + series);
				const value = Math.max(0, base + spec.amp[series] * (0.6 * wave + 0.4 * rand()));
				return Math.round(value * 100) / 100;
			}),
		);
	}
	return {
		meta: {
			start: END - conf.rows * conf.step,
			end: END,
			step: conf.step,
			rows: conf.rows,
			legend: spec.legend,
		},
		data,
		service,
		unit: spec.unit,
	};
}
