<?php
// Pages that print their own HTML shell and a raw command output (list/server?cpu, list/web-log).
// The fixture only provides `$body`, render.php appends it and closes the markup like the controllers do.

function fx_server_info_body(string $kind): string {
	switch ($kind) {
		case "cpu":
			$lines = [
				"top - 09:41:12 up 131 days,  3:12,  1 user,  load average: 0.42, 0.38, 0.35",
				"Tasks: 214 total,   1 running, 213 sleeping,   0 stopped,   0 zombie",
				"%Cpu(s):  3.1 us,  1.2 sy,  0.0 ni, 95.4 id,  0.2 wa,  0.0 hi,  0.1 si,  0.0 st",
				"MiB Mem :   7940.5 total,    812.3 free,   3120.9 used,   4007.3 buff/cache",
				"",
				"    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND",
			];
			$procs = [
				["mysqld", 12.3, 8.1],
				["php-fpm8.3", 4.2, 2.4],
				["nginx", 1.1, 0.6],
				["clamd", 0.7, 14.9],
				["apache2", 0.4, 1.1],
				["named", 0.3, 0.5],
				["exim4", 0.2, 0.3],
				["dovecot", 0.1, 0.2],
			];
			foreach ($procs as $n => [$cmd, $cpu, $mem]) {
				$lines[] = sprintf(
					"%7d %-9s 20   0 %7d %6d %6d S %5.1f %5.1f %9s %s",
					1200 + $n * 37,
					$n % 3 === 0 ? "mysql" : "root",
					812344 + $n * 1000,
					120344 + $n * 500,
					20344,
					$cpu,
					$mem,
					"12:3" . $n . ".44",
					$cmd,
				);
			}
			$lines[] = "";
			$lines[] = "model name      : Intel(R) Xeon(R) Gold 6248R CPU @ 3.00GHz";
			$lines[] = "cpu MHz         : 2999.998";
			$lines[] = "cache size      : 36608 KB";
			return implode("\n", $lines) . "\n";
		case "mem":
			return "               total        used        free      shared  buff/cache   available\nMem:            7940        3120         812         120        4007        4533\nSwap:           2047         118        1929\n";
		case "disk":
			return "Filesystem      Size  Used Avail Use% Mounted on\n/dev/vda1        80G   47G   30G  62% /\ntmpfs           3.9G  120M  3.8G   3% /dev/shm\n/dev/vdb1       200G  141G   51G  74% /backup\n/dev/vdc1       500G   33G  442G   7% /srv/mail-archiv-mit-langem-mountpunkt-fuer-layouttests\n";
		case "net":
			return "eth0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500\n        inet 203.0.113.10  netmask 255.255.255.0  broadcast 203.0.113.255\n        inet6 2001:db8::10  prefixlen 64  scopeid 0x0<global>\n        RX packets 482212311  bytes 612345678123 (570.2 GiB)\n        TX packets 391221004  bytes 288123456789 (268.3 GiB)\n\nlo: flags=73<UP,LOOPBACK,RUNNING>  mtu 65536\n        inet 127.0.0.1  netmask 255.0.0.0\n";
		case "web":
			return "<table border=\"1\"><tr><th>Server</th><th>Uptime</th><th>Requests</th></tr><tr><td>nginx/1.27.2</td><td>131 days</td><td>48 220 311</td></tr><tr><td>apache2/2.4.62</td><td>131 days</td><td>12 004 977</td></tr></table>\n";
		case "dns":
			return "version: BIND 9.18.28-1~deb12u2-Debian (Extended Support Version) <id:>\nboot time: Mon, 01 Sep 2025 06:01:44 GMT\nnumber of zones: 6 (0 automatic)\nserver is up and running\n";
		case "mail":
			return "Mail queue is empty\n\nexim 4.96 (Debian) - 14 delivered today, 3 deferred, 0 frozen\n";
		default:
			return "Uptime: 11340  Threads: 7  Questions: 84201331  Slow queries: 14  Opens: 322  Flush tables: 3  Open tables: 280  Queries per second avg: 7.42\n";
	}
}

return [
	"list_server_info" => function (string $variant): array {
		$kind = $variant ?: "cpu";
		$_GET = [$kind => ""];
		return ["body" => fx_server_info_body($kind)];
	},
	"list_weblog" => function (string $variant): array {
		$type = $variant === "error" ? "error" : "access";
		$_GET = ["domain" => "müller-und-söhne.de", "type" => $type];
		$lines = [];
		for ($n = 0; $n < 70; $n++) {
			if ($type === "access") {
				$lines[] = htmlentities(
					sprintf(
						'198.51.100.%d - - [05/Jan/2026:09:%02d:%02d +0100] "%s /%s HTTP/2.0" %d %d "https://www.google.de/" "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"',
						20 + ($n % 9),
						$n % 60,
						($n * 7) % 60,
						$n % 5 === 0 ? "POST" : "GET",
						$n % 4 === 0
							? "wp-admin/admin-ajax.php"
							: "produkte/küchenmaschine-" .
								$n .
								".html?ref=newsletter&utm_source=mail",
						$n % 11 === 0 ? 404 : 200,
						1000 + $n * 137,
					),
				);
			} else {
				$lines[] = htmlentities(
					sprintf(
						'2026/01/05 09:%02d:%02d [error] 1234#1234: *%d open() "/home/admin/web/müller-und-söhne.de/public_html/missing-%d.png" failed (2: No such file or directory), client: 198.51.100.%d, server: müller-und-söhne.de, request: "GET /missing-%d.png HTTP/2.0"',
						$n % 60,
						($n * 7) % 60,
						900 + $n,
						$n,
						20 + ($n % 9),
						$n,
					),
				);
			}
		}
		return ["body" => implode("\n", $lines) . "\n", "type" => $type];
	},
	"list_terminal" => function (): array {
		return [];
	},
];
