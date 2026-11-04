<?php
/**
 * Helpers for the page fixtures: deterministic sample data in the exact shape that the Hestia
 * v-list-* commands return (and the controllers hand to the templates).
 *
 * Everything is index based (no randomness) so screenshots are reproducible.
 */

/** Load every fixtures/*.php file; each returns [name => callable(variant, entry): array]. */
function fx_load_fixtures(): array {
	$all = [];
	foreach (glob(PREVIEW_ROOT . "/fixtures/*.php") as $file) {
		$all = array_merge($all, require $file);
	}
	return $all;
}

/** Pick the n-th element of a list, wrapping around. */
function fx_pick(array $list, int $n) {
	return $list[$n % count($list)];
}

/** Date helpers: a stable "today" so ages look plausible. */
function fx_date(int $daysAgo = 0): string {
	return date("Y-m-d", 1767268800 - $daysAgo * 86400);
}

function fx_time(int $n = 0): string {
	return sprintf("%02d:%02d:%02d", ($n * 7) % 24, ($n * 13) % 60, ($n * 29) % 60);
}

/**
 * Users the stub backend knows (result of v-list-user). `$overrides` from the manifest may change
 * single fields of the logged in user, e.g. {"admin": {"NOTIFICATIONS": "yes"}}.
 */
function fx_users(array $overrides = []): array {
	$base = fx_user_record("admin", [
		"FNAME" => "Jürgen",
		"LNAME" => "Müller-Lüdenscheidt",
		"NAME" => "Jürgen Müller-Lüdenscheidt",
		"CONTACT" => "juergen.mueller@vylaris.example",
		"ROLE" => "admin",
		"PACKAGE" => "default",
		"WEB_DOMAINS" => "unlimited",
		"WEB_ALIASES" => "unlimited",
		"DNS_DOMAINS" => "unlimited",
		"DNS_RECORDS" => "unlimited",
		"MAIL_DOMAINS" => "unlimited",
		"MAIL_ACCOUNTS" => "unlimited",
		"DATABASES" => "unlimited",
		"CRON_JOBS" => "unlimited",
		"DISK_QUOTA" => "unlimited",
		"BANDWIDTH" => "unlimited",
		"BACKUPS" => "10",
		"U_USERS" => "9",
		"SUSPENDED_USERS" => "2",
		"U_DISK" => "48210",
		"U_BANDWIDTH" => "9120",
		"U_WEB_DOMAINS" => "14",
		"U_WEB_ALIASES" => "27",
		"U_DNS_DOMAINS" => "6",
		"U_DNS_RECORDS" => "58",
		"U_MAIL_DOMAINS" => "5",
		"U_MAIL_ACCOUNTS" => "17",
		"U_DATABASES" => "11",
		"U_CRON_JOBS" => "7",
		"U_BACKUPS" => "4",
		"SUSPENDED_WEB" => "2",
		"SUSPENDED_DNS" => "1",
		"SUSPENDED_MAIL" => "1",
		"SUSPENDED_DB" => "1",
		"SUSPENDED_CRON" => "1",
	]);
	$users = ["admin" => $base];
	$users["bernd"] = fx_user_record("bernd", [
		"NAME" => "Bernd Beispiel",
		"FNAME" => "Bernd",
		"LNAME" => "Beispiel",
		"CONTACT" => "bernd@beispiel-gmbh.example",
		"ROLE" => "user",
		"PACKAGE" => "starter",
		"WEB_DOMAINS" => "5",
		"WEB_ALIASES" => "5",
		"DNS_DOMAINS" => "5",
		"DNS_RECORDS" => "100",
		"MAIL_DOMAINS" => "3",
		"MAIL_ACCOUNTS" => "20",
		"DATABASES" => "5",
		"CRON_JOBS" => "10",
		"DISK_QUOTA" => "10240",
		"BANDWIDTH" => "102400",
		"BACKUPS" => "3",
		"U_DISK" => "2310",
		"U_BANDWIDTH" => "840",
		"U_WEB_DOMAINS" => "3",
		"U_WEB_ALIASES" => "4",
		"U_DNS_DOMAINS" => "2",
		"U_DNS_RECORDS" => "14",
		"U_MAIL_DOMAINS" => "2",
		"U_MAIL_ACCOUNTS" => "6",
		"U_DATABASES" => "2",
		"U_CRON_JOBS" => "2",
		"U_BACKUPS" => "2",
	]);
	foreach ($overrides as $name => $fields) {
		$users[$name] = array_merge($users[$name] ?? $users["admin"], $fields);
	}
	return $users;
}

function fx_user_record(string $name, array $fields): array {
	return array_merge(
		[
			"FNAME" => $name,
			"LNAME" => "",
			"PACKAGE" => "default",
			"WEB_TEMPLATE" => "default",
			"BACKEND_TEMPLATE" => "default",
			"PROXY_TEMPLATE" => "default",
			"DNS_TEMPLATE" => "default",
			"WEB_DOMAINS" => "unlimited",
			"WEB_ALIASES" => "unlimited",
			"DNS_DOMAINS" => "unlimited",
			"DNS_RECORDS" => "unlimited",
			"MAIL_DOMAINS" => "unlimited",
			"MAIL_ACCOUNTS" => "unlimited",
			"RATE_LIMIT" => "200",
			"DATABASES" => "unlimited",
			"CRON_JOBS" => "unlimited",
			"DISK_QUOTA" => "unlimited",
			"BANDWIDTH" => "unlimited",
			"NS" => "ns1.vylaris.example,ns2.vylaris.example",
			"SHELL" => "bash",
			"BACKUPS" => "3",
			"BACKUPS_INCREMENTAL" => "no",
			"ROLE" => "user",
			"SUSPENDED" => "no",
			"SUSPENDED_USERS" => "0",
			"CONTACT" => $name . "@vylaris.example",
			"NAME" => $name,
			"CRON_REPORTS" => "no",
			"IP_AVAIL" => "1",
			"IP_OWNED" => "1",
			"U_USERS" => "0",
			"U_DISK" => "0",
			"U_DISK_DIRS" => "0",
			"U_DISK_WEB" => "0",
			"U_DISK_MAIL" => "0",
			"U_DISK_DB" => "0",
			"U_BANDWIDTH" => "0",
			"U_WEB_DOMAINS" => "0",
			"U_WEB_ALIASES" => "0",
			"U_DNS_DOMAINS" => "0",
			"U_DNS_RECORDS" => "0",
			"U_MAIL_DOMAINS" => "0",
			"U_MAIL_ACCOUNTS" => "0",
			"U_DATABASES" => "0",
			"U_CRON_JOBS" => "0",
			"U_BACKUPS" => "0",
			"SUSPENDED_WEB" => "0",
			"SUSPENDED_DNS" => "0",
			"SUSPENDED_MAIL" => "0",
			"SUSPENDED_DB" => "0",
			"SUSPENDED_CRON" => "0",
			"LANGUAGE" => "en",
			"NOTIFICATIONS" => "no",
			"PREF_UI_SORT" => "name",
			"TWOFA" => "",
			"QRCODE" => "",
			"PHPCLI" => "8.3",
			"THEME" => "",
			"RKEY" => "",
			"LOGIN_DISABLED" => "no",
			"LOGIN_USE_IPLIST" => "no",
			"LOGIN_ALLOW_IPS" => "",
			"MAIL" => "",
			"DATE" => "2025-03-14",
			"TIME" => "09:41:12",
		],
		$fields,
	);
}

/** Domain / host names that exercise layouts: umlauts, very long names, short names. */
function fx_domains(): array {
	return [
		"vylaris-group.eu",
		"müller-und-söhne.de",
		"bäckerei-schröder.example",
		"beispiel-gmbh.example",
		"shop.beispiel-gmbh.example",
		"staging.vylaris-group.eu",
		"example.org",
		"kanzlei-dr-weißenfels-und-partner.example",
		"a.io",
		"sehr-langer-hostname-fuer-layouttests.unterabteilung.beispiel-unternehmen-deutschland.example.com",
		"blog.mustermann.example",
		"www.hausverwaltung-grünwald.example",
		"ferienwohnung-ostsee.example",
		"intranet.vylaris-group.eu",
		"api.vylaris-group.eu",
		"alte-seite.example.net",
	];
}

/** The IPs of the sample server (v-list-sys-ips). */
function fx_ips(): array {
	return [
		"203.0.113.10" => [
			"OWNER" => "admin",
			"STATUS" => "shared",
			"NAME" => "main",
			"U_SYS_USERS" => "admin,bernd",
			"U_WEB_DOMAINS" => "14",
			"INTERFACE" => "eth0",
			"NETMASK" => "255.255.255.0",
			"NAT" => "",
			"HELO" => "",
			"DATE" => "2025-03-14",
			"TIME" => "09:30:04",
		],
		"203.0.113.11" => [
			"OWNER" => "admin",
			"STATUS" => "dedicated",
			"NAME" => "shop-ip",
			"U_SYS_USERS" => "bernd",
			"U_WEB_DOMAINS" => "1",
			"INTERFACE" => "eth0",
			"NETMASK" => "255.255.255.0",
			"NAT" => "",
			"HELO" => "",
			"DATE" => "2025-05-02",
			"TIME" => "12:11:50",
		],
		"10.0.0.15" => [
			"OWNER" => "admin",
			"STATUS" => "shared",
			"NAME" => "natted",
			"U_SYS_USERS" => "admin",
			"U_WEB_DOMAINS" => "2",
			"INTERFACE" => "eth0",
			"NETMASK" => "255.255.255.0",
			"NAT" => "198.51.100.77",
			"HELO" => "",
			"DATE" => "2025-06-21",
			"TIME" => "18:02:33",
		],
	];
}
