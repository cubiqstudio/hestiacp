<?php
/**
 * Stub environment for rendering the real Hestia templates without a backend.
 *
 * Nothing in here executes the controllers (web/list|add|edit/.../index.php) or any v-* binary.
 * Real helper functions from web/inc/*.php are imported by name via the tokenizer so they stay
 * in sync with the application; everything that would shell out is replaced by a stub.
 */

namespace Hestiacp\quoteshellarg {
	function quoteshellarg($arg) {
		return escapeshellarg((string) $arg);
	}
}

namespace {
	error_reporting(E_ALL);
	ini_set("display_errors", "0");
	ini_set("html_errors", "0");

	define("PREVIEW_ROOT", dirname(__DIR__));
	define("HESTIA_ROOT", realpath(PREVIEW_ROOT . "/../.."));

	/** Collected PHP problems (warnings, notices, deprecations) for the page that is rendered. */
	$GLOBALS["__preview_problems"] = [];
	set_error_handler(function ($errno, $errstr, $errfile, $errline) {
		if (!(error_reporting() & $errno)) {
			return false;
		}
		$labels = [
			E_WARNING => "Warning",
			E_NOTICE => "Notice",
			E_DEPRECATED => "Deprecated",
			E_USER_WARNING => "Warning",
			E_USER_NOTICE => "Notice",
			E_USER_DEPRECATED => "Deprecated",
		];
		$GLOBALS["__preview_problems"][] =
			($labels[$errno] ?? "Error") .
			": " .
			$errstr .
			" in " .
			str_replace(HESTIA_ROOT . "/", "", $errfile) .
			":" .
			$errline;
		return true;
	});

	/**
	 * Copy top level functions (by name) out of a real source file and declare them here.
	 */
	function preview_import_functions(string $file, array $names, int $maxDepth = 0): void {
		$tokens = PhpToken::tokenize(file_get_contents($file));
		$count = count($tokens);
		$depth = 0;
		for ($i = 0; $i < $count; $i++) {
			$t = $tokens[$i];
			if (
				$t->id === T_CURLY_OPEN ||
				$t->id === T_DOLLAR_OPEN_CURLY_BRACES ||
				$t->text === "{"
			) {
				$depth++;
				continue;
			}
			if ($t->text === "}") {
				$depth--;
				continue;
			}
			if ($depth > $maxDepth || $t->id !== T_FUNCTION) {
				continue;
			}
			// Find the function name (skip whitespace); closures have no name and are skipped.
			$j = $i + 1;
			while ($j < $count && $tokens[$j]->id === T_WHITESPACE) {
				$j++;
			}
			if ($tokens[$j]->id !== T_STRING || !in_array($tokens[$j]->text, $names, true)) {
				continue;
			}
			$name = $tokens[$j]->text;
			// Collect until the matching closing brace of the body.
			$src = "";
			$bodyDepth = 0;
			$started = false;
			for ($k = $i; $k < $count; $k++) {
				$tk = $tokens[$k];
				// __FILE__ / __DIR__ must keep pointing at the original source file.
				if ($tk->id === T_FILE) {
					$src .= var_export($file, true);
				} elseif ($tk->id === T_DIR) {
					$src .= var_export(dirname($file), true);
				} else {
					$src .= $tk->text;
				}
				if (
					$tk->id === T_CURLY_OPEN ||
					$tk->id === T_DOLLAR_OPEN_CURLY_BRACES ||
					$tk->text === "{"
				) {
					$bodyDepth++;
					$started = true;
				} elseif ($tk->text === "}") {
					$bodyDepth--;
					if ($started && $bodyDepth === 0) {
						break;
					}
				}
			}
			if (!function_exists($name)) {
				eval($src);
			}
			$i = $k;
		}
	}

	// ---------------------------------------------------------------------------------------------
	// Real code from the application
	// ---------------------------------------------------------------------------------------------
	// tohtml() is declared inside an `if (!function_exists())` block, hence the extra depth.
	preview_import_functions(
		HESTIA_ROOT . "/web/inc/helpers.php",
		[
			"tohtml",
			"theme_display_name",
			"docs_url",
			"legacy_themes",
			"visible_themes",
			"resolve_theme",
		],
		1,
	);
	preview_import_functions(HESTIA_ROOT . "/web/inc/main.php", [
		"render_page",
		"top_panel",
		"humanize_time",
		"humanize_usage_size",
		"humanize_usage_measure",
		"get_percentage",
		"translate_date",
		"convert_datetime",
		"show_alert_message",
		"list_timezones",
		"unset_alerts",
		"ipUsed",
		"verify_csrf",
	]);
	preview_import_functions(HESTIA_ROOT . "/web/inc/i18n.php", [
		"detect_user_language",
		"htmlify_trans",
		"translate_json",
		"translate_email",
	]);

	// ---------------------------------------------------------------------------------------------
	// Stubs for everything that would talk to the Hestia backend
	// ---------------------------------------------------------------------------------------------
	define("HESTIA_DIR_BIN", "/usr/local/hestia/bin/");
	define("HESTIA_CMD", "/usr/bin/sudo /usr/local/hestia/bin/");
	define("DEFAULT_PHP_VERSION", "php-8.3");

	function get_hostname() {
		return "srv01.vylaris.example";
	}

	function display_title($tab) {
		$array1 = ["{{page}}", "{{hostname}}", "{{ip}}", "{{appname}}"];
		$array2 = [$tab, get_hostname(), $_SERVER["REMOTE_ADDR"], $_SESSION["APP_NAME"]];
		return str_replace($array1, $array2, $_SESSION["TITLE"]);
	}

	function get_user_data($user) {
		$users = $GLOBALS["__preview_users"];
		$user = trim((string) $user, "'");
		return [$user => $users[$user] ?? $users["admin"]];
	}

	function is_it_mysql_or_mariadb() {
		return "MariaDB";
	}

	function backendtpl_with_webdomains() {
		return ["WordPress-FPM"];
	}

	function check_return_code($return_var, $output) {}

	/**
	 * Fixed, anonymised $_SERVER. The real one of the build machine is never exposed because the
	 * debug panel prints it.
	 */
	function preview_reset_server(): void {
		$_SERVER = [
			"HESTIA" => HESTIA_ROOT,
			"DOCUMENT_ROOT" => HESTIA_ROOT . "/web",
			"HTTP_HOST" => "srv01.vylaris.example:8083",
			"SERVER_NAME" => "srv01.vylaris.example",
			"SERVER_ADDR" => "203.0.113.10",
			"SERVER_PORT" => "8083",
			"REMOTE_ADDR" => "198.51.100.23",
			"REQUEST_METHOD" => "GET",
			"REQUEST_URI" => "/",
			"SCRIPT_NAME" => "/index.php",
			"HTTPS" => "on",
			"HTTP_USER_AGENT" => "Mozilla/5.0 (preview)",
			"HTTP_ACCEPT_LANGUAGE" => "de,en;q=0.8",
			"REQUEST_TIME" => 1767268800,
		];
	}

	/** Minimal replacement of the $_SESSION that web/login and main.php would set up. */
	function preview_default_session(string $theme, string $lang): array {
		return [
			// Identity and context
			"user" => "admin",
			"look" => "",
			"userContext" => "admin",
			"role" => "admin",
			"login_shell" => "bash",
			"ROOT_USER" => "admin",
			"token" => "preview0123456789abcdef0123456789ab",
			"user_combined_ip" => "198.51.100.23",
			"LAST_ACTIVITY" => 1767268800,
			"INACTIVE_SESSION_TIMEOUT" => 60,
			"userSortOrder" => "name",
			"userTheme" => $theme,
			"THEME" => $theme,
			"language" => $lang,
			"LANGUAGE" => $lang,
			// Branding / app
			"APP_NAME" => "VylarisSpace",
			"TITLE" => "{{page}} - {{appname}}",
			"VERSION" => "1.10.5",
			"RELEASE_BRANCH" => "release",
			"DEBUG_MODE" => "false",
			"DEMO_MODE" => "no",
			"HIDE_DOCS" => "yes",
			"UPDATE_AVAILABLE" => "no",
			"LOGIN_STYLE" => "default",
			// Installed services
			"WEB_SYSTEM" => "apache2",
			"WEB_BACKEND" => "php-fpm",
			"WEB_BACKEND_POOL" => "multiple",
			"PROXY_SYSTEM" => "nginx",
			"DNS_SYSTEM" => "bind9",
			"DNS_CLUSTER_SYSTEM" => "hestia-zone",
			"MAIL_SYSTEM" => "exim4",
			"IMAP_SYSTEM" => "dovecot",
			"ANTIVIRUS_SYSTEM" => "clamav-daemon",
			"ANTISPAM_SYSTEM" => "spamassassin",
			"DB_SYSTEM" => "mysql,pgsql",
			"FTP_SYSTEM" => "vsftpd",
			"CRON_SYSTEM" => "cron",
			"BACKUP_SYSTEM" => "local",
			"FIREWALL_SYSTEM" => "iptables",
			"FIREWALL_EXTENSION" => "fail2ban",
			"WEBMAIL_SYSTEM" => "roundcube",
			"WEBMAIL_ALIAS" => "webmail",
			"DB_PMA_ALIAS" => "phpmyadmin",
			"DB_PGA_ALIAS" => "phppgadmin",
			"PHPMYADMIN_KEY" => "",
			"PMA_RESTRICT_ACCESS" => "no",
			"SUPPORT_DNSSEC" => "yes",
			"FILE_MANAGER" => "true",
			"DISK_QUOTA" => "yes",
			"WEB_TERMINAL" => "true",
			"API" => "yes",
			"API_SYSTEM" => "1",
			"API_ALLOWED_IP" => "allow-all",
			"RESOURCES_LIMIT" => "no",
			"ENFORCE_SUBDOMAIN_OWNERSHIP" => "yes",
			"PLUGIN_APP_INSTALLER" => "true",
			"UPGRADE_SEND_EMAIL" => "true",
			"UPGRADE_SEND_EMAIL_LOG" => "false",
			// Policies
			"POLICY_USER_VIEW_SUSPENDED" => "no",
			"POLICY_USER_VIEW_LOGS" => "yes",
			"POLICY_USER_DELETE_LOGS" => "yes",
			"POLICY_USER_EDIT_DETAILS" => "yes",
			"POLICY_USER_EDIT_WEB_TEMPLATES" => "yes",
			"POLICY_USER_EDIT_DNS_TEMPLATES" => "yes",
			"POLICY_USER_CHANGE_THEME" => "yes",
			"POLICY_SYSTEM_PROTECTED_ADMIN" => "no",
			"POLICY_SYSTEM_HIDE_ADMIN" => "no",
			"POLICY_SYSTEM_HIDE_SERVICES" => "no",
			"POLICY_SYSTEM_PASSWORD_RESET" => "yes",
			"POLICY_SYSTEM_ENABLE_BACON" => "no",
			"POLICY_CSRF_STRICTNESS" => "1",
			"POLICY_SYNC_SKELETON" => "yes",
			"POLICY_SYNC_ERROR_DOCUMENTS" => "yes",
			"POLICY_BACKUP_SUSPENDED_USERS" => "no",
		];
	}

	/** Build the gettext environment. German needs a compiled locale (see shoot.mjs, LOCPATH). */
	function preview_setup_gettext(string $lang): string {
		putenv("LANGUAGE=" . $lang);
		$locales = $lang === "de" ? ["de_DE.UTF-8"] : [];
		$active = setlocale(LC_ALL, ...array_merge($locales, ["en_US.UTF-8", "C.UTF-8", "C"]));
		bindtextdomain("hestiacp", HESTIA_ROOT . "/web/locale");
		textdomain("hestiacp");
		bind_textdomain_codeset("hestiacp", "UTF-8");
		return (string) $active;
	}
}
