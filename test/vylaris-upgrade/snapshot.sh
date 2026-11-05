#!/bin/bash
# snapshot.sh - record the state of a VylarisSpace server that an update must not touch.
# Runs INSIDE the server (as root). Usage: snapshot.sh <out-dir> [label]
#
# Written to <out-dir>:
#   content/       a copy of the files of files.tsv up to 100 KB (for the diffs of compare.sh)
#   files.tsv      path  type  mode  owner:group  size  sha256  link-target  mtime
#                  for the admin / customer / branding / generated-config trees (list below)
#   pkgfiles.tsv   the same columns for every file owned by the package hestia (dpkg-query -L)
#   hestia-conf.kv sorted key=value content of /usr/local/hestia/conf/hestia.conf
#   etc-hestiacp.kv  the same for /etc/hestiacp/hestia.conf and local.conf (if present)
#   lists/*.json   what the panel itself reports (v-list-*), i.e. the customer data as the
#                  panel sees it
#   db-content.txt content of the customer test database (SQL)
#   dpkg.txt apt.txt services.txt   package version, apt policy, service states
#
# Read only: it does not change anything on the server.
set -u
OUT=${1:?usage: snapshot.sh <out-dir> [label]}
LABEL=${2:-snapshot}
mkdir -p "$OUT/lists"
H=/usr/local/hestia

# ---- trees that belong to the owner / the admin / the customers / the generated configs ----
TREES=(
	"$H/data"
	"$H/conf"
	/etc/hestiacp
	"$H/web/css/themes/custom"
	"$H/web/js/custom_scripts"
	"$H/web/images/custom"
	/etc/apt/sources.list.d
	/etc/apt/preferences.d
	/etc/apt/auth.conf.d
	/etc/apt/apt.conf.d/80-retries
	/usr/share/keyrings/vylarisspace-keyring.gpg
	/etc/nginx
	/etc/php
	/etc/exim4
	/etc/dovecot
	/etc/bind
	/etc/fail2ban
	/etc/cron.d
	/var/spool/cron/crontabs
	/etc/sudoers.d
	/etc/ssh/sshd_config
	/etc/ssh/sshd_config.d
	/etc/logrotate.d
	/etc/ssl/certs/dhparam.pem
	/etc/ssl/certs/hestia.crt
	/etc/ssl/private/hestia.key
)
# user trees: configuration, web content, mail, ssh keys, backups
for d in /home/*; do
	[ -d "$d" ] || continue
	for s in conf web mail .ssh .config .cache/_none_ backup .bash_history; do
		[ -e "$d/$s" ] && TREES+=("$d/$s")
	done
done

# volatile by nature, never part of a comparison (sockets, pid files, caches, sessions, logs)
EXCLUDES=(
	-path "$H/data/sessions/*" -o
	-path "$H/data/queue/*.pid" -o
	-path '/etc/nginx/*.pid' -o
	-path '*/.cache/*' -o
	-path '/etc/php/*/fpm/pool.d/*.sock'
)

{
	for t in "${TREES[@]}"; do
		[ -e "$t" ] || continue
		find "$t" \( "${EXCLUDES[@]}" \) -prune -o \( -type f -o -type l -o -type d \) -print0 2> /dev/null
	done
} | sort -zu > "$OUT/.paths0"

emit() { # reads NUL separated paths on stdin, writes the TSV rows
	while IFS= read -r -d '' p; do
		if [ -L "$p" ]; then
			printf '%s\tl\t%s\t%s\t%s\t-\t%s\t-\n' "$p" "$(stat -c '%a' -- "$p")" "$(stat -c '%U:%G' -- "$p")" 0 "$(readlink -- "$p")"
		elif [ -d "$p" ]; then
			printf '%s\td\t%s\t%s\t%s\t-\t-\t-\n' "$p" "$(stat -c '%a' -- "$p")" "$(stat -c '%U:%G' -- "$p")" 0
		elif [ -f "$p" ]; then
			printf '%s\tf\t%s\t%s\t%s\t%s\t-\t%s\n' "$p" "$(stat -c '%a' -- "$p")" "$(stat -c '%U:%G' -- "$p")" "$(stat -c '%s' -- "$p")" "$(sha256sum -- "$p" | cut -d' ' -f1)" "$(stat -c '%Y' -- "$p")"
		fi
	done
}
emit < "$OUT/.paths0" > "$OUT/files.tsv"
rm -f "$OUT/.paths0"

# a copy of every file up to 100 KB, so that compare.sh can show WHAT changed
mkdir -p "$OUT/content"
while IFS=$'\t' read -r p t _ _ sz _; do
	[ "$t" = f ] && [ "$sz" -le 102400 ] && cp --parents -- "$p" "$OUT/content/" 2> /dev/null
done < "$OUT/files.tsv"

# ---- files owned by the package hestia ----
if dpkg -s hestia > /dev/null 2>&1; then
	dpkg-query -L hestia | sort -u | while IFS= read -r p; do
		[ -f "$p" ] || [ -L "$p" ] && printf '%s\0' "$p"
	done | emit > "$OUT/pkgfiles.tsv"
fi

# ---- hestia.conf as key=value ----
kv() { # strip comments / empty lines, one KEY=VALUE per line, sorted
	[ -f "$1" ] && grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" | sort
}
kv "$H/conf/hestia.conf" > "$OUT/hestia-conf.kv"
{
	kv /etc/hestiacp/hestia.conf
	kv /etc/hestiacp/local.conf
} > "$OUT/etc-hestiacp.kv"

# ---- what the panel reports ----
if [ -x "$H/bin/v-list-users" ]; then
	export HESTIA=$H
	"$H/bin/v-list-users" json > "$OUT/lists/users.json" 2>&1
	for u in $("$H/bin/v-list-users" plain | awk '{print $1}'); do
		for c in list-user list-web-domains list-mail-domains list-databases list-dns-domains list-cron-jobs \
			list-user-ssh-keys list-backups list-user-notifications list-user-packages; do
			[ -x "$H/bin/v-$c" ] || continue
			case "$c" in
				list-user-notifications | list-user-packages) continue ;;
			esac
			"$H/bin/v-$c" "$u" json > "$OUT/lists/$u.$c.json" 2>&1
		done
		for d in $("$H/bin/v-list-mail-domains" "$u" plain 2> /dev/null | awk '{print $1}'); do
			"$H/bin/v-list-mail-accounts" "$u" "$d" json > "$OUT/lists/$u.mail-accounts.$d.json" 2>&1
		done
	done
	"$H/bin/v-list-firewall" json > "$OUT/lists/firewall.json" 2>&1
	"$H/bin/v-list-sys-config" json > "$OUT/lists/sys-config.json" 2>&1
	"$H/bin/v-list-sys-themes" json > "$OUT/lists/sys-themes.json" 2>&1
fi
# timestamps in the panel output change with every run: they are not part of the comparison
sed -i -E 's/"(TIME|DATE|SERIAL|U_DISK[A-Z_]*|U_BANDWIDTH)":[^,}]*[,}]?//' "$OUT"/lists/*.json 2> /dev/null || true

# ---- customer database content (a real row, written by seed.sh) ----
if command -v mariadb > /dev/null 2>&1 && mariadb -e 'select 1' > /dev/null 2>&1; then
	{
		mariadb -N -e 'show databases' | grep -v -E '^(information_schema|performance_schema|mysql|sys)$'
		mariadb -N -e 'select * from cust_shop.orders order by id' 2> /dev/null
		mariadb -N -e "select user,host from mysql.user where user like 'cust%' order by 1,2" 2> /dev/null
	} > "$OUT/db-content.txt"
fi

# ---- packages, apt, services ----
{
	dpkg -l hestia hestia-nginx hestia-php hestia-web-terminal 2> /dev/null | awk '$1 ~ /^[a-z][a-z]$/ {print $1, $2, $3}'
	dpkg -l | awk '$1 == "ii" {print $2, $3}' | sort
} > "$OUT/dpkg.txt"
{
	LC_ALL=C apt-cache policy hestia 2> /dev/null
	echo '--- pin_ok / versions as the panel sees them'
	"$H/bin/v-update-sys-vylaris" status 2> /dev/null
} > "$OUT/apt.txt"
systemctl list-units --type=service --state=running --no-legend --plain 2> /dev/null | awk '{print $1}' | sort > "$OUT/services.txt"
# ---- health: does everything still work? ----
{
	echo "panel login page: $(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1:8083/login/)"
	echo "nginx -t: $(nginx -t 2>&1 | tail -1)"
	if command -v named-checkconf > /dev/null; then echo "named-checkconf: rc=$(
		named-checkconf > /dev/null 2>&1
		echo $?
	)"; fi
	echo "failed units: $(systemctl --failed --no-legend --plain 2> /dev/null | awk '{print $1}' | tr '\n' ' ')"
	if id cust > /dev/null 2>&1; then
		ip=$("$H/bin/v-list-web-domain" cust shop.example.org plain 2> /dev/null | awk '{print $2; exit}')
		echo "customer site http : $(curl -sk -L --max-time 10 --resolve "shop.example.org:80:$ip" --resolve "shop.example.org:443:$ip" http://shop.example.org/ | grep -o 'SEED-MARKER')"
		echo "customer site https: $(curl -sk --max-time 10 --resolve "shop.example.org:443:$ip" -D - https://shop.example.org/ | grep -io -e 'SEED-MARKER' -e '^x-customer-include[^\r]*' | tr '\n' ' ')"
		echo "customer mailbox files: $(find /home/cust/mail -type f 2> /dev/null | wc -l)"
		echo "dns zone files: $(ls /home/cust/conf/dns 2> /dev/null | tr '\n' ' ')"
	fi
	echo "hestia package: $(dpkg-query -W -f='${Version}' hestia)"
	echo "marker file of build B: $([ -f $H/web/vylaris-build-marker.txt ] && echo present || echo absent)"
} > "$OUT/health.txt"
echo "$LABEL $(date -u +%FT%TZ)" > "$OUT/label.txt"
echo "snapshot '$LABEL': $(wc -l < "$OUT/files.tsv") files, $(wc -l < "$OUT/pkgfiles.tsv" 2> /dev/null || echo 0) package files -> $OUT"
