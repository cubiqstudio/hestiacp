<?php
ob_start();
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

// Check token
verify_csrf($_GET);

if (($_SESSION["UPSTREAM_UPDATES"] ?? "no") !== "yes") {
	// Upstream update channels are switched off (UPSTREAM_UPDATES in hestia.conf)
	$_SESSION["error_msg"] = _(
		"Upstream updates are disabled. This server is updated through its own package source.",
	);
} elseif (
	($_SESSION["userContext"] === "admin" && $_SESSION["POLICY_SYSTEM_HIDE_SERVICES"] == "no") ||
	$_SESSION["user"] == $_SESSION["ROOT_USER"]
) {
	exec(HESTIA_CMD . "v-add-cron-hestia-autoupdate", $output, $return_var);
	unset($output);
}

header("Location: /list/updates/");
exit();
