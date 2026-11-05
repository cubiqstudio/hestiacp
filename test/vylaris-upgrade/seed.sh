#!/bin/bash
# seed.sh - fill a freshly installed VylarisSpace server with the things an update must not touch.
# Runs INSIDE the server as root, after the installer. Everything goes through the real v-*
# commands where there is one; plain file writes are used only for what an admin edits by hand
# (custom theme, custom script, edited template, hand-edited hestia.conf line, mail file).
# Usage: seed.sh            (exit status 0 when every step worked)
set -u
export HESTIA=/usr/local/hestia
export PATH="$PATH:$HESTIA/bin"
H=$HESTIA
FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

step() { printf '\n[seed] %s\n' "$*"; }
run() { # run a command, log it, count failures
	printf '  $ %s\n' "$*"
	"$@"
	local rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "  [seed] FAILED (exit $rc): $*"
		FAILED=$((FAILED + 1))
	fi
}

# ------------------------------------------------------------------------------------------
step "1. branding and admin settings (hestia.conf through v-change-sys-config-value)"
run v-change-sys-config-value APP_NAME 'Customer Brand'
run v-change-sys-config-value TITLE '{{page}} - {{hostname}} - Customer Brand'
run v-change-sys-config-value THEME 'vylaris-dark'
run v-change-sys-config-value HIDE_DOCS 'no'
run v-change-sys-config-value UPGRADE_SEND_EMAIL 'false'
run v-change-sys-config-value POLICY_USER_VIEW_LOGS 'no'
run v-change-sys-config-value INACTIVE_SESSION_TIMEOUT '45'
run v-change-sys-config-value LANGUAGE 'de'
run v-change-sys-config-value DISABLE_IP_CHECK 'yes'
echo "  hand edit of conf/hestia.conf (non-default BACKUP_GZIP, one key the panel does not know)"
sed -i "s/^BACKUP_GZIP=.*/BACKUP_GZIP='7'/" "$H/conf/hestia.conf"
printf "OWNER_NOTE='written by hand, must survive'\n" >> "$H/conf/hestia.conf"
echo "  values that contain a hash sign (an SMTP password style value must not be cut at the #)"
# SERVER_SMTP_PASSWD exists in a fresh hestia.conf (empty): the admin replaces the value
sed -i "s/^SERVER_SMTP_PASSWD=.*/SERVER_SMTP_PASSWD='pa#ss'/" "$H/conf/hestia.conf"
printf "OWNER_HASH_NOTE='a#b # c&d|e'\n" >> "$H/conf/hestia.conf"
echo "  a key that appears twice (a hand edit gone wrong): the upgrade merges it, the last value wins"
printf "OWNER_DUP='first'\nOWNER_DUP='last#value|with&chars'\n" >> "$H/conf/hestia.conf"
echo "  /etc/hestiacp/local.conf (the file the header of hestia.conf tells the admin to use)"
cat > /etc/hestiacp/local.conf << 'EOL'
# local settings of the owner
export OWNER_LOCAL_SETTING='local-conf-must-survive'
EOL

# ------------------------------------------------------------------------------------------
step "2. custom theme, custom script, custom logos (whitelabel)"
mkdir -p "$H/web/css/themes/custom" "$H/web/images/custom"
cat > "$H/web/css/themes/custom/mytheme.css" << 'EOL'
/* customer theme */
body { background: #123456; }
EOL
echo '/* customer theme, second file */' > "$H/web/css/themes/custom/other.css"
cat > "$H/web/js/custom_scripts/custom.js" << 'EOL'
// customer script, loaded by the panel on every page
console.log('customer script');
EOL
cat > "$H/web/images/custom/logo.svg" << 'EOL'
<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="#c0ffee"/></svg>
EOL
cp "$H/web/images/custom/logo.svg" "$H/web/images/custom/logo-header.svg"
cp "$H/web/images/favicon.png" "$H/web/images/custom/favicon.png"
printf 'customer-logo-png' > "$H/web/images/custom/logo.png"
run v-update-white-label-logo
echo "  canary: a package-owned file edited by hand (NOT a supported customisation, expected to be replaced)"
echo '/* hand edit of a package file */' >> "$H/web/css/themes/dark.min.css"
run v-change-user-theme admin 'mytheme'
run v-list-sys-themes plain

# ------------------------------------------------------------------------------------------
step "3. edited and new templates (web / mail / dns), custom hosting package"
T=$H/data/templates
echo '# EDITED BY THE OWNER (web template)' >> "$T/web/nginx/default.tpl"
echo '# EDITED BY THE OWNER (web template, ssl)' >> "$T/web/nginx/default.stpl"
cp "$T/web/nginx/default.tpl" "$T/web/nginx/ownertpl.tpl"
cp "$T/web/nginx/default.stpl" "$T/web/nginx/ownertpl.stpl"
cp "$T/web/nginx/php-fpm/default.tpl" "$T/web/nginx/php-fpm/ownerphp.tpl" 2> /dev/null || true
cp "$T/web/nginx/php-fpm/default.stpl" "$T/web/nginx/php-fpm/ownerphp.stpl" 2> /dev/null || true
echo '; EDITED BY THE OWNER (php-fpm pool template)' >> "$T/web/php-fpm/default.tpl"
echo '# EDITED BY THE OWNER (mail domain template)' >> "$T/mail/nginx/default.tpl"
echo "  dns template: one extra record line appended (format: ID='..' RECORD='..' ...)"
printf "ID='90' RECORD='_owner' TYPE='TXT' PRIORITY='' VALUE='\"owner-dns-template\"' SUSPENDED='no' TIME='%%time%%' DATE='%%date%%'\n" >> "$T/dns/default.tpl"
cp "$T/dns/default.tpl" "$T/dns/ownerdns.tpl"
sed "s/^WEB_DOMAINS=.*/WEB_DOMAINS='25'/" "$H/data/packages/default.pkg" > "$TMP/ownerpkg.pkg"
run v-add-user-package "$TMP/ownerpkg.pkg" ownerpkg

# ------------------------------------------------------------------------------------------
step "4. a customer: web domain with ssl, database with content, mail, dns, cron, ssh key"
run v-add-user cust 'Seed-Passw0rd-1' cust@example.org default Cust Omer
IP=$(v-list-sys-ips plain | awk 'NR==1 {print $1}')
echo "  server ip: $IP"
run v-add-web-domain cust shop.example.org "$IP" yes www.shop.example.org
echo '<html><body>customer site v1 SEED-MARKER</body></html>' > /home/cust/web/shop.example.org/public_html/index.html
chown cust:cust /home/cust/web/shop.example.org/public_html/index.html
echo "  own ssl certificate for the domain"
mkdir -p "$TMP/ssl"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=shop.example.org' \
	-keyout "$TMP/ssl/shop.example.org.key" -out "$TMP/ssl/shop.example.org.crt" 2> /dev/null
run v-add-web-domain-ssl cust shop.example.org "$TMP/ssl" yes
echo "  custom nginx include of the customer (the templates include conf_* files)"
echo 'add_header X-Customer-Include "kept";' > /home/cust/conf/web/shop.example.org/nginx.conf_customer
echo 'add_header X-Customer-Include-Ssl "kept";' > /home/cust/conf/web/shop.example.org/nginx.ssl.conf_customer
echo "  admin-owned nginx file outside of the generated tree"
echo "  canary: the admin adds an own CDN range to the generated Cloudflare list (the update rewrites that file when it can reach the Cloudflare API)"
echo 'set_real_ip_from 203.0.113.0/24; # added by the owner' >> /etc/nginx/conf.d/cloudflare.inc
printf "# owner file\nlog_format ownerfmt '\$remote_addr owner';\n" > /etc/nginx/conf.d/zz-owner-custom.conf
nginx -t

run v-add-database cust shop shopuser 'Db-Passw0rd-1' mysql
mariadb cust_shop -e "create table orders (id int primary key, item varchar(40)); insert into orders values (1,'order-one'),(2,'order-two');" \
	|| {
		echo "  [seed] FAILED: database content"
		FAILED=$((FAILED + 1))
	}

run v-add-dns-domain cust shop.example.org "$IP"
run v-add-dns-record cust shop.example.org shopwww A 192.0.2.11
run v-add-mail-domain cust shop.example.org no no no
run v-add-mail-account cust shop.example.org info 'Mail-Passw0rd-1'
mdir=/home/cust/mail/shop.example.org/info
mkdir -p "$mdir/cur" 2> /dev/null
printf 'From: a@example.org\nSubject: SEED-MAIL\n\nbody\n' > "$mdir/cur/1700000000.seed:2,S"
chown -R cust:mail /home/cust/mail/shop.example.org 2> /dev/null || true
run v-add-mail-account-alias cust shop.example.org info sales

run v-add-cron-job cust 15 3 '*' '*' '*' 'echo seed-cron > /dev/null'
ssh-keygen -q -t ed25519 -N '' -C seed-key -f "$TMP/key"
run v-add-user-ssh-key cust "$(cat "$TMP/key.pub")"

step "5. firewall rule, backup"
run v-add-firewall-rule ACCEPT 203.0.113.7 8123 TCP 'owner rule'
run v-backup-user cust no
ls -l /backup 2> /dev/null

echo
if [ "$FAILED" -eq 0 ]; then
	echo "[seed] done, every step worked"
else
	echo "[seed] done with $FAILED failed step(s)"
fi
[ "$FAILED" -eq 0 ]
