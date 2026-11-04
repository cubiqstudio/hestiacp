<?php
// edit/server: one long configuration page plus the per service config editors.

function fx_php_versions(): array {
	$rows = [
		["PHP 8.4", "php-8.4", "8.4", false, false, []],
		[
			"PHP 8.3",
			"php-8.3",
			"8.3",
			true,
			true,
			[
				"admin" => ["vylaris-group.eu", "müller-und-söhne.de"],
				"bernd" => ["beispiel-gmbh.example"],
			],
		],
		["PHP 8.2", "PHP-8_2", "8.2", true, false, ["admin" => ["example.org"]]],
		["PHP 8.1", "PHP-8_1", "8.1", false, false, []],
		["PHP 7.4", "PHP-7_4", "7.4", true, false, []],
	];
	$out = [];
	foreach ($rows as [$name, $tpl, $version, $installed, $protected, $usedby]) {
		$out[] = (object) [
			"name" => $name === "PHP 8.3" ? "php-8.3" : "php-" . $version,
			"tpl" => $tpl,
			"version" => $version,
			"installed" => $installed,
			"protected" => $protected,
			"usedby" => $usedby,
		];
	}
	return $out;
}

function fx_server_config(string $service): string {
	return match ($service) {
		"nginx"
			=> "user                    nginx;\nworker_processes        auto;\nworker_rlimit_nofile    65535;\npid                     /run/nginx.pid;\n\nevents {\n    worker_connections  1024;\n    multi_accept        on;\n}\n\nhttp {\n    include             /etc/nginx/mime.types;\n    default_type        application/octet-stream;\n    charset             utf-8;\n    sendfile            on;\n    tcp_nopush          on;\n    tcp_nodelay         on;\n    server_tokens       off;\n    client_max_body_size 256m;\n    gzip                on;\n    gzip_comp_level     6;\n    include /etc/nginx/conf.d/*.conf;\n}\n",
		default => "# Konfiguration / configuration for " .
			$service .
			"\n# Letzte Änderung: " .
			fx_date(3) .
			"\n\n[main]\nsetting_one = 1\nsetting_two = \"Wert mit Umlauten: äöüß\"\n",
	};
}

return [
	"edit_server" => function (string $variant): array {
		$_SESSION["DEBUG_MODE"] = "false";
		return [
			"v_hostname" => "srv01.vylaris.example",
			"v_timezone" => "Europe/Berlin",
			"v_timezones" => [
				"Europe/Berlin" => "Europe/Berlin (CET)",
				"Europe/London" => "Europe/London (GMT)",
				"UTC" => "UTC",
				"America/New_York" => "America/New_York (EST)",
			],
			"theme" => ["vylaris", "vylaris-dark", "dark", "flat", "default"],
			"languages" => fx_languages(),
			"v_smtp_relay" => "true",
			"v_smtp_relay_host" => "smtp.relay-provider.example",
			"v_smtp_relay_port" => "587",
			"v_smtp_relay_user" => "relay-user@vylaris-group.eu",
			"v_php_versions" => fx_php_versions(),
			"v_dns_cluster" => "yes",
			"dns_cluster" => [
				"ns3.vylaris.example" => [
					"HOST" => "ns3.vylaris.example",
					"USER" => "dns-sync",
					"PORT" => "8083",
				],
				"ns4.vylaris.example" => [
					"HOST" => "ns4.vylaris.example",
					"USER" => "dns-sync",
					"PORT" => "8083",
				],
			],
			"v_mysql" => "yes",
			"v_mysql_hosts" => [
				"localhost" => [
					"HOST" => "localhost",
					"USER" => "root",
					"MAX_DB" => "500",
					"U_DB_BASES" => "11",
				],
				"db2.vylaris.example" => [
					"HOST" => "db2.vylaris.example",
					"USER" => "hestia",
					"MAX_DB" => "100",
					"U_DB_BASES" => "0",
				],
			],
			"v_pgsql" => "yes",
			"v_pgsql_hosts" => [
				"localhost" => [
					"HOST" => "localhost",
					"USER" => "postgres",
					"MAX_DB" => "500",
					"U_DB_BASES" => "2",
				],
			],
			"v_backup" => "yes",
			"v_backup_gzip" => "5",
			"v_backup_dir" => "/backup",
			"v_backup_mode" => "zstd",
			"v_backup_type" => "sftp",
			"v_backup_incremental" => "no",
			"v_backup_remote_adv" => "",
			"v_backup_host" => "backup.vylaris.example",
			"v_backup_port" => "22",
			"v_backup_username" => "backup",
			"v_backup_password" => "",
			"v_backup_bpath" => "/srv/backup/hestia",
			"v_backup_bucket" => "",
			"v_backup_application_id" => "",
			"v_backup_application_key" => "",
			"v_rclone_host" => "",
			"v_rclone_path" => "",
			"v_repo" => "",
			"v_snapshots" => "",
			"v_keep_daily" => "7",
			"v_keep_weekly" => "4",
			"v_keep_monthly" => "6",
			"v_keep_yearly" => "1",
			"v_ssl_crt" => $GLOBALS["__fx_cert"]["v_ssl_crt"],
			"v_ssl_key" => $GLOBALS["__fx_cert"]["v_ssl_key"],
			"v_ssl_subject" => "CN = srv01.vylaris.example",
			"v_ssl_aliases" => "srv01.vylaris.example",
			"v_ssl_not_before" => "Mar 14 09:41:12 2025 GMT",
			"v_ssl_not_after" => "Jun 12 09:41:11 2025 GMT",
			"v_ssl_signature" => "sha256WithRSAEncryption",
			"v_ssl_pub_key" => "RSA Public-Key: (2048 bit)",
			"v_ssl_issuer" => "C = US, O = Let's Encrypt, CN = R11",
		];
	},
	"edit_server_service" => function (string $variant): array {
		$name = $variant ?: "nginx";
		return [
			"v_service_name" => $name,
			"v_config_path" => "/etc/" . $name . "/" . $name . ".conf",
			"v_config" => fx_server_config($name),
		];
	},
	"edit_server_httpd" => function (): array {
		return [
			"v_service_name" => "apache2",
			"v_config_path" => "/etc/apache2/apache2.conf",
			"v_config" => fx_server_config("apache2"),
		];
	},
	"edit_server_bind9" => function (): array {
		return [
			"v_service_name" => "bind9",
			"v_config_path" => "/etc/bind/named.conf",
			"v_config" => fx_server_config("bind9"),
			"v_options_path" => "/etc/bind/named.conf.options",
			"v_options" => fx_server_config("bind9-options"),
		];
	},
	"edit_server_pgsql" => function (): array {
		return [
			"v_service_name" => "postgresql",
			"v_config_path" => "/etc/postgresql/16/main/postgresql.conf",
			"v_config" => fx_server_config("postgresql"),
			"v_options_path" => "/etc/postgresql/16/main/pg_hba.conf",
			"v_options" => fx_server_config("pg_hba"),
		];
	},
	"edit_server_dovecot" => function (): array {
		$vars = ["v_service_name" => "dovecot"];
		$files = [
			"dovecot.conf",
			"conf.d/10-mail.conf",
			"conf.d/10-auth.conf",
			"conf.d/10-ssl.conf",
			"conf.d/15-lda.conf",
			"conf.d/20-imap.conf",
			"conf.d/20-pop3.conf",
			"conf.d/10-master.conf",
			"conf.d/90-quota.conf",
		];
		$vars["v_config_path"] = "/etc/dovecot/" . $files[0];
		$vars["v_config"] = fx_server_config("dovecot");
		foreach (array_slice($files, 1) as $n => $file) {
			$vars["v_config_path" . ($n + 1)] = "/etc/dovecot/" . $file;
			$vars["v_config" . ($n + 1)] = fx_server_config($file);
		}
		return $vars;
	},
	"edit_server_mysql" => function (): array {
		return [
			"v_service_name" => "mariadb",
			"v_config_path" => "/etc/mysql/mariadb.conf.d/50-server.cnf",
			"v_config" => fx_server_config("mysql"),
			"v_max_connections" => "100",
			"v_max_user_connections" => "20",
			"v_wait_timeout" => "28800",
			"v_interactive_timeout" => "28800",
			"v_max_allowed_packet" => "64M",
			"v_adv" => "",
		];
	},
	"edit_server_nginx" => function (): array {
		return [
			"v_service_name" => "nginx",
			"v_config_path" => "/etc/nginx/nginx.conf",
			"v_config" => fx_server_config("nginx"),
			"v_worker_processes" => "auto",
			"v_worker_connections" => "1024",
			"v_send_timeout" => "60s",
			"v_proxy_connect_timeout" => "60s",
			"v_proxy_send_timeout" => "60s",
			"v_proxy_read_timeout" => "60s",
			"v_client_max_body_size" => "256m",
			"v_gzip" => "on",
			"v_gzip_comp_level" => "6",
			"v_charset" => "utf-8",
			"v_adv" => "",
		];
	},
	"edit_server_php" => function (): array {
		return [
			"v_config_path" => "/etc/php/8.3/fpm/php.ini",
			"v_config" => fx_server_config("php"),
			"v_memory_limit" => "256M",
			"v_max_execution_time" => "30",
			"v_max_input_time" => "60",
			"v_upload_max_filesize" => "100M",
			"v_post_max_size" => "100M",
			"v_display_errors" => "Off",
			"v_error_reporting" => "E_ALL & ~E_DEPRECATED & ~E_STRICT",
			"v_adv" => "",
		];
	},
];
