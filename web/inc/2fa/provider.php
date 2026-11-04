<?php
/**
 * Shared helpers for the 2FA scripts (secret.php, check.php).
 *
 * The QR code is rendered locally as an inline SVG data URI with
 * bacon/bacon-qr-code (pure PHP, no Imagick, no network access). The TOTP
 * secret never leaves the server.
 */

use RobThree\Auth\TwoFactorAuth;
use RobThree\Auth\Providers\Qr\BaconQrCodeProvider;

require_once __DIR__ . "/../vendor/autoload.php";

/**
 * Issuer shown in authenticator apps: APP_NAME from hestia.conf.
 * The scripts run in CLI context (no session), so the file is read directly.
 */
function hestia_2fa_issuer(): string {
	$issuer = "";
	$hestia = getenv("HESTIA");
	if (empty($hestia)) {
		$hestia = "/usr/local/hestia";
	}
	$conf = @file_get_contents($hestia . "/conf/hestia.conf");
	if ($conf !== false && preg_match("/^APP_NAME=(['\"]?)(.*)\\1\\s*$/m", $conf, $m)) {
		$issuer = $m[2];
	}
	// ":" separates issuer and account in the otpauth label, control characters are not allowed
	$issuer = trim(preg_replace("/[:\\x00-\\x1f\\x7f]/", "", $issuer));
	return $issuer === "" ? "VylarisSpace" : $issuer;
}

function hestia_2fa_new(): TwoFactorAuth {
	return new TwoFactorAuth(new BaconQrCodeProvider(4, "#ffffff", "#000000", "svg"), hestia_2fa_issuer());
}
