<?php
// Updates from the own package source (VYLARIS_UPDATES in hestia.conf), admin only
ob_start();
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

// Check token
verify_csrf($_GET);

if (($_SESSION["VYLARIS_UPDATES"] ?? "no") !== "yes") {
	$_SESSION["error_msg"] = _(
		"Updates from the own package source are disabled on this server (VYLARIS_UPDATES).",
	);
} elseif ($_SESSION["userContext"] === "admin") {
	// "check" only refreshes the package source, "install" starts the update in the background
	$action = $_GET["action"] ?? "";
	if ($action === "check") {
		exec(HESTIA_CMD . "v-update-sys-vylaris check 2>&1", $output, $return_var);
		if ($return_var != 0) {
			$_SESSION["error_msg"] = implode(" ", $output) ?: _("The update failed.");
		} else {
			$_SESSION["ok_msg"] = _("The package source has been checked.");
		}
	} elseif ($action === "install") {
		exec(HESTIA_CMD . "v-update-sys-vylaris background 2>&1", $output, $return_var);
		if ($return_var != 0) {
			$_SESSION["error_msg"] = implode(" ", $output) ?: _("The update failed.");
		} else {
			$_SESSION["ok_msg"] = sprintf(
				_("The update of %s has been started. The result is shown in the log."),
				$_SESSION["APP_NAME"] ?? "VylarisSpace",
			);
		}
	}
	unset($output);
}

header("Location: /list/updates/");
exit();
