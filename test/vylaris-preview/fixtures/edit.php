<?php
// Edit pages: the controllers (web/edit/<name>/index.php) turn v-list-* output into $v_* variables.

$GLOBALS["__fx_cert"] = [
	"v_ssl_crt" =>
		"-----BEGIN CERTIFICATE-----\nMIIDdzCCAl+gAwIBAgIUQ0ZtY2VydGlmaWNhdGVzYW1wbGUwDQYJKoZIhvcNAQEL\nBQAwSzELMAkGA1UEBhMCREUxDzANBgNVBAgMBkJlcmxpbjEPMA0GA1UEBwwGQmVy\nbGluMQ8wDQYDVQQKDAZWeWxhcmlzMB4XDTI1MDMxNDA5NDExMloXDTI1MDYxMjA5\n-----END CERTIFICATE-----",
	"v_ssl_key" =>
		"-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7sampleSAMPLE\nsampleSAMPLEsampleSAMPLEsampleSAMPLEsampleSAMPLEsampleSAMPLE\n-----END PRIVATE KEY-----",
	"v_ssl_ca" =>
		"-----BEGIN CERTIFICATE-----\nMIIFFjCCAv6gAwIBAgIRAJErCErPDBinU/bWLiWnX1owDQYJKoZIhvcNAQELBQAw\nTzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh\n-----END CERTIFICATE-----",
	"v_ssl_subject" => "CN = müller-und-söhne.de",
	"v_ssl_aliases" => "müller-und-söhne.de,www.müller-und-söhne.de,shop.müller-und-söhne.de",
	"v_ssl_not_before" => "Mar 14 09:41:12 2025 GMT",
	"v_ssl_not_after" => "Jun 12 09:41:11 2025 GMT",
	"v_ssl_signature" => "sha256WithRSAEncryption",
	"v_ssl_pub_key" => "RSA Public-Key: (2048 bit)",
	"v_ssl_issuer" => "C = US, O = Let's Encrypt, CN = R11",
];

function fx_edit_web(string $variant): array {
	$ssl = $variant !== "nossl";
	$vars = [
		"v_domain" => "müller-und-söhne.de",
		"v_aliases" =>
			"www.müller-und-söhne.de\nshop.müller-und-söhne.de\nsehr-langer-alias-fuer-das-layout.beispiel-unternehmen-deutschland.example.com",
		"v_ip" => "203.0.113.10",
		"v_template" => "default",
		"v_backend_template" => "default",
		"v_proxy_template" => "caching",
		"v_proxy" => "yes",
		"v_proxy_ext" =>
			"jpg,jpeg,gif,png,ico,svg,css,zip,tgz,gz,rar,bz2,doc,xls,exe,pdf,ppt,txt,odt,ods,odp,odf,tar,wav,bmp,rtf,js,mp3,avi,mpeg,flv,html,htm",
		"v_nginx_cache" => "yes",
		"v_nginx_cache_duration" => "1m",
		"v_ssl" => $ssl ? "yes" : "no",
		"v_letsencrypt" => $ssl && $variant !== "custom-ssl" ? "yes" : "no",
		"v_ssl_forcessl" => "yes",
		"v_ssl_hsts" => "no",
		"v_ssl_key_algo" => "ecdsa-256",
		"v_stats" => "awstats",
		"v_stats_user" => "stats",
		"v_stats_password" => "",
		"v_redirect" => "www.müller-und-söhne.de",
		"v_redirect_custom" => "",
		"v_redirect_code" => "301",
		"v_status" => "active",
		"v_custom_doc_root" => "",
		"v_custom_doc_root_prepath" => "/home/admin/web/",
		"v_custom_doc_domain" => "",
		"v_custom_doc_folder" => "",
		"v_ftp_user" => "admin_deploy",
		"v_ftp_password" => "",
		"v_ftp_path" => "/",
		"v_ftp_pre_path" => "/home/admin/web/müller-und-söhne.de/public_html",
		"v_ftp_pre_path_new_user" => "/home/admin/web/müller-und-söhne.de/public_html",
		"v_ftp_email" => "",
		"v_ftp_users" => [
			[
				"v_ftp_user" => "admin_deploy",
				"v_ftp_password" => "",
				"v_ftp_path" => "/",
				"v_ftp_email" => "",
				"v_ftp_pre_path" => "/home/admin/web/müller-und-söhne.de/public_html",
				"is_new" => 0,
			],
			[
				"v_ftp_user" => "admin_agentur",
				"v_ftp_password" => "",
				"v_ftp_path" => "/wp-content",
				"v_ftp_email" => "",
				"v_ftp_pre_path" => "/home/admin/web/müller-und-söhne.de/public_html",
				"is_new" => 0,
			],
		],
		"ips" => fx_ips(),
		"stats" => ["none", "awstats", "webalizer"],
		"templates" => [
			"default",
			"hosting-wordpress",
			"hosting-joomla",
			"caching",
			"no-php",
			"sehr-lange-vorlage-fuer-layout-tests",
		],
		"backend_templates" => ["default", "no-php", "WordPress", "PHP-8_3"],
		"proxy_templates" => ["default", "caching", "hosting-wordpress", "no-cache"],
		"redirect_code_options" => [301, 302, 303, 307, 308],
		"user_domains" => array_slice(array_keys(fx_web_domains(5)), 0, 5),
	];
	return array_merge($vars, $GLOBALS["__fx_cert"]);
}

function fx_languages(): array {
	return [
		"en" => "English",
		"de" => "Deutsch",
		"fr" => "Français",
		"es" => "Español",
		"nl" => "Nederlands",
		"pl" => "Polski",
		"ja" => "日本語",
	];
}

function fx_package_vars(string $name): array {
	return [
		"v_package" => $name,
		"v_package_new" => $name,
		"v_web_template" => "default",
		"v_backend_template" => "default",
		"v_proxy_template" => "default",
		"v_dns_template" => "default",
		"v_web_domains" => "50",
		"v_web_aliases" => "50",
		"v_dns_domains" => "unlimited",
		"v_dns_records" => "unlimited",
		"v_mail_domains" => "50",
		"v_mail_accounts" => "1000",
		"v_databases" => "20",
		"v_cron_jobs" => "unlimited",
		"v_disk_quota" => "102400",
		"v_bandwidth" => "unlimited",
		"v_ratelimit" => "200",
		"v_shell" => "bash",
		"v_backups" => "10",
		"v_backups_incremental" => "no",
		"v_ns1" => "ns1.vylaris.example",
		"v_ns2" => "ns2.vylaris.example",
		"v_ns3" => "",
		"v_ns4" => "",
		"v_ns5" => "",
		"v_ns6" => "",
		"v_ns7" => "",
		"v_ns8" => "",
		"v_cpu_quota" => "unlimited",
		"v_cpu_quota_period" => "100",
		"v_memory_limit" => "unlimited",
		"v_swap_limit" => "unlimited",
		"v_status" => "active",
		"web_templates" => ["default", "hosting-wordpress", "caching"],
		"backend_templates" => ["default", "no-php", "WordPress"],
		"proxy_templates" => ["default", "caching", "no-cache"],
		"dns_templates" => ["default", "child-ns", "default-nodnssec"],
		"shells" => ["nologin", "sh", "bash", "rbash", "dash"],
	];
}

return [
	"edit_web" => function (string $variant): array {
		return fx_edit_web($variant);
	},
	"edit_user" => function (string $variant): array {
		$self = $variant === "self-user";
		return [
			"v_username" => $self ? "bernd" : "löwenzahn",
			"v_name" => $self ? "Bernd Beispiel" : "Käthe Löwenzahn-Großmann",
			"v_email" => $self
				? "bernd@beispiel-gmbh.example"
				: "kaethe.loewenzahn.grossmann@sehr-langer-firmenname-fuer-tests.example",
			"v_package" => "business-plus",
			"v_role" => "user",
			"v_language" => "de",
			"v_user_theme" => "",
			"v_sort_order" => "name",
			"v_shell" => "bash",
			"v_phpcli" => "8.3",
			"v_ns1" => "ns1.vylaris.example",
			"v_ns2" => "ns2.vylaris.example",
			"v_ns3" => "",
			"v_ns4" => "",
			"v_ns5" => "",
			"v_ns6" => "",
			"v_ns7" => "",
			"v_ns8" => "",
			"v_status" => "active",
			"v_login_disabled" => "no",
			"v_login_use_iplist" => "no",
			"v_login_allowed_ips" => "",
			"v_twofa" => $variant === "twofa" ? "JBSWY3DPEHPK3PXP" : "",
			"v_qrcode" => "",
			"v_password" => "",
			"languages" => fx_languages(),
			"themes" => ["vylaris", "vylaris-dark", "dark", "flat", "default"],
			"packages" => array_map(fn($p) => ["x" => 1], fx_packages()),
			"shells" => ["nologin", "sh", "bash", "rbash", "dash"],
			"php_versions" => ["php-8.3", "php-8.2", "php-8.1", "php-7.4"],
		];
	},
	"edit_package" => function (): array {
		return fx_package_vars("business-plus");
	},
	"add_package" => function (): array {
		return array_merge(fx_package_vars(""), ["v_package" => ""]);
	},
	"edit_dns" => function (): array {
		return [
			"v_domain" => "vylaris-group.eu",
			"v_ip" => "203.0.113.10",
			"v_template" => "default",
			"v_ttl" => "14400",
			"v_exp" => fx_date(-300),
			"v_soa" => "ns1.vylaris-group.eu",
			"v_dnssec" => "yes",
			"v_status" => "active",
			"v_ips" => fx_ips(),
			"templates" => ["default", "child-ns", "default-nodnssec"],
		];
	},
	"edit_dns_rec" => function (): array {
		return [
			"v_domain" => "vylaris-group.eu",
			"v_record_id" => "107",
			"v_rec" => "mail",
			"v_type" => "A",
			"v_val" => "203.0.113.10",
			"v_priority" => "",
			"v_ttl" => "300",
			"v_status" => "active",
			"v_ips" => fx_ips(),
		];
	},
	"edit_mail" => function (): array {
		return [
			"v_domain" => "vylaris-group.eu",
			"v_antispam" => "yes",
			"v_antivirus" => "yes",
			"v_dkim" => "yes",
			"v_dkim_selector" => "mail",
			"v_catchall" => "postmaster@vylaris-group.eu",
			"v_reject" => "yes",
			"v_rate" => "200",
			"v_status" => "active",
			"v_webmail" => "roundcube",
			"v_webmail_alias" => "webmail",
			"v_smtp_relay" => "true",
			"v_smtp_relay_host" => "smtp.relay-provider.example",
			"v_smtp_relay_port" => "587",
			"v_smtp_relay_user" => "relay-user@vylaris-group.eu",
			"v_letsencrypt" => "yes",
			"v_ssl" => "yes",
			"v_ssl_crt" => $GLOBALS["__fx_cert"]["v_ssl_crt"],
			"v_ssl_key" => $GLOBALS["__fx_cert"]["v_ssl_key"],
			"v_ssl_ca" => $GLOBALS["__fx_cert"]["v_ssl_ca"],
			"v_ssl_subject" => "CN = mail.vylaris-group.eu",
			"v_ssl_aliases" => "mail.vylaris-group.eu",
			"v_ssl_not_before" => "Mar 14 09:41:12 2025 GMT",
			"v_ssl_not_after" => "Jun 12 09:41:11 2025 GMT",
			"v_ssl_signature" => "sha256WithRSAEncryption",
			"v_ssl_pub_key" => "RSA Public-Key: (2048 bit)",
			"v_ssl_issuer" => "C = US, O = Let's Encrypt, CN = R11",
			"v_ssl_key_algo" => "ecdsa-256",
			"webmail_clients" => ["roundcube", "snappymail"],
		];
	},
	"edit_mail_acc" => function (): array {
		return [
			"v_domain" => "vylaris-group.eu",
			"v_account" => "geschäftsführung",
			"v_webmail_alias" => "webmail",
			"v_password" => "",
			"v_quota" => "2048",
			"v_aliases" => "sales\nverkauf\noffice",
			"v_fwd" => "externe.adresse@beispiel-provider.example",
			"v_fwd_only" => "no",
			"v_blackhole" => "no",
			"v_autoreply" => "yes",
			"v_autoreply_message" =>
				"Guten Tag,\n\nich bin bis zum 12. Januar nicht im Büro und melde mich danach.\n\nMit freundlichen Grüßen",
			"v_send_email" => "geschäftsführung@vylaris-group.eu",
			"v_rate" => "200",
			"v_status" => "active",
		];
	},
	"edit_db" => function (): array {
		return [
			"v_database" => "admin_wp_main",
			"v_dbuser" => "admin_dbuser_wp_main",
			"v_password" => "",
			"v_type" => "mysql",
			"v_host" => "localhost",
			"v_charset" => "utf8mb4",
			"v_status" => "active",
		];
	},
	"edit_cron" => function (): array {
		return [
			"v_min" => "*/5",
			"v_hour" => "*",
			"v_day" => "*",
			"v_month" => "*",
			"v_wday" => "*",
			"v_cmd" => "/usr/bin/php /home/admin/web/vylaris-group.eu/public_html/cron.php",
			"v_status" => "active",
			"current_timestamp" => 1767268800,
		];
	},
	"edit_ip" => function (): array {
		return [
			"v_ip" => "203.0.113.11",
			"v_interface" => "eth0",
			"v_netmask" => "255.255.255.0",
			"v_name" => "shop-ip",
			"v_nat" => "",
			"v_dedicated" => "yes",
			"v_owner" => "bernd",
			"users" => ["admin", "bernd", "löwenzahn", "ostsee"],
		];
	},
	"edit_firewall" => function (): array {
		return [
			"v_action" => "DROP",
			"v_protocol" => "TCP",
			"v_port" => "1:1024",
			"v_ip" => "ipset:blacklist",
			"v_comment" => "Sehr lange Kommentare werden hier getestet",
			"v_status" => "active",
			"ipset_lists_json" => json_encode([
				["name" => "country-de", "label" => "country-de"],
				["name" => "blacklist", "label" => "blacklist"],
			]),
		];
	},
	"edit_backup_exclusions" => function (): array {
		return [
			"v_web" =>
				"vylaris-group.eu:public_html/cache\nvylaris-group.eu:public_html/wp-content/cache",
			"v_mail" => "",
			"v_db" => "admin_wp_main:wp_actionscheduler_logs",
			"v_userdir" => "uploads:tmp,*.log",
		];
	},
	"edit_whitelabel" => function (): array {
		return [
			"v_app_name" => "VylarisSpace",
			"v_title" => "{{page}} - {{hostname}} - {{appname}}",
			"v_hide_docs" => "no",
			"v_from_name" => "VylarisSpace",
			"v_from_email" => "noreply@vylaris-group.eu",
			"v_subject_email" => "{{subject}}",
		];
	},
];
