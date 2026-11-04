export default async function initWebTerminal() {
	const container = document.querySelector('.js-web-terminal');
	if (!container) {
		return;
	}

	const Terminal = await loadXterm();
	const terminal = new Terminal({ theme: getTerminalTheme(container) });
	let Addon = null;
	if (typeof WebGL2RenderingContext !== 'undefined') {
		Addon = await loadWebGLAddon();
	} else {
		Addon = await loadCanvasAddon();
	}
	terminal.loadAddon(new Addon());
	terminal.open(container);
	terminal.focus();

	const socket = new WebSocket(`wss://${window.location.host}/_shell/`);
	socket.addEventListener('open', (_) => {
		terminal.focus();
		terminal.onData((data) => socket.send(data));
		socket.addEventListener('message', (evt) => terminal.write(evt.data));
	});
	socket.addEventListener('error', (_) => {
		terminal.reset();
		terminal.writeln('Connection error.');
	});
	socket.addEventListener('close', (evt) => {
		if (evt.wasClean) {
			terminal.reset();
			terminal.writeln(evt.reason ?? 'Connection closed.');
		}
	});
}

// Maps xterm theme options to the CSS custom properties that supply them
const terminalThemeVariables = {
	background: '--vy-surface-sunken',
	foreground: '--vy-text',
	cursor: '--vy-text',
	selectionBackground: '--vy-selection',
	black: '--vy-text-muted',
	red: '--vy-danger',
	green: '--vy-success',
	yellow: '--vy-warning',
	blue: '--vy-info',
	magenta: '--vy-icon-purple',
	cyan: '--vy-icon-teal',
	white: '--vy-text',
	brightBlack: '--vy-text-muted',
	brightRed: '--vy-danger',
	brightGreen: '--vy-success',
	brightYellow: '--vy-warning',
	brightBlue: '--vy-info',
	brightMagenta: '--vy-icon-purple',
	brightCyan: '--vy-icon-teal',
	brightWhite: '--vy-text',
};

// Builds the xterm theme from the theme's CSS variables. Variables that are not defined
// (themes without them) are skipped, so xterm keeps its default colours for those entries.
function getTerminalTheme(container) {
	const styles = getComputedStyle(container);
	const theme = {};
	for (const [option, variable] of Object.entries(terminalThemeVariables)) {
		const value = styles.getPropertyValue(variable).trim();
		if (value) {
			theme[option] = value;
		}
	}
	return theme;
}

/** @returns {Promise<typeof import("@xterm/xterm").Terminal>} */
async function loadXterm() {
	// NOTE: String expression used to prevent ESBuild from resolving
	// the import on build (xterm is a separate bundle)
	const xtermBundlePath = '/js/dist/xterm.min.js';
	const xtermModule = await import(`${xtermBundlePath}`);
	return xtermModule.default.Terminal;
}

/** @returns {Promise<typeof import("@xterm/addon-webgl").WebglAddon>} */
async function loadWebGLAddon() {
	// NOTE: String expression used to prevent ESBuild from resolving
	// the import on build (xterm-addon-webgl is a separate bundle)
	const xtermBundlePath = '/js/dist/xterm-addon-webgl.min.js';
	const xtermModule = await import(`${xtermBundlePath}`);
	return xtermModule.default.WebglAddon;
}

/** @returns {Promise<typeof import("@xterm/addon-canvas").CanvasAddon>} */
async function loadCanvasAddon() {
	// NOTE: String expression used to prevent ESBuild from resolving
	// the import on build (xterm-addon-canvas is a separate bundle)
	const xtermBundlePath = '/js/dist/xterm-addon-canvas.min.js';
	const xtermModule = await import(`${xtermBundlePath}`);
	return xtermModule.default.CanvasAddon;
}
