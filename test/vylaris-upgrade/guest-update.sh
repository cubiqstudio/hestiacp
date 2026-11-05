#!/bin/bash
# guest-update.sh - runs INSIDE the server: closes the network, then runs the update through
# the own channel (bin/v-update-sys-vylaris install) under strace.
#
# Usage: guest-update.sh <repo-ip> <out-dir> [open]
#   open: do NOT close the network (the update then reaches the real internet; the DNS of the
#         repo container forwards to public resolvers and logs the names). Default: closed.
#
#   * default route and the routes of the interface that had it are removed. What remains is the
#     internal test network, which has the repo container (https server + DNS) and nothing else.
#     (The IP address of the interface stays, so the panel's IP list is not changed.)
#   * /etc/resolv.conf points to the DNS of the repo container, which answers only the repo host
#     name and logs every query.
#   * strace -f follows every process the update starts (apt, dpkg, postinst, the upgrade
#     scripts, curl, wget) and records connect(), sendto(), sendmsg() and execve()/clone() (only to
#     tell which program made a connection).
set -u
REPO_IP=${1:?repo ip}
OUT=${2:?out dir}
MODE=${3:-closed}
mkdir -p "$OUT"

dev=$(ip route show default | awk '{print $5; exit}')
echo "interface with the default route: ${dev:-none}"
[ "$MODE" = closed ] && [ -n "$dev" ] && ip route flush dev "$dev"
printf 'nameserver %s\n' "$REPO_IP" > /etc/resolv.conf
{
	echo "--- routes after closing the network"
	ip route
	echo "--- resolv.conf"
	cat /etc/resolv.conf
} | tee "$OUT/network.txt"

echo "--- sanity: network mode '$MODE'. Closed: the outside world must be unreachable. The repo must be reachable."
for ip in 1.1.1.1 8.8.8.8 91.189.91.83; do
	[ "$MODE" = closed ] || break
	if curl -sS --max-time 5 -o /dev/null "https://$ip/" 2> "$OUT/egress-test.txt"; then
		echo "NETWORK NOT CLOSED: $ip is reachable" >&2
		exit 90
	fi
	echo "$ip: unreachable ($(head -c 100 "$OUT/egress-test.txt"))"
done
curl -sS --max-time 10 -o /dev/null -w 'repo.vylaris.test: HTTP %{http_code}\n' https://repo.vylaris.test/pubkey.gpg || exit 91

echo "--- state before the update (as the panel sees it)"
/usr/local/hestia/bin/v-update-sys-vylaris status | tee "$OUT/status-before.txt"

echo "--- v-update-sys-vylaris install (strace -f)"
export TERM=dumb
# markers in the query log of the resolver: net-summary.sh only counts what happens between them
getent hosts harness-marker-start.invalid > /dev/null 2>&1
strace -f -qq -tt -s 120 -e trace=connect,sendto,sendmsg,execve,clone,clone3,fork,vfork -o "$OUT/connect.trace" \
	/usr/local/hestia/bin/v-update-sys-vylaris install > "$OUT/update.log" 2>&1
echo $? > "$OUT/update.rc"
getent hosts harness-marker-end.invalid > /dev/null 2>&1
echo "update exit status: $(cat "$OUT/update.rc")"
# what the upgrade wrote about itself (also copied out by run.sh)
mkdir -p "$OUT/hst_backups"
cp -a /root/hst_backups/. "$OUT/hst_backups/" 2> /dev/null
cp /usr/local/hestia/log/vylaris-update.log "$OUT/" 2> /dev/null
tail -n 200 /var/log/apt/term.log > "$OUT/apt-term.log" 2> /dev/null
echo "--- state after the update"
/usr/local/hestia/bin/v-update-sys-vylaris status | tee "$OUT/status-after.txt"
