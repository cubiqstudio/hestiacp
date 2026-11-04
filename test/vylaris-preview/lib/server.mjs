// Tiny static server: pre-rendered HTML, the built themes, and the real web/ tree.
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { rrdResponse } from "./rrd.mjs";

const MIME = {
	".html": "text/html; charset=utf-8",
	".css": "text/css; charset=utf-8",
	".js": "text/javascript; charset=utf-8",
	".mjs": "text/javascript; charset=utf-8",
	".json": "application/json; charset=utf-8",
	".map": "application/json; charset=utf-8",
	".svg": "image/svg+xml",
	".png": "image/png",
	".jpg": "image/jpeg",
	".gif": "image/gif",
	".ico": "image/x-icon",
	".woff2": "font/woff2",
	".woff": "font/woff",
	".ttf": "font/ttf",
	".txt": "text/plain; charset=utf-8",
};

function safeJoin(root, urlPath) {
	const full = path.normalize(path.join(root, decodeURIComponent(urlPath)));
	return full === root || full.startsWith(root + path.sep) ? full : null;
}

/**
 * @param {{cssDir: string, htmlDir: string, webRoot: string, notifications: unknown[]}} options
 * @returns {Promise<{port: number, close: () => Promise<void>}>}
 */
export function startServer({ cssDir, htmlDir, webRoot, notifications }) {
	const server = http.createServer((req, res) => {
		const url = new URL(req.url, "http://localhost");
		const pathname = url.pathname;

		const send = (status, body, type = "text/plain; charset=utf-8") => {
			res.writeHead(status, { "Content-Type": type, "Cache-Control": "no-store" });
			res.end(body);
		};
		const sendFile = (file) => {
			fs.readFile(file, (error, data) => {
				if (error) {
					send(404, `Not found: ${pathname}`);
					return;
				}
				send(200, data, MIME[path.extname(file).toLowerCase()] ?? "application/octet-stream");
			});
		};

		// Endpoints the page JavaScript calls (stubbed backend)
		if (pathname === "/list/notifications/") {
			send(200, JSON.stringify(notifications), MIME[".json"]);
			return;
		}
		if (pathname === "/delete/notification/") {
			send(200, "");
			return;
		}
		if (pathname === "/list/rrd/ajax.php" && req.method === "POST") {
			let raw = "";
			req.on("data", (chunk) => {
				raw += chunk;
			});
			req.on("end", () => {
				let payload = {};
				try {
					payload = JSON.parse(raw);
				} catch {
					// keep defaults
				}
				send(
					200,
					JSON.stringify(rrdResponse(payload.service ?? "la", payload.period ?? "daily")),
					MIME[".json"],
				);
			});
			return;
		}
		// Quick Install App cards: the installer thumbnails do not exist in this repo checkout
		if (/^\/src\/app\/WebApp\/Installers\/[^/]+\/[^/]+\.(png|jpe?g|svg)$/.test(pathname)) {
			const label = decodeURIComponent(pathname.split("/")[5] ?? "App");
			send(
				200,
				`<svg xmlns="http://www.w3.org/2000/svg" width="160" height="100" viewBox="0 0 160 100"><rect width="160" height="100" fill="#cbd5e1"/><text x="80" y="56" font-family="sans-serif" font-size="16" text-anchor="middle" fill="#334155">${label}</text></svg>`,
				"image/svg+xml",
			);
			return;
		}

		// Pre-rendered pages: /__preview/<theme>/<id>.html
		if (pathname.startsWith("/__preview/")) {
			const file = safeJoin(htmlDir, pathname.slice("/__preview/".length));
			file ? sendFile(file) : send(403, "Forbidden");
			return;
		}

		// Themes come from the harness build, never from web/css/themes
		if (pathname.startsWith("/css/themes/") && !pathname.startsWith("/css/themes/custom/")) {
			const file = safeJoin(cssDir, pathname.slice("/css/themes/".length));
			file ? sendFile(file) : send(403, "Forbidden");
			return;
		}

		const file = safeJoin(webRoot, pathname);
		if (!file) {
			send(403, "Forbidden");
			return;
		}
		sendFile(file);
	});

	return new Promise((resolve, reject) => {
		server.on("error", reject);
		server.listen(0, "127.0.0.1", () => {
			resolve({
				port: server.address().port,
				close: () => new Promise((done) => server.close(() => done())),
			});
		});
	});
}
