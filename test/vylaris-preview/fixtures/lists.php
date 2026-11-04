<?php
// List pages: web/list/<name>/index.php builds $data (and a few extras) from v-list-* JSON.

function fx_web_domains(int $count = 16, string $owner = "admin"): array {
	$names = fx_domains();
	$ext =
		"jpg,jpeg,gif,png,ico,svg,css,zip,tgz,gz,rar,bz2,doc,xls,exe,pdf,ppt,txt,odt,ods,odp,odf,tar,wav,bmp,rtf,js,mp3,avi,mpeg,flv,html,htm";
	$data = [];
	foreach (array_slice($names, 0, $count) as $n => $name) {
		$suspended = in_array($n, [3, 9, 13], true);
		$ssl = $n % 3 !== 2;
		$data[$name] = [
			"IP" => fx_pick(["203.0.113.10", "203.0.113.11", "10.0.0.15"], $n),
			"IP6" => "",
			"U_DISK" => (string) [
				12,
				480,
				5120,
				0,
				880000,
				20480,
				1500,
				33,
				2200000,
				64,
				310,
				9100,
				770,
				4,
				150,
				42,
			][$n % 16],
			"U_BANDWIDTH" => (string) [
				0,
				1200,
				15000,
				0,
				330000,
				120,
				8,
				0,
				90,
				4400,
				210,
				15,
				0,
				3,
				760,
				22,
			][$n % 16],
			"TPL" => "default",
			"ALIAS" =>
				$n % 4 === 1
					? "www.$name,shop.$name,mail-tools.$name,cdn.$name,images.$name"
					: "www.$name",
			"STATS" => fx_pick(["awstats", "", "webalizer", ""], $n),
			"STATS_USER" => "",
			"STATS_CRYPT" => "",
			"SSL" => $ssl ? "yes" : "no",
			"SSL_HOME" => $ssl ? "same" : "",
			"LETSENCRYPT" => $n % 2 ? "yes" : "no",
			"FTP_USER" =>
				$n % 5 === 0
					? "$owner" . "_ftp:$owner" . "_dev:$owner" . "_deploy:$owner" . "_backup"
					: ($n % 2
						? "$owner" . "_ftp"
						: ""),
			"FTP_PATH" => "/home/$owner/web/$name/public_html",
			"AUTH_USER" => "",
			"AUTH_HASH" => "",
			"BACKEND" => "default",
			"PROXY" => "default",
			"PROXY_EXT" => $n % 3 === 0 ? $ext : "jpg,jpeg,gif,png,ico,svg,css,zip",
			"REDIRECT" => "",
			"REDIRECT_CODE" => "",
			"SUSPENDED" => $suspended ? "yes" : "no",
			"TIME" => fx_time($n),
			"DATE" => fx_date($n * 9),
			"DOCUMENT_ROOT" => "",
		];
	}
	return $data;
}

function fx_users_list(): array {
	$rows = [
		[
			"admin",
			"Jürgen Müller-Lüdenscheidt",
			"juergen.mueller@vylaris.example",
			"default",
			"admin",
			false,
		],
		["bernd", "Bernd Beispiel", "bernd@beispiel-gmbh.example", "starter", "user", false],
		[
			"löwenzahn",
			"Käthe Löwenzahn-Großmann",
			"kaethe.loewenzahn.grossmann@sehr-langer-firmenname-fuer-tests.example",
			"business-plus",
			"user",
			false,
		],
		[
			"shop-team",
			"Online Shop Team (International Sales & Support)",
			"support@shop.beispiel-gmbh.example",
			"business",
			"user",
			false,
		],
		[
			"ostsee",
			"Ferienwohnung Ostsee",
			"info@ferienwohnung-ostsee.example",
			"starter",
			"user",
			true,
		],
		["mustermann", "Max Mustermann", "max@mustermann.example", "default", "user", false],
		[
			"hausverwaltung",
			"Hausverwaltung Grünwald",
			"buero@hausverwaltung-grünwald.example",
			"business",
			"user",
			false,
		],
		[
			"kanzlei",
			"Dr. Weißenfels & Partner",
			"kanzlei@kanzlei-dr-weißenfels.example",
			"business-plus",
			"user",
			false,
		],
		["testkunde", "Test Customer", "test@example.org", "system", "user", true],
		["api-bot", "API Service Account", "bot@vylaris.example", "default", "user", false],
		["support", "Second Level Support", "support@vylaris.example", "default", "admin", false],
		["wartung", "Wartung & Betrieb", "betrieb@vylaris.example", "default", "admin", false],
	];
	$data = [];
	foreach ($rows as $n => [$login, $name, $mail, $package, $role, $suspended]) {
		$data[$login] = fx_user_record($login, [
			"NAME" => $name,
			"FNAME" => explode(" ", $name)[0],
			"CONTACT" => $mail,
			"PACKAGE" => $package,
			"ROLE" => $role,
			"SUSPENDED" => $suspended ? "yes" : "no",
			"DISK_QUOTA" => fx_pick(["unlimited", "10240", "51200", "204800"], $n),
			"BANDWIDTH" => fx_pick(["unlimited", "102400", "512000"], $n),
			"U_DISK" => (string) ($n * 3100 + 220),
			"U_BANDWIDTH" => (string) ($n * 870),
			"U_WEB_DOMAINS" => (string) (($n % 5) + 1),
			"U_DNS_DOMAINS" => (string) ($n % 3),
			"U_MAIL_DOMAINS" => (string) ($n % 4),
			"U_DATABASES" => (string) ($n % 6),
			"U_BACKUPS" => (string) ($n % 4),
			"IP_OWNED" => (string) ($n % 7 === 0 ? 2 : 1),
			"DATE" => fx_date($n * 31),
			"TIME" => fx_time($n),
		]);
	}
	return $data;
}

function fx_dns_domains(): array {
	$data = [];
	foreach (array_slice(fx_domains(), 0, 14) as $n => $name) {
		$data[$name] = [
			"IP" => fx_pick(["203.0.113.10", "203.0.113.11"], $n),
			"TPL" => fx_pick(["default", "child-ns", "default-nodnssec"], $n),
			"TTL" => fx_pick(["14400", "3600", "300"], $n),
			"EXP" => fx_date(-($n * 40 + 20)),
			"SOA" => "ns1." . ($n % 2 ? "vylaris-group.eu" : "vylaris.example"),
			"SERIAL" => "2025" . sprintf("%04d", $n),
			"SRC" => $n === 5 ? "dns-master.vylaris.example" : "",
			"RECORDS" => (string) ($n === 12 ? 0 : 6 + $n),
			"DNSSEC" => $n % 3 === 0 ? "yes" : "no",
			"SUSPENDED" => $n === 4 || $n === 10 ? "yes" : "no",
			"TIME" => fx_time($n),
			"DATE" => fx_date($n * 12),
		];
	}
	return $data;
}

function fx_dns_records(): array {
	$rows = [
		["@", "A", "", "203.0.113.10"],
		["www", "CNAME", "", "vylaris-group.eu."],
		["@", "MX", "10", "mail.vylaris-group.eu."],
		["@", "MX", "20", "mail2.vylaris-group.eu."],
		["mail", "A", "", "203.0.113.10"],
		["@", "TXT", "", "v=spf1 a mx ip4:203.0.113.10 -all"],
		["_dmarc", "TXT", "", "v=DMARC1; p=quarantine; rua=mailto:dmarc@vylaris-group.eu"],
		[
			"mail._domainkey",
			"TXT",
			"",
			"v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwJkDz8mQ3hZ5q0w7wZ1yV8wXq9r5uJ0lq2dGQ3J1Yb5mB8h9u2L7c4kXo6V1oQeW6u3p8wA2nHl5Fyz0v9sT4cRzZyDq1Tt9sL7aK3bM6nV2pQ5rJ8xE4gC0hU7yWvF1iB9oN3dZkS6tPlAqX8jHmGfIeUwRsY5nVcLbOzDxKhT2uEyMwJq7PnAo4rSgBvCzF1lIhdkXQIDAQAB",
		],
		["ns1", "A", "", "203.0.113.10"],
		["@", "NS", "", "ns1.vylaris-group.eu."],
		["@", "NS", "", "ns2.vylaris-group.eu."],
		["_sip._tcp", "SRV", "10", "5 5060 sip.vylaris-group.eu."],
		["blog", "A", "", "203.0.113.11"],
		[
			"sehr-langer-eintrag-fuer-den-layouttest-mit-vielen-zeichen-im-namen",
			"CNAME",
			"",
			"ziel.beispiel-unternehmen-deutschland.example.com.",
		],
		["@", "CAA", "", "0 issue \"letsencrypt.org\""],
		["ipv6", "AAAA", "", "2001:db8::10"],
	];
	$data = [];
	foreach ($rows as $n => [$record, $type, $prio, $value]) {
		$id = (string) (100 + $n * 7);
		$data[$id] = [
			"ID" => $id,
			"RECORD" => $record,
			"TYPE" => $type,
			"PRIORITY" => $prio,
			"VALUE" => $value,
			"SUSPENDED" => $n === 4 ? "yes" : "no",
			"TTL" => $n % 4 === 1 ? "300" : "",
			"TIME" => fx_time($n),
			"DATE" => fx_date($n * 3),
		];
	}
	return $data;
}

function fx_mail_domains(): array {
	$data = [];
	foreach (array_slice(fx_domains(), 0, 12) as $n => $name) {
		$data[$name] = [
			"ANTIVIRUS" => $n % 4 === 3 ? "no" : "yes",
			"ANTISPAM" => $n % 5 === 2 ? "no" : "yes",
			"DKIM" => $n % 3 === 1 ? "no" : "yes",
			"CATCHALL" => $n % 6 === 0 ? "postmaster@$name" : "",
			"ACCOUNTS" => (string) ($n === 7 ? 0 : $n + 2),
			"U_DISK" => (string) [0, 340, 15000, 2, 880, 22000, 12, 0, 640000, 7, 99, 410][$n],
			"SSL" => $n % 3 === 2 ? "no" : "yes",
			"LETSENCRYPT" => "no",
			"SUSPENDED" => $n === 6 ? "yes" : "no",
			"TIME" => fx_time($n),
			"DATE" => fx_date($n * 14),
			"RATE_LIMIT" => "200",
			"REJECT" => "yes",
		];
	}
	return $data;
}

function fx_mail_accounts(): array {
	$names = [
		"info",
		"kontakt",
		"support",
		"vertrieb",
		"buchhaltung",
		"geschäftsführung",
		"j.müller",
		"noreply",
		"webmaster",
		"postmaster",
		"newsletter",
		"very.long.account.name.for.layout.testing",
	];
	$data = [];
	foreach ($names as $n => $name) {
		$data[$name] = [
			"ALIAS" => $n % 3 === 0 ? "sales,verkauf,office" : "",
			"FWD" => $n % 4 === 1 ? "externe.adresse@beispiel-provider.example" : "",
			"FWD_ONLY" => "no",
			"AUTOREPLY" => $n === 5 ? "yes" : "no",
			"QUOTA" => $n % 3 === 2 ? "unlimited" : (string) ($n % 2 ? 2048 : 512),
			"U_DISK" => (string) [0, 120, 3400, 22, 560, 8800, 12, 0, 150, 1, 4600, 2][$n],
			"SUSPENDED" => $n === 7 ? "yes" : "no",
			"TIME" => fx_time($n),
			"DATE" => fx_date($n * 8),
			"RATE_LIMIT" => "200",
		];
	}
	return $data;
}

function fx_databases(): array {
	$data = [];
	$names = [
		"wp_main",
		"wp_blog",
		"shop",
		"typo3_live",
		"nextcloud",
		"staging_db",
		"analytics",
		"forum",
		"crm",
		"kunden_löschen",
		"very_long_database_name_for_testing",
		"test",
	];
	foreach ($names as $n => $name) {
		$data["admin_$name"] = [
			"DBUSER" => "admin_" . ($n % 3 === 0 ? "dbuser_$name" : $name),
			"HOST" => "localhost",
			"TYPE" => $n % 4 === 3 ? "pgsql" : "mysql",
			"CHARSET" => $n % 4 === 3 ? "UTF8" : fx_pick(["utf8mb4", "utf8", "latin1"], $n),
			"U_DISK" => (string) [14, 880, 1200, 52000, 330, 5, 9100, 41, 770, 0, 12, 3][$n],
			"SUSPENDED" => $n === 5 ? "yes" : "no",
			"TIME" => fx_time($n),
			"DATE" => fx_date($n * 20),
		];
	}
	return $data;
}

function fx_cron_jobs(): array {
	$jobs = [
		[
			"*/5",
			"*",
			"*",
			"*",
			"*",
			"/usr/bin/php /home/admin/web/vylaris-group.eu/public_html/cron.php",
		],
		["0", "3", "*", "*", "*", "sudo /usr/local/hestia/bin/v-backup-users"],
		[
			"15",
			"2",
			"*",
			"*",
			"1",
			"/usr/bin/rsync -a /home/admin/uploads/ /mnt/backup/uploads/ --delete --exclude=cache --exclude=tmp --exclude=*.log",
		],
		[
			"30",
			"4",
			"1",
			"*",
			"*",
			"wget -q -O /dev/null https://shop.beispiel-gmbh.example/cron/monthly-report?token=0123456789",
		],
		["*", "*", "*", "*", "*", "echo 'jede Minute' > /dev/null"],
		["0", "*/2", "*", "*", "*", "/home/admin/bin/clear-cache.sh"],
		[
			"45",
			"23",
			"*",
			"12",
			"5",
			"/usr/bin/php /home/bernd/web/beispiel-gmbh.example/public_html/jahresabschluss.php --verbose",
		],
		["0", "0", "1", "1", "*", "curl -fsS https://example.org/new-year"],
	];
	$data = [];
	foreach ($jobs as $n => [$min, $hour, $day, $month, $wday, $cmd]) {
		$id = (string) ($n + 1);
		$data[$id] = [
			"JOB" => $id,
			"MIN" => $min,
			"HOUR" => $hour,
			"DAY" => $day,
			"MONTH" => $month,
			"WDAY" => $wday,
			"CMD" => $cmd,
			"SUSPENDED" => $n === 4 ? "yes" : "no",
			"TIME" => fx_time($n),
			"DATE" => fx_date($n * 17),
		];
	}
	return $data;
}

function fx_packages(): array {
	$rows = [
		[
			"default",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"10240",
			"unlimited",
			"nologin",
		],
		["starter", "5", "5", "5", "100", "3", "20", "5", "10", "10240", "102400", "nologin"],
		[
			"business",
			"50",
			"50",
			"50",
			"1000",
			"20",
			"200",
			"50",
			"100",
			"102400",
			"unlimited",
			"bash",
		],
		[
			"business-plus",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"512000",
			"unlimited",
			"bash",
		],
		[
			"system",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"unlimited",
			"bash",
		],
		[
			"reseller-gold-extra-lang",
			"500",
			"500",
			"500",
			"5000",
			"200",
			"2000",
			"500",
			"1000",
			"2097152",
			"unlimited",
			"rbash",
		],
	];
	$data = [];
	foreach ($rows as $n => $r) {
		$data[$r[0]] = [
			"WEB_TEMPLATE" => "default",
			"BACKEND_TEMPLATE" => "default",
			"PROXY_TEMPLATE" => "default",
			"DNS_TEMPLATE" => "default",
			"WEB_DOMAINS" => $r[1],
			"WEB_ALIASES" => $r[2],
			"DNS_DOMAINS" => $r[3],
			"DNS_RECORDS" => $r[4],
			"MAIL_DOMAINS" => $r[5],
			"MAIL_ACCOUNTS" => $r[6],
			"DATABASES" => $r[7],
			"CRON_JOBS" => $r[8],
			"DISK_QUOTA" => $r[9],
			"BANDWIDTH" => $r[10],
			"NS" => "ns1.vylaris.example,ns2.vylaris.example",
			"SHELL" => $r[11],
			"BACKUPS" => $n === 1 ? "3" : "10",
			"TIME" => fx_time($n),
			"DATE" => fx_date($n * 60),
		];
	}
	return $data;
}

function fx_firewall_rules(): array {
	$rows = [
		["ACCEPT", "TCP", "80,443", "0.0.0.0/0", "WEB"],
		["ACCEPT", "TCP", "22", "198.51.100.0/24", "SSH aus dem Büro"],
		["ACCEPT", "TCP", "8083", "0.0.0.0/0", "Hestia Control Panel"],
		["DROP", "TCP", "23", "0.0.0.0/0", "Telnet blocken"],
		["ACCEPT", "UDP", "53", "0.0.0.0/0", "DNS"],
		["DROP", "ICMP", "", "203.0.113.200", ""],
		["ACCEPT", "TCP", "25,465,587", "0.0.0.0/0", "MAIL"],
		[
			"DROP",
			"TCP",
			"1:1024",
			"ipset:blacklist",
			"Sehr langer Kommentar, der den Umbruch in der Tabelle auf die Probe stellen soll",
		],
		["ACCEPT", "TCP", "110,143,993,995", "0.0.0.0/0", "IMAP/POP3"],
		["ACCEPT", "TCP", "21,12000:12100", "0.0.0.0/0", "FTP"],
	];
	$data = [];
	foreach ($rows as $n => [$action, $protocol, $port, $ip, $comment]) {
		$id = (string) ($n + 1);
		$data[$id] = [
			"RULE" => $id,
			"ACTION" => $action,
			"PROTOCOL" => $protocol,
			"PORT" => $port,
			"IP" => $ip,
			"COMMENT" => $comment,
			"SUSPENDED" => $n === 5 ? "yes" : "no",
			"TIME" => fx_time($n),
			"DATE" => fx_date($n * 5),
		];
	}
	return $data;
}

return [
	"list_user" => function (string $variant): array {
		$data = fx_users_list();
		if ($variant === "date") {
			$_SESSION["userSortOrder"] = "date";
		}
		return ["data" => $variant === "empty" ? [] : $data];
	},
	"list_web" => function (string $variant): array {
		$owner = $variant === "user" ? "bernd" : "admin";
		$data = fx_web_domains($variant === "user" ? 5 : 16, $owner);
		if ($variant === "empty") {
			$data = [];
		}
		return ["data" => $data, "ips" => fx_ips()];
	},
	"list_dns" => function (string $variant): array {
		return ["data" => $variant === "empty" ? [] : fx_dns_domains()];
	},
	"list_dns_rec" => function (string $variant): array {
		return ["data" => $variant === "empty" ? [] : fx_dns_records()];
	},
	"list_dns_public" => function (): array {
		return [
			"data" => [
				"vylaris-group.eu" => [
					"RECORD" =>
						"vylaris-group.eu. IN DNSKEY 257 3 13 mdsswUyr3DPW132mOi8V9xESWE8jTo0dxCjjnopKl+GqJxpVXckHAeF+KkxLbxILfDLUT0rAK9iUzy1L53eKGQ==",
					"FLAG" => "257",
					"ALGORITHM" => "13",
					"KEY" =>
						"mdsswUyr3DPW132mOi8V9xESWE8jTo0dxCjjnopKl+GqJxpVXckHAeF+KkxLbxILfDLUT0rAK9iUzy1L53eKGQ==",
					"KEYTAG" => "34211",
					"DS" =>
						"34211 13 2 8E5D0C2E8D7E0C2D9B2F1FFAE39C1E7F9A6C3F3D6A1A0F4E0F2B9E6C1D2A3B4C",
				],
			],
			"domain" => "vylaris-group.eu",
			"flag" => "KSK (257)",
			"algorithm" => "13 - ECDSAP256/SHA256",
		];
	},
	"list_mail" => function (string $variant): array {
		return ["data" => $variant === "empty" ? [] : fx_mail_domains()];
	},
	"list_mail_acc" => function (string $variant): array {
		return ["data" => $variant === "empty" ? [] : fx_mail_accounts()];
	},
	"list_mail_dns" => function (): array {
		return [
			"data" => [
				"A" => ["TXT" => "203.0.113.10"],
			],
			"ips" => fx_ips(),
			"dkim" => [
				"mail._domainkey" => [
					"TXT" =>
						"v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwJkDz8mQ3hZ5q0w7wZ1yV8wXq9r5uJ0lq2dGQ3J1Yb5mB8h9u2L7c4kXo6V1oQeW6u3p8wA2nHl5Fyz0v9sT4cRzZyDq1Tt9sL7aK3bM6nV2pQ5rJ8xE4gC0hU7yWvF1iB9oN3dZkS6tPlAqX8jHmGfIeUwRsY5nVcLbOzDxKhT2uEyMwJq7PnAo4rSgBvCzF1lIhdkXQIDAQAB",
				],
			],
		];
	},
	"list_db" => function (string $variant): array {
		return ["data" => $variant === "empty" ? [] : fx_databases()];
	},
	"list_cron" => function (string $variant): array {
		return ["data" => $variant === "empty" ? [] : fx_cron_jobs()];
	},
	"list_packages" => function (string $variant): array {
		return ["data" => $variant === "empty" ? [] : fx_packages()];
	},
	"list_ip" => function (): array {
		return ["data" => fx_ips()];
	},
	"list_firewall" => function (string $variant): array {
		return ["data" => $variant === "empty" ? [] : fx_firewall_rules()];
	},
	"list_firewall_banlist" => function (): array {
		$data = [];
		$chains = ["SSH", "WEB", "MAIL", "RECIDIVE", "FTP"];
		for ($n = 0; $n < 14; $n++) {
			$ip = "198.51.100." . (20 + $n * 7);
			$data[$ip . "-" . $chains[$n % 5]] = [
				"IP" => $ip,
				"CHAIN" => $chains[$n % 5],
				"TIME" => fx_time($n),
				"DATE" => fx_date($n),
			];
		}
		return ["data" => $data];
	},
	"list_firewall_ipset" => function (): array {
		return [
			"data" => [
				"country-de" => [
					"IP_VERSION" => "v4",
					"AUTOUPDATE" => "yes",
					"TIME" => fx_time(1),
					"DATE" => fx_date(3),
				],
				"blacklist" => [
					"IP_VERSION" => "v4",
					"AUTOUPDATE" => "no",
					"TIME" => fx_time(2),
					"DATE" => fx_date(30),
				],
				"ipverse-ru" => [
					"IP_VERSION" => "v6",
					"AUTOUPDATE" => "yes",
					"TIME" => fx_time(5),
					"DATE" => fx_date(60),
				],
			],
		];
	},
	"list_key" => function (): array {
		return [
			"data" => [
				"a1b2c3d4e5f6" => [
					"ID" => "a1b2c3d4e5f6",
					"KEY" =>
						"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKJfPzq4m1YxJ9Z8fWmQ0vE3xY6nVd2R5oPtLhU7sB1c juergen@arbeitsplatz-laptop-mit-langem-namen",
				],
				"f6e5d4c3b2a1" => [
					"ID" => "f6e5d4c3b2a1",
					"KEY" =>
						"ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDExampleExampleExampleExampleExampleExampleExampleExampleExampleExampleExampleExampleExampleExampleExample deploy@ci",
				],
			],
		];
	},
];
