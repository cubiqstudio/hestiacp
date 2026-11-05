<?php

ob_start();
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

// Check token
verify_csrf($_GET);

if (
	($_SESSION["userContext"] === "admin" && $_SESSION["POLICY_SYSTEM_HIDE_SERVICES"] == "no") ||
	$_SESSION["user"] == $_SESSION["ROOT_USER"]
) {
	// Removes the cron job of the own package source when that channel is on
	// and the cron job of the upstream channel otherwise (or additionally)
	$own_updates = ($_SESSION["VYLARIS_UPDATES"] ?? "no") === "yes";
	if ($own_updates) {
		exec(HESTIA_CMD . "v-delete-cron-vylaris-autoupdate", $output, $return_var);
		unset($output);
	}
	if (!$own_updates || ($_SESSION["UPSTREAM_UPDATES"] ?? "no") === "yes") {
		exec(HESTIA_CMD . "v-delete-cron-hestia-autoupdate", $output, $return_var);
		unset($output);
	}
}

header("Location: /list/updates/");
exit();
