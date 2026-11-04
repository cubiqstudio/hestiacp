<?php
use function Hestiacp\quoteshellarg\quoteshellarg;

// Init
ob_start();
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

// Check token
verify_csrf($_GET);

if (($_SESSION["UPSTREAM_UPDATES"] ?? "no") !== "yes") {
	// Upstream update channels are switched off (UPSTREAM_UPDATES in hestia.conf)
	$_SESSION["error_msg"] = _(
		"Upstream updates are disabled. This server is updated through its own package source.",
	);
} elseif ($_SESSION["userContext"] === "admin") {
	if (!empty($_GET["pkg"])) {
		$v_pkg = quoteshellarg($_GET["pkg"]);
		exec(HESTIA_CMD . "v-update-sys-hestia " . $v_pkg, $output, $return_var);
	}

	if ($return_var != 0) {
		$error = implode("<br>", $output);
		if (empty($error)) {
			$error = sprintf(_("Error: %s update failed.", $v_pkg));
			$_SESSION["error_msg"] = $error;
		}
	}
	unset($output);
}

header("Location: /list/updates/");
exit();
