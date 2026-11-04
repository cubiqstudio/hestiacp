// Interaction steps from pages.json, executed with Playwright before the screenshot.

export const FAKE_WEBSOCKET = `
(() => {
	class FakeSocket extends EventTarget {
		constructor(url) {
			super()
			this.url = url
			this.readyState = 0
			setTimeout(() => {
				this.readyState = 1
				this.dispatchEvent(new Event('open'))
				const banner = [
					'Last login: Mon Jan  5 09:12:44 2026 from 198.51.100.23',
					'admin@srv01:~$ ls public_html',
					'index.php  wp-content  wp-config.php',
					'admin@srv01:~$ ',
				].join('\\r\\n')
				this.dispatchEvent(new MessageEvent('message', { data: banner }))
			}, 50)
		}
		send() {}
		close() {}
		addEventListener(type, listener, options) {
			super.addEventListener(type, listener, options)
		}
	}
	window.WebSocket = FakeSocket
})()
`;

const ACTIONS = [
	"click",
	"hover",
	"focus",
	"blur",
	"press",
	"fill",
	"type",
	"select",
	"check",
	"uncheck",
	"wait",
	"waitFor",
	"scrollTo",
	"eval",
	"clip",
];

/**
 * Run the steps of a page. Returns { clip, errors[] }. A failing step is recorded and the run
 * continues, so the screenshot still shows how far the page got.
 */
export async function runSteps(page, steps, viewportName) {
	const errors = [];
	let clip = null;
	for (const step of steps ?? []) {
		if (step.only && step.only !== viewportName) {
			continue;
		}
		if (step.skip && step.skip === viewportName) {
			continue;
		}
		const action = ACTIONS.find((name) => name in step);
		if (!action) {
			errors.push(`unknown step ${JSON.stringify(step)}`);
			continue;
		}
		const arg = step[action];
		try {
			switch (action) {
				case "click":
					await page
						.locator(arg)
						.first()
						.click({ timeout: 3000, force: Boolean(step.force) });
					break;
				case "hover":
					await page.locator(arg).first().hover({ timeout: 3000 });
					break;
				case "focus":
					await page.locator(arg).first().focus({ timeout: 3000 });
					break;
				case "blur":
					await page
						.locator(arg)
						.first()
						.evaluate((el) => el.blur());
					break;
				case "press":
					await page.keyboard.press(arg);
					break;
				case "fill":
					await page.locator(arg[0]).first().fill(arg[1], { timeout: 3000 });
					break;
				case "type":
					await page.locator(arg[0]).first().pressSequentially(arg[1], { timeout: 3000 });
					break;
				case "select":
					await page.locator(arg[0]).first().selectOption(arg[1], { timeout: 3000 });
					break;
				case "check":
					await page.locator(arg).first().check({ timeout: 3000 });
					break;
				case "uncheck":
					await page.locator(arg).first().uncheck({ timeout: 3000 });
					break;
				case "wait":
					await page.waitForTimeout(arg);
					break;
				case "waitFor":
					await page.locator(arg).first().waitFor({ state: "visible", timeout: 3000 });
					break;
				case "scrollTo":
					await page.locator(arg).first().scrollIntoViewIfNeeded({ timeout: 3000 });
					break;
				case "eval":
					await page.evaluate(arg);
					break;
				case "clip":
					clip = arg;
					break;
			}
		} catch (error) {
			errors.push(`step ${action} ${JSON.stringify(arg)}: ${String(error.message).split("\n")[0]}`);
		}
	}
	return { clip, errors };
}
