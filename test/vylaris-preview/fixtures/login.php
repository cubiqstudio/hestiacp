<?php
// Login / password reset pages (web/login/index.php, web/reset/index.php, web/reset2fa).
// Variables: $error (string), $success (reset2fa). The session "login" array drives the step.

return [
	"login_login" => function (string $variant): array {
		return ["error" => $variant === "error" ? "Invalid username or password" : ""];
	},
	"login_login_a" => function (string $variant): array {
		return [
			"error" =>
				$variant === "error" ? "Ungültiger Benutzername oder ungültiges Passwort" : "",
		];
	},
	"login_login_1" => function (string $variant): array {
		$_SESSION["login"]["username"] = "jürgen.müller";
		return ["error" => $variant === "error" ? "Invalid username or password" : ""];
	},
	"login_login_2" => function (string $variant): array {
		$_SESSION["login"]["username"] = "admin";
		$_SESSION["login"]["password"] = "x";
		return ["error" => $variant === "error" ? "Invalid or missing 2FA token" : ""];
	},
	"login_reset_1" => function (string $variant): array {
		return [
			"error" =>
				$variant === "error" ? "Please wait 15 minutes before sending a new request." : "",
		];
	},
	"login_reset_2" => function (string $variant): array {
		$_GET["user"] = "admin";
		return ["error" => $variant === "error" ? "Invalid reset code" : ""];
	},
	"login_reset_3" => function (string $variant): array {
		$_GET["user"] = "admin";
		$_GET["code"] = "a1b2c3d4e5f6";
		return [
			"error" => $variant === "error" ? "Passwords do not match, please try again" : "",
		];
	},
	"login_reset2fa" => function (string $variant): array {
		return [
			"success" => $variant === "success",
			"error" => $variant === "error" ? "Invalid username or reset code" : "",
		];
	},
];
