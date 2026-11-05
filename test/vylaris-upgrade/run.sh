#!/usr/bin/env bash
# run.sh - prove what an update through the own channel does to branding, admin settings,
# customisations and customer data, on a REAL VylarisSpace installation in Docker.
#
#   1. build deb A (revision 100) and deb B (revision 101 + a marker file) from a scratch copy
#   2. throw-away CA, signing key and signed apt repository; publish A; serve it over https
#   3. a systemd Ubuntu 24.04 container; the REAL installer (install/hst-install-ubuntu.sh)
#   4. seed.sh: branding, settings, custom theme/script/templates, a customer with web, ssl,
#      database, mail, dns, cron, ssh key, a firewall rule, a backup
#   5. snapshot.sh (before), publish B, close the network except the repo, run
#      bin/v-update-sys-vylaris install under strace, snapshot.sh (after)
#   6. compare.sh (strict), assert.sh, list of every network destination, README-style summary
#   7. guard phase on the same server: a foreign hestia package (dpkg -i and apt-get install) must be
#      refused and leave the server as it was; then a second own update (revision 102) must still
#      work; then, in throw-away copies of the server, the deliberate override must let the foreign
#      package in (file /etc/hestiacp/allow-foreign-hestia, variable VYLARIS_ALLOW_FOREIGN_HESTIA)
#
# Usage: run.sh [options]
#   --work DIR          work and result directory (default /tmp/vylaris-upgrade-test)
#   --reuse-debs        do not rebuild the debs if DIR/debs has them
#   --keep              keep containers and network after the run (for inspection)
#   --admin-user NAME   panel admin user created by the installer (default: admin)
#   --install-args STR  options for the installer instead of the default service set
#   --open-network      do NOT close the network for the update: the update reaches the real internet
#                       (shows what it does on a normal server, e.g. the Cloudflare IP list).
#                       Results go to DIR/result-open instead of DIR/result.
#   --no-seed           skip seed.sh (the comparison then only shows the installer defaults)
#   --no-guard          skip the guard phase (step 7)
#   --rebuild-images    rebuild the docker images even if they exist
#   -h, --help
# Environment: PREFIX (name prefix of containers/network, default vyup),
#              VYLUP_EXTRA_CA (PEM file with CA certificates the images must trust, default
#              /root/.ccr/ca-bundle.crt when it exists: needed behind a TLS intercepting proxy).
#
# The checkout is only read. Exit status: 0 when the update left every protected thing alone,
# 1 when compare.sh found an unexpected difference, 2 when the test itself could not run.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-/tmp/vylaris-upgrade-test}
PREFIX=${PREFIX:-vyup}
REUSE_DEBS=0
KEEP=0
ADMIN='admin'
DO_SEED=1
NETMODE=closed
REBUILD_IMAGES=0
DO_GUARD=1
HOSTNAME_FQDN=server.vylaris.test
REPO_HOST=repo.vylaris.test
INSTALL_ARGS="--apache no --phpfpm yes --multiphp no --vsftpd no --proftpd no --named yes --mysql yes --postgresql no --exim yes --dovecot yes --clamav no --spamassassin no --iptables yes --fail2ban no --quota no --api yes"
ADMIN_PASS='Vylaris-Test-2026x'

while [ $# -gt 0 ]; do
	case "$1" in
		--work)
			WORK=$2
			shift 2
			;;
		--reuse-debs)
			REUSE_DEBS=1
			shift
			;;
		--keep)
			KEEP=1
			shift
			;;
		--admin-user)
			ADMIN=$2
			shift 2
			;;
		--install-args)
			INSTALL_ARGS=$2
			shift 2
			;;
		--no-seed)
			DO_SEED=0
			shift
			;;
		--open-network)
			NETMODE=open
			shift
			;;
		--no-guard)
			DO_GUARD=0
			shift
			;;
		--rebuild-images)
			REBUILD_IMAGES=1
			shift
			;;
		-h | --help)
			sed -n '2,36p' "$0"
			exit 0
			;;
		*)
			echo "unknown option: $1" >&2
			exit 2
			;;
	esac
done

SYS=$PREFIX-sys
REPOC=$PREFIX-repo
NET=$PREFIX-net
IMG_SYS=vylaris-upgrade-sys
IMG_REPO=vylaris-upgrade-repo
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
RES=$WORK/result
[ "$NETMODE" = open ] && RES=$WORK/result-open
STATE=$WORK/repo-state
LOG=$WORK/logs
mkdir -p "$LOG"

say() { printf '\n==> %s\n' "$*"; }
die() {
	printf '\nrun.sh: %s\n' "$*" >&2
	exit 2
}
# run a command in the server container with a normal root umask (docker exec starts with 0000)
sx() { docker exec -e TERM=dumb "$SYS" bash -c 'umask 022; exec "$@"' _ "$@"; }

cleanup() {
	local rc=$?
	if [ "$KEEP" -eq 0 ]; then
		docker rm -f "$SYS" "$REPOC" > /dev/null 2>&1
		docker network rm "$NET" > /dev/null 2>&1
	else
		echo "containers kept: $SYS $REPOC (network $NET); remove with: docker rm -f $SYS $REPOC; docker network rm $NET"
	fi
	"$HERE/repo.sh" clean "$STATE" 2> /dev/null
	exit "$rc"
}
trap cleanup EXIT

# ------------------------------------------------------------------ preflight
say "preflight"
for t in docker openssl gpg reprepro dpkg-deb git node npm composer flock; do
	command -v "$t" > /dev/null || die "$t not found on this host"
done
docker ps > /dev/null 2>&1 || die "the docker daemon is not reachable (docker ps fails). Start it (dockerd) first."
docker rm -f "$SYS" "$REPOC" > /dev/null 2>&1
docker network rm "$NET" > /dev/null 2>&1
rm -rf "$RES"
mkdir -p "$RES"

# ------------------------------------------------------------------ images
say "docker images"
build_image() { # name file
	if [ "$REBUILD_IMAGES" -eq 0 ] && docker image inspect "$1" > /dev/null 2>&1; then
		echo "image $1 exists (use --rebuild-images to rebuild)"
		return
	fi
	local ctx=$WORK/docker-ctx
	rm -rf "$ctx"
	mkdir -p "$ctx/extra-ca"
	cp "$HERE/Dockerfile" "$HERE/Dockerfile.repo" "$ctx/"
	local ca=${VYLUP_EXTRA_CA:-/root/.ccr/ca-bundle.crt}
	[ -f "$ca" ] && cp "$ca" "$ctx/extra-ca/extra.crt"
	docker build -q -t "$1" -f "$ctx/$2" --build-arg "BASE=$IMG_SYS" "$ctx" > "$LOG/docker-build-$1.log" 2>&1 \
		|| {
			tail -20 "$LOG/docker-build-$1.log"
			die "docker build $1 failed"
		}
	echo "built $1"
}
build_image "$IMG_SYS" Dockerfile
build_image "$IMG_REPO" Dockerfile.repo

# ------------------------------------------------------------------ debs
say "build deb A (revision 100) and deb B (revision 101 + marker) from a scratch copy"
if [ "$REUSE_DEBS" -eq 1 ] && ls "$WORK"/debs/hestia_*-100+*.deb "$WORK"/debs/hestia_*-101+*.deb > /dev/null 2>&1 && [ -d "$WORK/build/tree-A" ]; then
	echo "reusing $WORK/debs"
else
	"$HERE/build-debs.sh" "$ROOT" "$WORK/build" "$WORK/debs" || die "build failed"
fi
DEB_A=$(ls "$WORK"/debs/hestia_*-100+*.deb)
DEB_B=$(ls "$WORK"/debs/hestia_*-101+*.deb)
echo "A: $(basename "$DEB_A")"
echo "B: $(basename "$DEB_B")"

# ------------------------------------------------------------------ repository
say "throw-away CA, signing key, signed apt repository (A published)"
"$HERE/repo.sh" clean "$STATE" 2> /dev/null
rm -rf "$STATE"
REPO_HOST=$REPO_HOST "$HERE/repo.sh" init "$STATE" || die "repo init failed"
# shellcheck disable=SC1091
. "$STATE/env"
"$HERE/repo.sh" publish "$STATE" "$DEB_A" > "$LOG/publish-A.log" 2>&1 || {
	cat "$LOG/publish-A.log"
	die "publish A failed"
}
grep -E 'published|signed by' "$LOG/publish-A.log"

cat > "$WORK/nginx-repo.conf" << EOC
events {}
http {
  access_log /var/log/nginx/repo-access.log;
  server {
    listen 443 ssl;
    server_name $REPO_HOST;
    ssl_certificate /ca/server.crt;
    ssl_certificate_key /ca/server.key;
    root /srv/repo/public;
    autoindex off;
  }
}
EOC

say "containers: internal network, repo container ($REPO_HOST), server container (systemd)"
docker network create --internal "$NET" > /dev/null || die "network create failed"
docker run -d --name "$REPOC" --network "$NET" --network-alias "$REPO_HOST" \
	-v "$STATE/repo/public:/srv/repo/public:ro" -v "$STATE/ca:/ca:ro" -v "$WORK/nginx-repo.conf:/etc/nginx/nginx.conf:ro" \
	--entrypoint nginx "$IMG_REPO" -g 'daemon off;' > /dev/null || die "repo container failed"
REPO_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$REPOC")
dns_upstream=(--no-resolv)
if [ "$NETMODE" = open ]; then
	# the resolver forwards to public DNS, so the repo container needs the internet too
	docker network connect bridge "$REPOC"
	dns_upstream=(--no-resolv --server=8.8.8.8 --server=8.8.4.4)
fi
docker exec -d "$REPOC" dnsmasq --keep-in-foreground --conf-file=/dev/null "${dns_upstream[@]}" --no-hosts --log-queries \
	--log-facility=/var/log/dnsmasq.log --bind-interfaces --listen-address="$REPO_IP" --host-record="$REPO_HOST,$REPO_IP"
echo "repo container $REPO_IP"

docker run -d --name "$SYS" --hostname "$HOSTNAME_FQDN" --privileged --cgroupns=host \
	-v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock --network "$NET" "$IMG_SYS" > /dev/null || die "server container failed"
# the first network is the internal one; the default bridge gives internet access for the installer only
docker network connect bridge "$SYS" || die "network connect failed"
for _ in $(seq 1 30); do
	st=$(docker exec "$SYS" systemctl is-system-running 2> /dev/null)
	[ "$st" = running ] || [ "$st" = degraded ] && break
	sleep 1
done
echo "systemd in the server container: $st"
docker cp "$STATE/ca/ca.crt" "$SYS:/usr/local/share/ca-certificates/vylaris-test-ca.crt"
sx update-ca-certificates > /dev/null 2>&1
sx curl -sS -o /dev/null -w "server -> https://$REPO_HOST/: HTTP %{http_code}\n" "https://$REPO_HOST/pubkey.gpg" || die "server cannot reach the repo"

# Test-environment shim, not part of the product: the kernel of this host may have no IPv6, and
# the Dovecot configuration of the installer has "listen = *, ::", which then cannot start.
if ! docker exec "$SYS" test -e /proc/net/if_inet6; then
	echo "NOTE: no IPv6 in this kernel; dovecot gets a systemd drop-in that rewrites 'listen' to IPv4 (test shim)"
	sx bash -c 'mkdir -p /etc/systemd/system/dovecot.service.d; printf "[Service]\nExecStartPre=+/bin/sed -i \"s/^listen = .*/listen = */\" /etc/dovecot/dovecot.conf\n" > /etc/systemd/system/dovecot.service.d/test-no-ipv6.conf'
fi

# ------------------------------------------------------------------ installer
say "REAL installer: install/hst-install-ubuntu.sh (this takes about 6-10 minutes)"
docker cp "$WORK/build/tree-A/install" "$SYS:/root/install-src"
# shellcheck disable=SC2086
sx bash -c "cd /root/install-src && bash hst-install-ubuntu.sh --vylaris-repo https://$REPO_HOST --vylaris-key-fingerprint $KEY_FPR \
	-f --interactive no --username $ADMIN --hostname $HOSTNAME_FQDN --email admin@example.com --password '$ADMIN_PASS' --lang en $INSTALL_ARGS" \
	> "$LOG/installer.log" 2>&1
rc=$?
tail -12 "$LOG/installer.log" | sed 's/\x1b\[[0-9;]*m//g'
[ "$rc" -eq 0 ] || die "the installer failed (exit $rc); log: $LOG/installer.log"
grep -q 'successfully installed' "$LOG/installer.log" || die "installer finished without the success message; log: $LOG/installer.log"
for _ in $(seq 1 20); do
	[ "$(sx curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8083/login/)" = 200 ] && break
	sleep 2
done
echo "installed: $(sx dpkg-query -W -f='${Package} ${Version}\n' hestia hestia-nginx hestia-php | tr '\n' ';')"

# ------------------------------------------------------------------ seed + snapshot before
docker cp "$HERE/seed.sh" "$SYS:/root/seed.sh"
docker cp "$HERE/snapshot.sh" "$SYS:/root/snapshot.sh"
docker cp "$HERE/guest-update.sh" "$SYS:/root/guest-update.sh"
docker cp "$HERE/guard-phase.sh" "$SYS:/root/guard-phase.sh"
if [ "$DO_SEED" -eq 1 ]; then
	say "seed.sh"
	sx bash /root/seed.sh > "$LOG/seed.log" 2>&1
	seed_rc=$?
	tail -3 "$LOG/seed.log"
	[ "$seed_rc" -eq 0 ] || echo "WARNING: seed.sh had failing steps, see $LOG/seed.log"
fi
say "snapshot before"
sx bash /root/snapshot.sh /root/snap-before before || die "snapshot failed"

# ------------------------------------------------------------------ update
say "publish B and run the update through the own channel (network: $NETMODE)"
"$HERE/repo.sh" publish "$STATE" "$DEB_B" > "$LOG/publish-B.log" 2>&1 || {
	cat "$LOG/publish-B.log"
	die "publish B failed"
}
grep -E 'published|signed by' "$LOG/publish-B.log"
ACCESS_BEFORE=$(docker exec "$REPOC" sh -c 'wc -l < /var/log/nginx/repo-access.log')
sx bash /root/guest-update.sh "$REPO_IP" /root/upd "$NETMODE" 2>&1 | tee "$LOG/guest-update.log"
upd_rc=$(docker exec "$SYS" cat /root/upd/update.rc 2> /dev/null || echo missing)
say "snapshot after"
sx bash /root/snapshot.sh /root/snap-after after || die "snapshot failed"

# ------------------------------------------------------------------ collect + compare
say "collect and compare"
for d in snap-before snap-after upd; do docker cp "$SYS:/root/$d" "$RES/$d" > /dev/null; done
docker cp "$REPOC:/var/log/dnsmasq.log" "$RES/dnsmasq.log" > /dev/null
docker exec "$REPOC" tail -n +"$((ACCESS_BEFORE + 1))" /var/log/nginx/repo-access.log > "$RES/repo-access-update.log"
"$HERE/compare.sh" --pkg-tsv "$DEB_A" > "$RES/pkg-A.tsv"
"$HERE/compare.sh" --pkg-tsv "$DEB_B" > "$RES/pkg-B.tsv"
NETMODE=$NETMODE "$HERE/net-summary.sh" "$RES/upd/connect.trace" "$RES/dnsmasq.log" "$REPO_IP" "$RES/repo-access-update.log" > "$RES/network.txt"
# strict: the update runs no upgrade step and no user rebuild, so volatile fields must not differ either
"$HERE/compare.sh" "$RES/snap-before" "$RES/snap-after" --pkg-a "$RES/pkg-A.tsv" --pkg-b "$RES/pkg-B.tsv" --strict > "$RES/compare.txt"
cmp_rc=$?

{
	echo "update through the own channel: exit status $upd_rc"
	echo "installed before: $(grep -m1 '^ii hestia ' "$RES/snap-before/dpkg.txt")"
	echo "installed after : $(grep -m1 '^ii hestia ' "$RES/snap-after/dpkg.txt")"
} > "$RES/summary.txt"

say "RESULT FILES in $RES: compare.txt network.txt summary.txt upd/update.log upd/connect.trace"
cat "$RES/summary.txt"
echo
cat "$RES/compare.txt"
echo
echo "################ network destinations during 'v-update-sys-vylaris install' ################"
cat "$RES/network.txt"
[ "$upd_rc" = 0 ] || {
	echo "the update command itself failed (exit $upd_rc), see $RES/upd/update.log"
	exit 2
}

# ------------------------------------------------------------------ explicit assertions
say "assert.sh: what must hold after the update"
"$HERE/assert.sh" "$RES" "$NETMODE" | tee "$RES/assert.txt"
assert_rc=${PIPESTATUS[0]}

# ------------------------------------------------------------------ guard phase
guard_rc=0
guard_fail=0
if [ "$DO_GUARD" -eq 1 ] && [ "$NETMODE" = closed ]; then
	GD=$RES/guard
	XD=$WORK/debs-extra
	mkdir -p "$GD" "$XD"
	rm -f "$XD"/*.deb
	B_VER=$(dpkg-deb -f "$DEB_B" Version)
	SFX=${B_VER#*+}
	FOREIGN_VER="1.10.6-1+$SFX"
	C_VER=${B_VER/-101+/-102+}
	"$HERE/repack-deb.sh" foreign "$DEB_B" "$XD/foreign.deb" "$FOREIGN_VER" || die "repack foreign failed"
	"$HERE/repack-deb.sh" own "$DEB_B" "$XD/hestia_${C_VER}_amd64.deb" "$C_VER" || die "repack own failed"

	say "guard phase 1: foreign hestia $FOREIGN_VER over the installed $B_VER (dpkg -i, apt-get install)"
	sx mkdir -p /root/guard
	docker cp "$XD/foreign.deb" "$SYS:/root/guard/foreign.deb"
	sx bash /root/guard-phase.sh > "$GD/guard-phase.log" 2>&1
	echo "guard-phase.sh exit status $?"
	grep -E '^(PASS|FAIL|###|guard phase)|REFUSED|exit [0-9]+\]' "$GD/guard-phase.log" | sed 's/^/  /'
	sx bash /root/snapshot.sh /root/snap-guard guard > /dev/null || die "snapshot failed"
	docker cp "$SYS:/root/snap-guard" "$RES/snap-guard" > /dev/null
	docker cp "$SYS:/root/guard/." "$GD/raw" > /dev/null
	"$HERE/compare.sh" "$RES/snap-after" "$RES/snap-guard" --strict > "$GD/compare-after-refusals.txt"
	g_cmp1=$?
	echo "compare snapshot after the update -> after the refused attempts: $(grep -m1 'RESULT:' "$GD/compare-after-refusals.txt")"
	echo "                                                                 $(grep -A1 -m1 'RESULT:' "$GD/compare-after-refusals.txt" | tail -1)"

	say "guard phase 2: recovery, a second own update (revision 102) through the same channel"
	"$HERE/repo.sh" publish "$STATE" "$XD/hestia_${C_VER}_amd64.deb" > "$LOG/publish-C.log" 2>&1 || {
		cat "$LOG/publish-C.log"
		die "publish C failed"
	}
	grep -E 'published|signed by' "$LOG/publish-C.log"
	sx bash /root/guest-update.sh "$REPO_IP" /root/upd2 closed > "$LOG/guest-update2.log" 2>&1
	upd2_rc=$(docker exec "$SYS" cat /root/upd2/update.rc 2> /dev/null || echo missing)
	echo "second update exit status: $upd2_rc"
	sx bash /root/snapshot.sh /root/snap-c recovery > /dev/null || die "snapshot failed"
	docker cp "$SYS:/root/upd2" "$GD/upd2" > /dev/null
	docker cp "$SYS:/root/snap-c" "$RES/snap-recovery" > /dev/null
	# deb B and deb C have the same files, so the package file lists are the same
	# (compare.sh tells its two package lists apart by file name, so B is passed as two files)
	cp "$RES/pkg-B.tsv" "$RES/pkg-C.tsv"
	"$HERE/compare.sh" "$RES/snap-guard" "$RES/snap-recovery" --pkg-a "$RES/pkg-B.tsv" --pkg-b "$RES/pkg-C.tsv" --strict > "$GD/compare-after-second-update.txt"
	g_cmp2=$?
	echo "compare after the refused attempts -> after the second update: $(grep -m1 'RESULT:' "$GD/compare-after-second-update.txt")"
	echo "                                                              $(grep -A1 -m1 'RESULT:' "$GD/compare-after-second-update.txt" | tail -1)"
	{
		g2() { # description, command...
			local d=$1
			shift
			if "$@" > /dev/null 2>&1; then echo "PASS: $d"; else echo "FAIL: $d"; fi
		}
		echo "### recovery checks"
		g2 "second update exited 0" test "$upd2_rc" = 0
		g2 "installed hestia is $C_VER" grep -qxF "ii hestia $C_VER" "$RES/snap-recovery/dpkg.txt"
		g2 "second update ran no version step" bash -c "! grep -Eqi 'applying patches' '$GD/upd2/update.log'"
		g2 "second update started no v-rebuild-* program" bash -c "! grep -Eq 'execve\\([^)]*v-rebuild-' '$GD/upd2/connect.trace'"
		g2 "panel login page 200 after the second update" grep -q '^panel login page: 200' "$RES/snap-recovery/health.txt"
		g2 "guard still installed (hook file, checker, prerm)" sx bash -c 'test -f /etc/apt/apt.conf.d/90vylarisspace-guard && test -x /usr/local/hestia/bin/v-check-package-source && test -x /var/lib/dpkg/info/hestia.prerm'
		g2 "foreign package is still refused after the second update" sx bash -c '! dpkg -i /root/guard/foreign.deb'
		g2 "compare after the refused attempts: 0 unexpected" test "$g_cmp1" -eq 0
		g2 "compare after the second update: 0 unexpected" test "$g_cmp2" -eq 0
		g2 "hestia.conf keys after the second update equal the keys after the first (SERVER_SMTP_PASSWD, OWNER_NOTE ...)" diff "$RES/snap-after/hestia-conf.kv" "$RES/snap-recovery/hestia-conf.kv"
	} > "$GD/recovery.log" 2>&1
	sed 's/^/  /' "$GD/recovery.log"

	say "guard phase 3: deliberate override, in throw-away copies of the server (docker commit, no systemd)"
	OVIMG=vylaris-upgrade-override-copy
	docker commit "$SYS" "$OVIMG" > /dev/null || die "docker commit failed"
	: > "$GD/override.log"
	for combo in "file dpkg" "env apt"; do
		set -- $combo
		docker run --rm --network none --entrypoint bash -v "$XD:/guard:ro" -v "$HERE/guard-override.sh:/guard-override.sh:ro" "$OVIMG" \
			/guard-override.sh "$1" "$2" >> "$GD/override.log" 2>&1
		echo "override ($1/$2) exit status $?"
	done
	docker rmi "$OVIMG" > /dev/null 2>&1
	grep -E '^(PASS|FAIL|override)' "$GD/override.log" | sed 's/^/  /'

	guard_fail=$(cat "$GD"/guard-phase.log "$GD"/recovery.log "$GD"/override.log | grep -c '^FAIL')
	guard_pass=$(cat "$GD"/guard-phase.log "$GD"/recovery.log "$GD"/override.log | grep -c '^PASS')
	echo
	echo "guard phase total: $guard_pass PASS, $guard_fail FAIL"
	[ "$guard_fail" -eq 0 ] || guard_rc=1
elif [ "$DO_GUARD" -eq 1 ]; then
	echo "guard phase skipped (open network run)"
fi

echo
echo "################################ RESULT ################################"
echo "update exit status      : $upd_rc"
echo "compare.sh (strict)     : $(grep -m1 'RESULT:' "$RES/compare.txt")"
echo "                          $(grep -A1 -m1 'RESULT:' "$RES/compare.txt" | tail -1)"
echo "assert.sh               : $(tail -1 "$RES/assert.txt")"
[ "$DO_GUARD" -eq 1 ] && [ "$NETMODE" = closed ] && echo "guard phase             : $guard_pass PASS, $guard_fail FAIL"
echo "########################################################################"
final=0
[ "$cmp_rc" -eq 0 ] || final=1
[ "$assert_rc" -eq 0 ] || final=1
[ "$guard_rc" -eq 0 ] || final=1
exit "$final"
