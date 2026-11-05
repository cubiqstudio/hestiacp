#!/usr/bin/env bash
# net-summary.sh - list every network destination an update tried to reach, and who tried.
#   net-summary.sh <connect.trace> <dnsmasq.log> <repo-ip> <repo-access.log>
# connect.trace: strace -f output (connect, sendto, sendmsg, execve) of the update;
# dnsmasq.log: query log of the resolver the server used (only the part between the two
# harness-marker queries is read); repo-access.log: nginx log of the repo container.
set -u
TRACE=${1:?trace}
DNSLOG=${2:?dnsmasq log}
REPO_IP=${3:?repo ip}
ACCESS=${4:-/dev/null}

echo "== network destinations in the trace, with the program that made the call"
if [ "${NETMODE:-closed}" = closed ]; then
	echo "   (the network was closed except the repo container: anything that is not the repo failed)"
else
	echo "   (the network was OPEN: the destinations that are not the repo were really reached)"
fi
awk -v repo="$REPO_IP" '
	function cls(ip, port) {
		if (port == 0) return "port 0: local address / route probe, no packet leaves the host"
		if (ip == repo && port == 53) return "DNS of the test repo container (the resolver of the server)"
		if (ip == repo && port == 443) return "TEST REPO (https)"
		if (ip ~ /^127\./) return "loopback (local service)"
		return "OUTSIDE (not the test repo)"
	}
	/ (clone|clone3|fork|vfork)\(.* = [0-9]+$/ {
		child = $0; sub(/.* = /, "", child)
		if ($1 in prog) prog[child] = prog[$1]
		next
	}
	/ execve\(/ {
		pid = $1
		if (match($0, /execve\("[^"]*", \[[^]]*\]/)) {
			e = substr($0, RSTART + 8, RLENGTH - 8)
			path = e; sub(/".*/, "", path)
			args = e; sub(/^[^[]*\[/, "", args); sub(/\]$/, "", args); gsub(/"/, "", args); gsub(/, /, " ", args)
			if (length(args) > 90) args = substr(args, 1, 90) "..."
			prog[$1] = args
		}
		next
	}
	/AF_UNIX/ { u++; next }
	/AF_NETLINK/ { nl++; next }
	/sin_port=htons/ {
		if (match($0, /sin_port=htons\([0-9]+\), sin_addr=inet_addr\("[^"]+"\)/)) {
			s = substr($0, RSTART, RLENGTH)
			port = s; sub(/^sin_port=htons\(/, "", port); sub(/\).*/, "", port)
			ip = s; sub(/.*inet_addr\("/, "", ip); sub(/".*/, "", ip)
			res = "ok"
			if ($0 ~ / = -1 /) { res = $0; sub(/.* = -1 /, "", res); sub(/ .*/, "", res) }
			else if ($0 ~ /EINPROGRESS/) res = "started (non-blocking)"
			else if ($0 ~ /unfinished/) res = "started"
			key = ip ":" port "|" cls(ip, port) "|" res
			cnt[key]++
			who = prog[$1]; if (who == "") who = "(pid " $1 ")"
			if (index(by[key], "<" who ">") == 0 && n[key] < 6) { by[key] = by[key] "<" who "> "; n[key]++ }
		}
	}
	END {
		for (k in cnt) {
			split(k, f, "|")
			printf "%5d  %-22s %-70s %s\n", cnt[k], f[1], f[2], f[3]
			printf "       by: %s\n", by[k]
		}
		printf "%5d  AF_UNIX sockets (local, not network)\n", u + 0
		printf "%5d  AF_NETLINK (local kernel interface)\n", nl + 0
	}
' "$TRACE"
echo
echo "== host names the server asked the resolver for (query log of the resolver)"
sed -n '/harness-marker-start.invalid/,/harness-marker-end.invalid/p' "$DNSLOG" | grep -v 'harness-marker' | grep -E 'query\[' \
	| awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^query\[/) { print $i, $(i + 1) } }' | sort | uniq -c | sort -rn
echo "   (names ending in .vylaris.test are search-domain expansions of the names above them. The resolver sees the whole"
echo "    server, strace only the update's process tree: a name without a matching call above was asked by a service"
echo "    that the update restarted, e.g. php-fpm of the sury build asks telemetry.sury.org when it starts)"
echo
echo "== answers of the resolver ($([ "${NETMODE:-closed}" = closed ] && echo 'it knows only the repo host name; everything else is refused' || echo 'forwarding to public resolvers'))"
sed -n '/harness-marker-start.invalid/,/harness-marker-end.invalid/p' "$DNSLOG" | grep -v 'harness-marker' \
	| grep -E ' (reply|config|NXDOMAIN|REFUSED|SERVFAIL|forwarded)' | sed -E 's/^.*dnsmasq\[[0-9]+\]: //; s/^[0-9]+ [0-9.]+\/[0-9]+ //' | sort | uniq -c | sort -rn | head -12
echo
echo "== requests the repo container served during the update (method, path, status)"
awk '{ print $6, $7, $9 }' "$ACCESS" | tr -d '"' | sort | uniq -c
