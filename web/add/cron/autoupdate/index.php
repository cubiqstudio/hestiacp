<?php
ob_start();
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

// Check token
verify_csrf($_GET);

$own_updates = ($_SESSION["VYLARIS_UPDATES"] ?? "no") === "yes";
$upstream_updates = ($_SESSION["UPSTREAM_UPDATES"] ?? "no") === "yes";

if (!$own_updates && !$upstream_updates) {
	// Upstream update channels are switched off (UPSTREAM_UPDATES in hestia.conf)
	$_SESSION["error_msg"] = _(
		"Upstream updates are disabled. This server is updated through its own package source.",
	);
} elseif (
	($_SESSION["userContext"] === "admin" && $_SESSION["POLICY_SYSTEM_HIDE_SERVICES"] == "no") ||
	$_SESSION["user"] == $_SESSION["ROOT_USER"]
) {
	// The own package source wins when both channels are switched on
	$cmd = $own_updates ? "v-add-cron-vylaris-autoupdate" : "v-add-cron-hestia-autoupdate";
	exec(HESTIA_CMD . $cmd, $output, $return_var);
	unset($output);
}

header("Location: /list/updates/");
exit();
