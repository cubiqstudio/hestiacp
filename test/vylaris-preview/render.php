<?php
/**
 * Render one preview page through the real Hestia templates, without a backend.
 *
 *   php render.php --page list-web [--theme vylaris] [--manifest pages.json] [--out file.html]
 *   php render.php --list                 (print all page ids as JSON)
 *
 * Exit code 0: clean render. Exit code 3: rendered, but PHP warnings/notices occurred (listed on
 * stderr, one per line, prefixed with "PHP: "). Exit code 2: hard failure.
 */

require __DIR__ . "/lib/bootstrap.php";
require __DIR__ . "/lib/fx.php";

$opts = getopt("", ["page:", "theme:", "manifest:", "out:", "list", "lang:"]);
$manifestPath = $opts["manifest"] ?? __DIR__ . "/pages.json";
$manifest = json_decode(file_get_contents($manifestPath), true);
if (!is_array($manifest) || !isset($manifest["pages"])) {
	fwrite(STDERR, "Invalid manifest: " . $manifestPath . "\n");
	exit(2);
}

if (isset($opts["list"])) {
	echo json_encode(array_column($manifest["pages"], "id")), "\n";
	exit(0);
}

$entry = null;
foreach ($manifest["pages"] as $candidate) {
	if ($candidate["id"] === ($opts["page"] ?? null)) {
		$entry = $candidate;
		break;
	}
}
if ($entry === null) {
	fwrite(STDERR, "Unknown page: " . ($opts["page"] ?? "(none)") . "\n");
	exit(2);
}

$theme = $opts["theme"] ?? "default";
$lang = $opts["lang"] ?? ($entry["lang"] ?? "en");

// ---- environment -------------------------------------------------------------------------------
preview_reset_server();
$_GET = $entry["get"] ?? [];
$_POST = $entry["post"] ?? [];
$_COOKIE = [];
$_SESSION = preview_default_session($theme, $lang);
foreach ($entry["session"] ?? [] as $key => $value) {
	$_SESSION[$key] = $value;
}
// The theme under test always wins, an entry may only change language and policies.
$_SESSION["userTheme"] = $theme;
$_SESSION["THEME"] = $theme;
$_SESSION["language"] = $lang;
$_SESSION["LANGUAGE"] = $lang;
$_SERVER["REQUEST_URI"] = $entry["uri"] ?? "/";
$locale = preview_setup_gettext($lang);
if ($lang !== "en" && stripos($locale, $lang) !== 0) {
	fwrite(
		STDERR,
		"PHP: locale for '$lang' is not available (got '$locale'); text stays English\n",
	);
}

// Users known to the stub backend (v-list-user).
$GLOBALS["__preview_users"] = fx_users($entry["panel"] ?? []);

// Globals that main.php provides to every template.
$i = 0;
$TAB = $entry["tab"] ?? "WEB";
$user_plain = htmlentities($_SESSION["look"] !== "" ? $_SESSION["look"] : $_SESSION["user"]);
$user = escapeshellarg($_SESSION["look"] !== "" ? $_SESSION["look"] : $_SESSION["user"]);
$read_only = false;
require HESTIA_ROOT . "/web/inc/policies.php"; // $read_only, $display_mode
define("JS_LATEST_UPDATE", "v=" . $_SESSION["VERSION"]);

// ---- fixture data ------------------------------------------------------------------------------
$fixtures = fx_load_fixtures();
$fixtureKey = $entry["fixture"] ?? str_replace(["/", "-"], "_", $entry["template"]);
if (!isset($fixtures[$fixtureKey])) {
	fwrite(STDERR, "Missing fixture '$fixtureKey' for page " . $entry["id"] . "\n");
	exit(2);
}
$vars = $fixtures[$fixtureKey]($entry["variant"] ?? "", $entry);
foreach ($vars as $name => $value) {
	$GLOBALS[$name] = $value;
}

// ---- render ------------------------------------------------------------------------------------
$mode = $entry["mode"] ?? "app";
$templateFile = HESTIA_ROOT . "/web/templates/pages/" . $entry["template"] . ".php";
if (!is_file($templateFile)) {
	fwrite(STDERR, "Template not found: " . $templateFile . "\n");
	exit(2);
}

ob_start();
try {
	if ($mode === "app") {
		render_page($user, $TAB, $entry["template"]);
	} elseif ($mode === "login") {
		$token = $_SESSION["token"];
		require HESTIA_ROOT . "/web/templates/header.php";
		require $templateFile;
		require HESTIA_ROOT . "/web/templates/includes/login-footer.php";
	} elseif ($mode === "standalone") {
		// list_server_info.php / list_weblog.php print their own page shell and the controller
		// appends the raw command output, then closes the markup (end_html()).
		require $templateFile;
		echo $body ?? "";
		echo "</pre>\n</div>\n</main>\n";
		include HESTIA_ROOT . "/web/templates/includes/app-footer.php";
		echo "</div>\n";
		include HESTIA_ROOT . "/web/templates/includes/jump-to-top-link.php";
		echo "</body>\n</html>\n";
	} else {
		throw new RuntimeException("Unknown mode: " . $mode);
	}
} catch (Throwable $e) {
	$GLOBALS["__preview_problems"][] =
		"Fatal error: " .
		$e->getMessage() .
		" in " .
		str_replace(HESTIA_ROOT . "/", "", $e->getFile()) .
		":" .
		$e->getLine();
}
$html = ob_get_clean();

// Safety net: the error handler swallows warnings, but fail loudly if any leaked into the markup.
if (
	preg_match_all(
		'/(?:Warning|Notice|Fatal error|Deprecated|Parse error): [^\n<]+ in \/\S+ on line \d+/',
		$html,
		$m,
	)
) {
	foreach ($m[0] as $leak) {
		$GLOBALS["__preview_problems"][] = "Leaked into output: " . $leak;
	}
}

$target = $opts["out"] ?? null;
if ($target) {
	if (!is_dir(dirname($target))) {
		mkdir(dirname($target), 0777, true);
	}
	file_put_contents($target, $html);
} else {
	echo $html;
}

$problems = array_values(array_unique($GLOBALS["__preview_problems"]));
foreach ($problems as $problem) {
	fwrite(STDERR, "PHP: " . $problem . "\n");
}
exit(count($problems) ? 3 : 0);
