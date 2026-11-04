<?php
// Add pages. Controllers (web/add/<name>/index.php) pre-fill $v_* with defaults or the posted values.
// Variants: "" / "form" -> the form; "accept-notice" -> admin has not confirmed yet; "error" -> validation error.

function fx_add_common(string $variant): array {
	// `$accept === "true"` shows the form, an admin without confirmation sees the notice first.
	if ($variant === "error") {
		$_SESSION["error_msg"] =
			"Fehler: Die Domain existiert bereits / Error: domain already exists";
	}
	return ["accept" => $variant === "accept-notice" ? "" : "true"];
}

return [
	"add_web" => function (string $variant): array {
		$_POST["v_ip"] = "203.0.113.10"; // the template reads the preselected IP from $_POST
		return array_merge(fx_add_common($variant), [
			"v_domain" => $variant === "error" ? "müller-und-söhne.de" : "",
			"v_ip" => "203.0.113.10",
			"v_dns" => "on",
			"v_mail" => "on",
			"ips" => fx_ips(),
			"ip_selected" => "203.0.113.10",
		]);
	},
	"add_db" => function (string $variant): array {
		return array_merge(fx_add_common($variant), [
			"v_database" => $variant === "error" ? "wp_main" : "",
			"v_dbuser" => "",
			"v_db_email" => "",
			"v_type" => "mysql",
			"v_host" => "localhost",
			"v_charset" => "utf8mb4",
			"v_adv" => "",
			"db_types" => ["mysql", "pgsql"],
			"db_hosts" => ["localhost", "db2.vylaris.example"],
		]);
	},
	"add_mail" => function (string $variant): array {
		return array_merge(fx_add_common($variant), [
			"v_domain" => "",
			"v_antispam" => "yes",
			"v_antivirus" => "yes",
			"v_dkim" => "yes",
			"v_dkim_selector" => "mail",
			"v_reject" => "yes",
			"v_webmail" => "roundcube",
			"v_smtp_relay" => "",
			"v_smtp_relay_host" => "",
			"v_smtp_relay_port" => "",
			"v_smtp_relay_user" => "",
			"webmail_clients" => ["roundcube", "snappymail"],
		]);
	},
	"add_mail_acc" => function (): array {
		return [
			"v_domain" => "vylaris-group.eu",
			"v_account" => "",
			"v_webmail_alias" => "webmail",
			"v_quota" => "",
			"v_aliases" => "",
			"v_fwd" => "",
			"v_fwd_only" => "",
			"v_blackhole" => "",
			"v_send_email" => "",
			"v_rate" => "",
			"v_adv" => "",
		];
	},
	"add_user" => function (string $variant): array {
		if ($variant === "error") {
			$_SESSION["error_msg"] = "Fehler: Passwort zu schwach / Error: password is too weak";
		}
		$_POST["v_package"] = "starter";
		return [
			"v_username" => $variant === "error" ? "löwenzahn" : "",
			"v_password" => "",
			"v_email" => "",
			"v_name" => "",
			"v_package" => "default",
			"v_role" => "user",
			"v_language" => "de",
			"v_login_disabled" => "",
			"v_notify" => "",
			"languages" => fx_languages(),
			"data" => [
				"default" => [],
				"starter" => [],
				"business" => [],
				"business-plus" => [],
				"system" => [],
			],
		];
	},
	"add_dns" => function (string $variant): array {
		return array_merge(fx_add_common($variant), [
			"v_domain" => "",
			"v_ip" => "203.0.113.10",
			"v_ips" => fx_ips(),
			"v_template" => "default",
			"v_ttl" => "14400",
			"v_exp" => fx_date(-365),
			"v_ns1" => "ns1.vylaris.example",
			"v_ns2" => "ns2.vylaris.example",
			"v_ns3" => "",
			"v_ns4" => "",
			"v_ns5" => "",
			"v_ns6" => "",
			"v_ns7" => "",
			"v_ns8" => "",
			"v_dnssec" => "",
			"v_adv" => "",
			"templates" => ["default", "child-ns", "default-nodnssec"],
		]);
	},
	"add_dns_rec" => function (): array {
		return [
			"v_domain" => "vylaris-group.eu",
			"v_rec" => "",
			"v_type" => "A",
			"v_val" => "",
			"v_priority" => "",
			"v_ttl" => "",
			"v_ips" => fx_ips(),
		];
	},
	"add_ip" => function (): array {
		return [
			"v_ip" => "",
			"v_netmask" => "255.255.255.0",
			"v_interface" => "eth0",
			"v_name" => "",
			"v_nat" => "",
			"v_dedicated" => "",
			"v_owner" => "admin",
			"interfaces" => ["eth0", "eth1", "ens192"],
			"users" => ["admin", "bernd", "löwenzahn", "ostsee"],
		];
	},
	"add_cron" => function (): array {
		return [
			"v_min" => "*",
			"v_hour" => "*",
			"v_day" => "*",
			"v_month" => "*",
			"v_wday" => "*",
			"v_cmd" => "",
			"current_timestamp" => 1767268800,
		];
	},
	"add_firewall" => function (): array {
		return [
			"v_action" => "DROP",
			"v_protocol" => "TCP",
			"v_port" => "",
			"v_ip" => "",
			"v_comment" => "",
			"ipset_lists_json" => json_encode([["name" => "country-de", "label" => "country-de"]]),
		];
	},
	"add_firewall_banlist" => function (): array {
		return ["v_ip" => "", "v_chain" => "SSH"];
	},
	"add_firewall_ipset" => function (): array {
		return ["v_ipname" => "", "v_ipver" => "v4", "v_datasource" => "", "v_autoupdate" => ""];
	},
	"add_key" => function (): array {
		return ["v_key" => ""];
	},
	"add_access_key" => function (): array {
		return [
			"apis" => [
				"v-list-web-domains" => ["ROLE" => "user"],
				"v-add-web-domain" => ["ROLE" => "user"],
				"v-list-users" => ["ROLE" => "admin"],
				"v-delete-user" => ["ROLE" => "admin"],
			],
		];
	},
	"generate_ssl" => function (): array {
		return [
			"v_domain" => "vylaris-group.eu",
			"v_aliases" => "www.vylaris-group.eu",
			"v_email" => "admin@vylaris-group.eu",
			"v_country" => "DE",
			"v_state" => "Nordrhein-Westfalen",
			"v_locality" => "Düsseldorf",
			"v_org" => "VylarisGroup Europe",
			"v_key_algo" => "ecdsa-256",
		];
	},
];
