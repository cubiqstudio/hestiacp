<?php
// More list pages: backups, services, statistics, logs, updates, search, task monitor, web apps ...

function fx_backups(): array {
	$data = [];
	for ($n = 0; $n < 8; $n++) {
		$name = "admin." . fx_date($n * 2) . "_03-" . sprintf("%02d", $n * 3) . "-07.tar";
		$data[$name] = [
			"TYPE" => $n % 3 === 0 ? "manual" : "cron",
			"SIZE" => (string) [4380, 5120, 880, 22010, 330, 9120, 52000, 120][$n],
			"RUNTIME" => (string) [3, 12, 1, 75, 2, 9, 130, 1][$n],
			"TIME" => "03:" . sprintf("%02d", $n * 3) . ":07",
			"DATE" => fx_date($n * 2),
			"WEB" => $n === 3 ? "" : "vylaris-group.eu,müller-und-söhne.de,example.org",
			"DNS" => $n % 2 ? "" : "vylaris-group.eu,example.org",
			"MAIL" => $n === 5 ? "" : "vylaris-group.eu",
			"DB" => $n === 4 ? "" : "admin_wp_main,admin_shop,admin_nextcloud",
			"CRON" => $n === 2 ? "" : "yes",
			"UDIR" => $n === 6 ? "" : "uploads,.config",
		];
	}
	return $data;
}

function fx_sys_info(): array {
	return [
		"sysinfo" => [
			"HOSTNAME" => "srv01.vylaris.example",
			"OS" => "Debian",
			"VERSION" => "12",
			"ARCH" => "x86_64",
			"UPTIME" => "11340",
			"LOADAVERAGE" => "0.42",
			"HESTIA" => "1.10.5",
			"RELEASE" => "release",
		],
	];
}

function fx_services(): array {
	$rows = [
		["nginx", "running", "Web Server (nginx)", 2, 48, 120000],
		["apache2", "running", "Web Server (apache2)", 7, 212, 120000],
		["php8.3-fpm", "running", "PHP Process Manager", 3, 96, 120000],
		["php8.2-fpm", "stopped", "PHP Process Manager", 0, 0, 0],
		["bind9", "running", "DNS Server", 1, 22, 119000],
		["exim4", "running", "Mail Server (SMTP)", 2, 31, 119000],
		["dovecot", "running", "IMAP/POP3 Server", 4, 28, 118000],
		["clamav-daemon", "running", "Antivirus", 4, 1180, 118000],
		["spamassassin", "running", "Antispam", 6, 480, 118000],
		["mariadb", "running", "Database Server (MariaDB)", 12, 640, 117000],
		["postgresql", "stopped", "Database Server (PostgreSQL)", 0, 0, 0],
		["vsftpd", "running", "FTP Server", 1, 4, 117000],
		["cron", "running", "Job Scheduler", 0, 2, 117000],
		["fail2ban", "running", "Intrusion Prevention", 2, 38, 117000],
		["hestia", "running", "Hestia Control Panel", 5, 74, 117000],
		["ssh", "running", "Secure Shell Daemon with a very long description line", 1, 6, 117000],
	];
	$data = [];
	foreach ($rows as [$name, $state, $system, $cpu, $mem, $rtime]) {
		$data[$name] = [
			"SYSTEM" => $system,
			"STATE" => $state,
			"CPU" => (string) $cpu,
			"MEM" => (string) $mem,
			"RTIME" => (string) $rtime,
		];
	}
	return $data;
}

function fx_stats(bool $single = false): array {
	$data = [];
	for ($n = 0; $n < ($single ? 3 : 6); $n++) {
		$month = fx_date($n * 31);
		$month = substr($month, 0, 7) . "-01";
		$data[$month] = [
			"IP_OWNED" => (string) ($single ? 1 : 4),
			"U_BACKUPS" => (string) (4 - ($n % 3)),
			"U_BANDWIDTH" => (string) (9120 + $n * 3000),
			"BANDWIDTH" => $single ? "102400" : "unlimited",
			"U_DISK" => (string) (48210 - $n * 2100),
			"DISK_QUOTA" => $single ? "10240" : "unlimited",
			"U_DISK_DIRS" => (string) (3100 - $n * 100),
			"U_DISK_WEB" => (string) (32000 - $n * 900),
			"U_DISK_MAIL" => (string) (9100 - $n * 300),
			"U_DISK_DB" => (string) (4010 - $n * 150),
			"U_WEB_DOMAINS" => (string) (14 - $n),
			"U_WEB_ALIASES" => (string) (27 - $n),
			"U_WEB_SSL" => (string) (11 - $n),
			"U_MAIL_DOMAINS" => "5",
			"U_MAIL_ACCOUNTS" => (string) (17 - $n),
			"U_DNS_DOMAINS" => "6",
			"U_DNS_RECORDS" => (string) (58 - $n * 2),
			"U_DATABASES" => (string) (11 - $n),
			"U_CRON_JOBS" => "7",
		];
	}
	return $data;
}

function fx_logs(int $count = 24): array {
	$messages = [
		["Info", "Auth", "Logged in successfully (IP: 198.51.100.23)"],
		["Info", "Web", "Added web domain müller-und-söhne.de"],
		[
			"Warning",
			"Security",
			"User impersonation session started (User: 'bernd', Administrator: 'admin')",
		],
		[
			"Error",
			"Backup",
			"Backup failed: not enough disk space on /backup (needed: 4.2 GB, available: 1.1 GB)",
		],
		["Info", "Database", "Database admin_wp_main created (utf8mb4)"],
		["Warning", "Firewall", "Banned IP address 198.51.100.77 (chain: SSH)"],
		["Info", "Mail", "Mail account info@vylaris-group.eu was changed"],
		[
			"Error",
			"SSL",
			"Let's Encrypt validation for shop.beispiel-gmbh.example failed: Invalid response from http://shop.beispiel-gmbh.example/.well-known/acme-challenge/abcdef",
		],
		["Info", "Cron", "Cron job added (ID: 4)"],
		["Info", "System", "Sehr lange Meldung ohne Leerzeichen: " . str_repeat("abcdefghij", 12)],
	];
	$data = [];
	for ($n = 0; $n < $count; $n++) {
		[$level, $category, $message] = $messages[$n % count($messages)];
		$data[(string) (1000 + $n)] = [
			"LEVEL" => $level,
			"CATEGORY" => $category,
			"MESSAGE" => $message,
			"DATE" => fx_date(intdiv($n, 3)),
			"TIME" => fx_time($n),
		];
	}
	return $data;
}

function fx_auth_log(): array {
	$agents = [
		"Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0",
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
		"curl/8.5.0",
	];
	$data = [];
	for ($n = 0; $n < 14; $n++) {
		$failed = $n % 4 === 3;
		$data[(string) (500 + $n)] = [
			"ACTION" => $n % 5 === 4 ? "logout" : "login",
			"ACTIVE" => $n === 0 ? "yes" : "no",
			"STATUS" => $failed ? "failed" : "success",
			"IP" => "198.51.100." . (20 + $n),
			"USER_AGENT" => $agents[$n % 3],
			"DATE" => fx_date(intdiv($n, 2)),
			"TIME" => fx_time($n),
		];
	}
	return $data;
}

function fx_updates(string $variant = ""): array {
	$data = [];
	$rows = [
		["hestia", "VylarisSpace core package", "1.10.5", "yes"],
		["hestia-nginx", "VylarisSpace internal web server", "1.27.2", "no"],
		["hestia-php", "VylarisSpace internal php interpreter", "8.3.14", "yes"],
		["hestia-web-terminal", "VylarisSpace web terminal", "1.0.2", "no"],
	];
	foreach ($rows as [$pkg, $descr, $version, $updated]) {
		$data[$pkg] = [
			"DESCR" => $descr,
			"VERSION" => $version,
			"ARCH" => "amd64",
			"UPDATED" => $updated,
			"CANDIDATE" => "",
			"AUTOUPDATE" => "",
		];
	}
	// Own package source (VYLARIS_UPDATES=yes): only the panel package is tracked
	if (str_starts_with($variant, "own")) {
		$data["hestia"]["VERSION"] = "1.10.5-100+ubuntu24.04";
		$data["hestia"]["UPDATED"] = $variant === "own-available" ? "no" : "yes";
		$data["hestia"]["CANDIDATE"] = $variant === "own-available" ? "1.10.6-100+ubuntu24.04" : "";
		$data["hestia"]["AUTOUPDATE"] = $variant === "own-available" ? "no" : "yes";
	}
	return $data;
}

function fx_search_results(): array {
	$rows = [
		["WEB", "DOMAIN", "vylaris-group.eu", "", "", "admin", "no"],
		["WEB", "DOMAIN", "vylaris-group-shop.example", "", "", "bernd", "yes"],
		["DNS", "DOMAIN", "vylaris-group.eu", "", "", "admin", "no"],
		["DNS", "RECORD", "vylaris-group.eu", "vylaris-group.eu", "107", "admin", "no"],
		["MAIL", "DOMAIN", "mail.vylaris-group.eu", "", "", "admin", "no"],
		["MAIL", "ACCOUNT", "info@vylaris-group.eu", "vylaris-group.eu", "info", "admin", "no"],
		["DB", "DATABASE", "admin_vylaris_wp", "", "", "admin", "no"],
		[
			"CRON",
			"JOB",
			"/usr/bin/php /home/admin/web/vylaris-group.eu/cron.php",
			"",
			"1",
			"admin",
			"yes",
		],
	];
	$data = [];
	foreach ($rows as $n => [$type, $key, $result, $parent, $link, $owner, $suspended]) {
		$data[(string) $n] = [
			"TYPE" => $type === "WEB" ? "web" : strtolower($type),
			"KEY" => $key,
			"RESULT" => $result,
			"PARENT" => $parent,
			"LINK" => $link,
			"USER" => $owner,
			"SUSPENDED" => $suspended,
			"DATE" => fx_date($n * 20),
			"TIME" => fx_time($n),
		];
	}
	return $data;
}

function fx_rrd_services(): array {
	return [
		["TITLE" => "Load Average", "TYPE" => "la", "RRD" => "la"],
		["TITLE" => "Memory Usage", "TYPE" => "mem", "RRD" => "mem"],
		["TITLE" => "Network (eth0)", "TYPE" => "net", "RRD" => "eth0"],
		["TITLE" => "Apache2 Connections", "TYPE" => "web", "RRD" => "apache2"],
		["TITLE" => "Nginx Connections", "TYPE" => "web", "RRD" => "nginx"],
		["TITLE" => "SMTP Queue", "TYPE" => "mail", "RRD" => "mail"],
		["TITLE" => "MariaDB Queries", "TYPE" => "db", "RRD" => "mysql_localhost"],
		["TITLE" => "SSH Connections", "TYPE" => "ssh", "RRD" => "ssh"],
	];
}

/** Object that mimics Hestia\WebApp\InstallationTarget for the "Quick Install App" cards. */
function fx_webapp(string $name, string $version, bool $installable = true) {
	return new class ($name, $version, $installable) {
		public $thumbnail = "thumbnail.png";
		public function __construct(public $name, public $version, private $installable) {}
		public function isInstallable() {
			return $this->installable;
		}
	};
}

return [
	"list_backup" => function (string $variant): array {
		return ["data" => $variant === "empty" ? [] : fx_backups()];
	},
	"list_backup_detail" => function (): array {
		$data = fx_backups();
		$name = array_key_first($data);
		$_GET["backup"] = $name;
		return ["data" => [$name => $data[$name]]];
	},
	"list_backup_incremental" => function (): array {
		$data = [];
		for ($n = 0; $n < 6; $n++) {
			$data[] = [
				"short_id" => substr(sha1("snapshot$n"), 0, 8),
				"time" => fx_date($n * 2) . " 03:00:0" . $n,
				"hostname" => "srv01.vylaris.example",
				"tags" => ["admin"],
			];
		}
		return ["data" => $data];
	},
	"list_backup_exclusions" => function (): array {
		return [
			"data" => [
				"WEB" => [
					"vylaris-group.eu" => "public_html/cache,public_html/wp-content/cache",
					"example.org" => "*",
				],
				"MAIL" => [],
				"DB" => ["admin_wp_main" => "wp_actionscheduler_logs"],
				"USER_DIR" => ["uploads" => "tmp,*.log"],
			],
		];
	},
	"list_services" => function (): array {
		$data = fx_services();
		return [
			"sys" => fx_sys_info(),
			"data" => $data,
			"phpfpm" => ["php8.3-fpm", "php8.2-fpm"],
			"php" => ["8.3", "8.2"],
		];
	},
	"list_stats" => function (string $variant): array {
		return [
			"data" => fx_stats($variant === "user"),
			"users" => ["admin", "bernd", "löwenzahn", "ostsee", "testkunde"],
			"v_user" => $variant === "peruser" ? "bernd" : "",
		];
	},
	"list_log" => function (string $variant): array {
		$_GET["user"] = $variant === "system" ? "system" : "admin";
		return ["data" => $variant === "empty" ? [] : fx_logs()];
	},
	"list_log_auth" => function (): array {
		return ["data" => fx_auth_log()];
	},
	"list_updates" => function (string $variant): array {
		return ["data" => fx_updates($variant), "autoupdate" => $variant === "auto" ? "yes" : "no"];
	},
	"list_search" => function (string $variant): array {
		$_GET["q"] = "vylaris";
		return ["data" => $variant === "empty" ? [] : fx_search_results()];
	},
	"list_rrd" => function (string $variant): array {
		$period = $variant ?: "daily";
		return ["data" => fx_rrd_services(), "period" => $period];
	},
	"list_webapps" => function (): array {
		return [
			"v_domain" => "vylaris-group.eu",
			"v_web_apps" => [
				fx_webapp("WordPress", "6.7.1"),
				fx_webapp("Joomla", "5.2.1"),
				fx_webapp("Drupal", "10.3.9", false),
				fx_webapp("Nextcloud", "30.0.2"),
				fx_webapp("PrestaShop", "8.1.7"),
				fx_webapp("Laravel", "11.0"),
			],
		];
	},
	"setup_webapp" => function (): array {
		$installer = new class {
			public function applicationName() {
				return "WordPress";
			}
			public function formNamespace() {
				return "webapp_";
			}
			public function isDomainRootClean() {
				return false;
			}
			public function getOptions() {
				return [
					"site_name" => ["value" => "Mein Blog", "label" => "Site Name"],
					"admin_username" => ["value" => "admin"],
					"admin_password" => ["type" => "password"],
					"admin_email" => ["placeholder" => "mail@example.com"],
					"language" => [
						"type" => "select",
						"options" => ["en_US" => "English (US)", "de_DE" => "Deutsch"],
						"value" => "de_DE",
					],
					"install_woocommerce" => "boolean",
					"database_name" => ["placeholder" => "admin_wordpress"],
				];
			}
		};
		return ["v_domain" => "vylaris-group.eu", "WebappInstaller" => $installer];
	},
	"list_ssl" => function (): array {
		return [
			"v_domain" => "vylaris-group.eu",
			"v_crt" =>
				"-----BEGIN CERTIFICATE-----\nMIIDdzCCAl+gAwIBAgIUQ0ZtY2VydGlmaWNhdGVzYW1wbGUwDQYJKoZIhvcNAQEL\nBQAwSzELMAkGA1UEBhMCREUxDzANBgNVBAgMBkJlcmxpbjEPMA0GA1UEBwwGQmVy\n-----END CERTIFICATE-----\n",
			"v_csr" =>
				"-----BEGIN CERTIFICATE REQUEST-----\nMIICijCCAXICAQAwRTELMAkGA1UEBhMCREUxEzARBgNVBAgMClNvbWUtU3RhdGUx\nITAfBgNVBAoMGEludGVybmV0IFdpZGdpdHMgUHR5IEx0ZDCC\n-----END CERTIFICATE REQUEST-----\n",
			"v_key" =>
				"-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7sampleSAMPLE\nsampleSAMPLEsampleSAMPLE\n-----END PRIVATE KEY-----\n",
		];
	},
	"list_access_keys" => function (string $variant): array {
		if ($variant === "empty") {
			return ["data" => []];
		}
		return [
			"data" => [
				"AbCdEfGhIjKlMnOpQrSt" => [
					"USER" => "admin",
					"COMMENT" => "Deployment pipeline (GitLab CI)",
					"PERMISSIONS" => "v-list-web-domains v-add-web-domain v-delete-web-domain",
					"DATE" => fx_date(10),
					"TIME" => fx_time(3),
				],
				"UvWxYzAbCdEfGhIjKlMn" => [
					"USER" => "admin",
					"COMMENT" => "Monitoring-Skript für Müller & Söhne",
					"PERMISSIONS" => "admin",
					"DATE" => fx_date(70),
					"TIME" => fx_time(8),
				],
				"OpQrStUvWxYzAbCdEfGh" => [
					"USER" => "bernd",
					"COMMENT" => "",
					"PERMISSIONS" => "v-list-user v-list-web-domains",
					"DATE" => fx_date(200),
					"TIME" => fx_time(2),
				],
			],
		];
	},
	"list_access_key" => function (string $variant): array {
		if ($variant === "created") {
			$_SESSION["ok_msg"] = "Access key created, save the secret key now.";
		}
		return [
			"key_data" => [
				"ACCESS_KEY_ID" => "'AbCdEfGhIjKlMnOpQrSt'",
				"SECRET_ACCESS_KEY" => "'k3Jf9sLq2mXz0Vb7NwEa5YtRoUi8PcHd'",
				"COMMENT" => "Deployment pipeline (GitLab CI)",
				"PERMISSIONS" => ["Add Web Domain", "List Web Domains", "Delete Web Domain"],
			],
		];
	},
];
