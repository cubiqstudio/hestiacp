#!/usr/bin/env bash
# guest.sh - runs INSIDE the test container (started by run.sh). Plays the part of a fresh server:
# the installer src/vylaris/setup-repo-host.sh runs against mock-cloudflare.py, a stub systemctl and
# a stub cloudflared. Prints PASS/FAIL lines; exit status 0 only when nothing failed.
#
# PROFILE a: error cases (state directory, lost key/state, lock, checkout owner, API base, DNS/tunnel
#            ownership, rate limit, zone depth), full run, idempotency, nginx auth, signature,
#            CLIENT-INSTALL.txt, password printed once, secrets (log, process list, world-readable files),
#            client check with client-setup.sh, --status, --print-client-command, --uninstall-tunnel
# PROFILE b: --force-dns (in place, backup, A+AAAA), foreign nginx file, big nginx -T output, port conflict,
#            nginx rollback, --listen-port, --skip-tunnel-service, --public, --staging, several suites,
#            the build path with a stand-in build script, untracked files, DNS POST that answers 500
# PROFILE cfd: cloudflared from the real pkg.cloudflare.com (a fake one must be refused, a captive-portal page
#            at the first key address must not stop the fallback), real service unit
# PROFILE build: the real package build (src/hst_autocompile.sh) and publish
set -uo pipefail

PROFILE=${PROFILE:-a}
OUT=/result
DOMAIN=repo.vylaris.test
ZONE=vylaris.test
STATE=/root/vylarisspace-repo-host
REPO=/srv/vylarisspace-repo
SRC=/opt/src
SCRIPT=$SRC/src/vylaris/setup-repo-host.sh
GOOD=mock-valid-token-0123456789abcdef
WRONG=mock-WRONG-token-0123456789abcdef
LOGF=/var/log/vylarisspace-repo-host.log
PORT=8088
PASS=0
FAIL=0
RUN_N=0
LAST_RC=0

pass() {
	echo "PASS: $*"
	PASS=$((PASS + 1))
}
fail() {
	echo "FAIL: $*"
	FAIL=$((FAIL + 1))
}
banner() { printf '\n######## %s\n' "$*"; }
check() { # description command...
	local d=$1
	shift
	if "$@" > /dev/null 2>&1; then pass "$d"; else fail "$d"; fi
}
check_eq() { # description actual expected
	if [ "$2" = "$3" ]; then pass "$1 ($2)"; else fail "$1: got '$2', expected '$3'"; fi
}
last_out() { cat "$OUT/run-$(printf '%02d' "$RUN_N")-"*.out; }
out_has() { # description pattern
	if last_out | grep -qE -- "$2"; then pass "$1"; else fail "$1 (pattern '$2' not in the output of run $RUN_N)"; fi
}
out_has_lit() { # description literal string (see out_has_not_lit)
	if last_out | grep -qF -f <(printf '%s\n' "$2"); then pass "$1"; else fail "$1 (the text was not found in the output of run $RUN_N)"; fi
}
out_has_not() { # description pattern
	if last_out | grep -qE -- "$2"; then fail "$1 (pattern '$2' found in the output of run $RUN_N)"; else pass "$1"; fi
}
out_has_not_lit() { # description literal string (not a pattern; passed through a pipe, never in a command line: it may be the password)
	if last_out | grep -qF -f <(printf '%s\n' "$2"); then fail "$1 (the text was found in the output of run $RUN_N)"; else pass "$1"; fi
}
expect_rc() { # description rc
	check_eq "$1: exit code" "$LAST_RC" "$2"
}
show_tail() { last_out | tail -n "${1:-12}" | sed 's/^/    | /'; }

# mock helpers -----------------------------------------------------------------------------------
mock() { # METHOD PATH [JSON]
	python3 - "$@" << 'PY'
import sys, urllib.request
method, path = sys.argv[1], sys.argv[2]
data = sys.argv[3].encode() if len(sys.argv) > 3 else None
req = urllib.request.Request("http://127.0.0.1:8787" + path, data=data, method=method)
print(urllib.request.urlopen(req, timeout=10).read().decode())
PY
}
mq() { # python expression over d (the mock state)
	mock GET /_mock/state | python3 -c 'import sys,json; d=json.load(sys.stdin)["result"]; print(eval(sys.argv[1]))' "$1"
}
mock_reset() { mock POST /_mock/reset > /dev/null; }
mock_set() { mock POST /_mock/set "$1" > /dev/null; }
calls() { # regex -> number of calls so far matching
	mq "len([c for c in d['calls'] if __import__('re').search(r'''$1''', c)])"
}

# run the installer (label, args...). Token from $TOK (default: the valid one).
run_script() {
	local label=$1
	shift
	RUN_N=$((RUN_N + 1))
	CLOUDFLARE_API_TOKEN="${TOK-$GOOD}" VYLARIS_CF_API_BASE="${TEST_CF_BASE:-http://127.0.0.1:8787/client/v4}" \
		VYLARIS_CF_RETRY_DELAY=1 VYLARIS_TUNNEL_WAIT="${TUNNEL_WAIT:-30}" VYLARIS_VERIFY_WAIT="${VERIFY_WAIT:-30}" \
		bash "$SCRIPT" "$@" > "$OUT/run-$(printf '%02d' "$RUN_N")-$label.out" 2>&1
	LAST_RC=$?
	echo "---- run $RUN_N ($label): bash setup-repo-host.sh $* -> exit $LAST_RC"
}

# the tunnel and the DNS record of the installer, among the decoys the tests put into the mock
OT="[t for t in d['tunnels'] if t['name']=='vylarisspace-repo' and not t['deleted_at']]"
OD="[r for r in d['dns'] if r['name']=='$DOMAIN']"
out_of() { cat "$OUT/run-$(printf '%02d' "$1")-"*.out; } # the output of run number N
state_get() { sed -n "s/^$1=//p" "$STATE/state.env" | head -n1; }

fpr_of() { gpg --batch --show-keys --with-colons "$1" 2> /dev/null | awk -F: '$1=="pub"{p=1;next} p==1&&$1=="fpr"{print $10;exit}'; }
modeof() { stat -c '%a' "$1"; }

# ------------------------------------------------------------------------------------------------
# environment: test CA and host name, mock, stubs, checkout, debs
# ------------------------------------------------------------------------------------------------
setup_environment() {
	banner "setup ($IMAGE, profile $PROFILE)"
	echo "127.0.0.1 $DOMAIN" >> /etc/hosts
	mkdir -p /etc/ssl/testca
	openssl req -x509 -newkey rsa:2048 -nodes -days 5 -subj "/CN=VylarisSpace repo host test CA" \
		-keyout /etc/ssl/testca/ca.key -out /etc/ssl/testca/ca.crt 2> /dev/null
	openssl req -newkey rsa:2048 -nodes -subj "/CN=$DOMAIN" -keyout /etc/ssl/testca/server.key -out /etc/ssl/testca/server.csr 2> /dev/null
	printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' "$DOMAIN" > /etc/ssl/testca/ext.cnf
	openssl x509 -req -in /etc/ssl/testca/server.csr -CA /etc/ssl/testca/ca.crt -CAkey /etc/ssl/testca/ca.key \
		-CAcreateserial -days 5 -extfile /etc/ssl/testca/ext.cnf -out /etc/ssl/testca/server.crt 2> /dev/null
	cp /etc/ssl/testca/ca.crt /usr/local/share/ca-certificates/vylaris-test-ca.crt
	update-ca-certificates > /dev/null 2>&1

	python3 /test/mock-cloudflare.py --port 8787 --edge-https-port 443 --cert /etc/ssl/testca/server.crt \
		--key /etc/ssl/testca/server.key --zone "$ZONE" --log /var/log/mock.log \
		> /var/log/mock.stdout 2>&1 &
	for _ in $(seq 1 50); do
		mock GET /_mock/state > /dev/null 2>&1 && break
		sleep 0.2
	done
	check "mock Cloudflare API answers" mock GET /_mock/state

	# stub systemctl: there is no systemd in the container
	cat > /usr/local/bin/systemctl << 'STUB'
#!/bin/bash
# test stub: enough of systemctl for setup-repo-host.sh without systemd
args=()
for a in "$@"; do case "$a" in --*) ;; *) args+=("$a") ;; esac; done
cmd=${args[0]:-}
unit=${args[1]:-}
unit=${unit%.service}
pidf=/run/stub-unit-$unit.pid
echo "systemctl $*" >> /result/systemctl-calls.txt
stop_unit() {
	if [ "$unit" = nginx ]; then nginx -s quit 2> /dev/null || true; return 0; fi
	if [ -f "$pidf" ]; then kill "$(cat "$pidf")" 2> /dev/null || true; rm -f "$pidf"; fi
}
start_unit() {
	local f=/etc/systemd/system/$unit.service envf exe
	if [ "$unit" = nginx ]; then pgrep -x nginx > /dev/null || nginx; return 0; fi
	[ -f "$f" ] || return 5
	envf=$(sed -n 's/^EnvironmentFile=//p' "$f")
	exe=$(sed -n 's/^ExecStart=//p' "$f")
	stop_unit
	(
		set -a
		[ -z "$envf" ] || . "$envf"
		set +a
		# shellcheck disable=SC2086
		setsid nohup $exe > /dev/null 2>&1 &
		echo $! > "$pidf"
	)
}
case "$cmd" in
	daemon-reload) ;;
	enable | start) start_unit ;;
	restart) stop_unit; start_unit ;;
	disable | stop) stop_unit ;;
	reload) [ "$unit" = nginx ] && nginx -s reload ;;
	is-active)
		if [ "$unit" = nginx ]; then pgrep -x nginx > /dev/null; else [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2> /dev/null; fi
		;;
	is-enabled) [ -f "/etc/systemd/system/$unit.service" ] && echo enabled ;;
	*) echo "stub systemctl: unsupported: $*" >&2; exit 1 ;;
esac
STUB
	chmod +x /usr/local/bin/systemctl

	# stub df: reports 1 MB free for /var/tmp while /tmp/fake-low-disk exists (the build-disk check of step 1)
	local realdf
	realdf=$(command -v df)
	cat > /usr/local/bin/df << STUB
#!/bin/bash
if [ -e /tmp/fake-low-disk ]; then
	case "\$*" in
		*/var/tmp*)
			printf 'Filesystem 1048576-blocks Used Available Capacity Mounted on\nfake 100 99 1 99%% /var/tmp\n'
			exit 0
			;;
	esac
fi
exec $realdf "\$@"
STUB
	chmod 755 /usr/local/bin/df

	# stub cloudflared as a .deb (this is also the --cloudflared-deb test): records its arguments, tells the
	# mock that the tunnel of $TUNNEL_TOKEN is connected, then sleeps like the real one
	local d=/tmp/cfd-stub
	mkdir -p "$d/DEBIAN" "$d/usr/bin"
	cat > "$d/usr/bin/cloudflared" << 'STUB'
#!/bin/bash
echo "$*" >> /result/cloudflared-argv.txt
case "${1:-}" in --version | version) echo "cloudflared version 2099.1.0 (test stub)"; exit 0 ;; esac
if [ -n "${TUNNEL_TOKEN:-}" ] && [ ! -e /tmp/no-connect ]; then
	python3 - << 'PY'
import base64, json, os, urllib.request
t = json.loads(base64.b64decode(os.environ["TUNNEL_TOKEN"]))["t"]
urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8787/_mock/connect", data=json.dumps({"tunnel_id": t}).encode(), method="POST"), timeout=10)
PY
fi
exec sleep 100000
STUB
	chmod 755 "$d/usr/bin/cloudflared"
	printf 'Package: cloudflared\nVersion: 2099.1.0\nArchitecture: all\nMaintainer: test <test@example.invalid>\nDescription: test stub of cloudflared\n' > "$d/DEBIAN/control"
	dpkg-deb --root-owner-group -b "$d" /tmp/cloudflared-stub.deb > /dev/null

	# the checkout under test: its own git repository, committed (the source archive is made from it)
	mkdir -p "$SRC"
	tar -xf "$OUT/src.tar" -C "$SRC"
	(cd "$SRC" && git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm "test checkout")
	check "the checkout copy is a clean git repository" test -z "$(git -C "$SRC" status --porcelain)"

	# debs of the harness, retagged for this system (+debianNN / +ubuntuNN.NN)
	local suffix
	suffix=$(. /etc/os-release && echo "$ID$VERSION_ID")
	DEB_A=/debs/hestia_1.10.5-100+ubuntu24.04_amd64.deb
	DEB_B=/debs/hestia_1.10.5-101+ubuntu24.04_amd64.deb
	if [ "$suffix" != ubuntu24.04 ]; then
		bash "$SRC/test/vylaris-upgrade/repack-deb.sh" own "$DEB_A" "/tmp/hestia_1.10.5-100+${suffix}_amd64.deb" "1.10.5-100+$suffix" > /dev/null
		bash "$SRC/test/vylaris-upgrade/repack-deb.sh" own "$DEB_B" "/tmp/hestia_1.10.5-101+${suffix}_amd64.deb" "1.10.5-101+$suffix" > /dev/null
		DEB_A="/tmp/hestia_1.10.5-100+${suffix}_amd64.deb"
		DEB_B="/tmp/hestia_1.10.5-101+${suffix}_amd64.deb"
	fi
	VER_A=$(dpkg-deb -f "$DEB_A" Version)
	VER_B=$(dpkg-deb -f "$DEB_B" Version)
	CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
	echo "debs: $VER_A and $VER_B, this system: $suffix ($CODENAME)"

	# best-effort process list: every command line seen during the whole test (unique lines)
	(
		while :; do
			for f in /proc/[0-9]*/cmdline; do
				tr '\0' ' ' 2> /dev/null < "$f"
				echo
			done
			sleep 0.05
		done | awk '!s[$0]++' > /result/ps-samples.txt
	) &
	SAMPLER=$!

	# leak watcher: the Cloudflare answer that carries the tunnel run token (cf.out in the installer's private
	# temp directory) must not stay on disk once it has been read; two sightings 0.4 s apart count as a leak.
	# It also records that the temp directory is on /run.
	(
		prev=''
		while :; do
			cur=''
			for f in /run/vylarisspace-repo-host.*/cf.out; do
				[ -f "$f" ] || continue
				echo "$f" >> /result/tmp-dirs-seen.txt
				if grep -q '"result": *"eyJ' "$f" 2> /dev/null; then cur=$f; fi
			done
			if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then echo "LEAK $cur" >> /result/token-leak.txt; fi
			prev=$cur
			sleep 0.4
		done
	) &
	WATCHER=$!
}

# checks that hold for the whole run of a profile
final_checks() {
	banner "checks over the whole run"
	check "no token answer stayed on disk (cf.out is wiped right after the tunnel token is read)" test ! -e "$OUT/token-leak.txt"
	check "the installer's temp directory was on /run" test -s "$OUT/tmp-dirs-seen.txt"
	check "no temp directory of the installer is left behind" bash -c "! ls -d /run/vylarisspace-repo-host.* 2>/dev/null | grep -v '[.]lock\$' | grep -q ."
	check "no .keygen temp directory is left in the state directory" bash -c "! ls -d $STATE/.keygen* 2>/dev/null | grep -q ."
	check "the log names the temp directory under /run" grep -q 'temporary files: /run/vylarisspace-repo-host\.' "$LOGF"
	check "static: no 'cmd | grep -q' pipeline in the installer (pipefail turns SIGPIPE into a false negative)" bash -c "! grep -nE '\| *grep +-[a-zA-Z]*q' $SCRIPT"
	check "static: git is never told safe.directory='*'" bash -c "! grep -n \"safe.directory\" $SCRIPT | grep -q \"'\\*'\""
	check "static: the test runner does not delete with a glob in the result directory" bash -c "! grep -nE 'rm -f .*result.*/\*' /test/run.sh"
}

# ------------------------------------------------------------------------------------------------
# secrets: nothing secret in the log, the process list, or any world-readable file
# ------------------------------------------------------------------------------------------------
scan_secrets() {
	banner "secrets: log, process list, world-readable files"
	local pw pass tun pats="$OUT/secret-patterns.txt" hits
	pw=''
	if [ -s "$STATE/repo-auth" ]; then
		pw=$(head -n1 "$STATE/repo-auth")
		pw=${pw#*:}
	fi
	pass=$(head -n1 "$STATE/key.pass")
	tun=$(sed -n 's/^TUNNEL_TOKEN=//p' /etc/vylarisspace-repo-host/tunnel.env 2> /dev/null | head -n1)
	[ -n "$tun" ] || tun=$(sed -n 's/^TUNNEL_TOKEN=//p' "$OUT/tunnel.env.copy" 2> /dev/null | head -n1)
	[ -n "$pass" ] && [ -n "$tun" ] || fail "could not read the secrets to look for (pass=${#pass} tunnel=${#tun} characters)"
	printf '%s\n%s\n%s\n%s\n' "$GOOD" "$WRONG" "$pass" "$tun" > "$pats"
	[ -z "$pw" ] || printf '%s\n' "$pw" >> "$pats"
	echo "  looking for $(wc -l < "$pats") secrets: CF token, a wrong token, key passphrase, tunnel token${pw:+, repo password}"
	for f in "$LOGF" "$LOGF.build" /var/log/nginx/*.log; do
		[ -f "$f" ] || continue
		if grep -qF -f "$pats" "$f"; then fail "a secret is in $f"; else pass "no secret in $f ($(wc -l < "$f") lines)"; fi
	done
	if grep -qF -f "$pats" "$OUT/ps-samples.txt"; then
		fail "a secret appeared in a command line (process list samples)"
		grep -F -f "$pats" "$OUT/ps-samples.txt" | sed 's/\(.\{60\}\).*/\1.../' | head -3
	else
		pass "no secret in any command line seen during the run ($(wc -l < "$OUT/ps-samples.txt") distinct command lines sampled)"
	fi
	grep -c 'cloudflared\|setup-repo-host\|curl' "$OUT/ps-samples.txt" | sed 's/^/  command lines sampled that mention cloudflared, the script or curl: /'
	# terminal output of all runs: the CF tokens and the tunnel token must not be there; the repo
	# password is shown once on purpose (final summary), the passphrase never
	if cat "$OUT"/run-*.out | grep -qF -e "$GOOD" -e "$WRONG" -e "$tun" -e "$pass"; then
		fail "CF token, tunnel token or key passphrase in the terminal output"
	else
		pass "CF tokens, tunnel token and key passphrase are not in the terminal output of any run"
	fi
	hits=$(find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /result -o -path /opt/src -o -path /usr/lib -o -path /usr/share \
		-o -path /var/lib/dpkg -o -path /var/lib/apt -o -path /var/cache -o -path /tmp/cfd-stub \) -prune \
		-o -type f -perm -004 -print0 2> /dev/null | xargs -0 grep -lF -f "$pats" 2> /dev/null | grep -v '^/tmp/cloudflared-stub.deb$' || true)
	if [ -z "$hits" ]; then
		pass "no world-readable file anywhere on / contains one of the secrets"
	else
		fail "world-readable files with a secret: $hits"
	fi
	hits=$(find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /result -o -path /opt/src -o -path /usr/lib -o -path /usr/share \
		-o -path /var/lib/dpkg -o -path /var/lib/apt -o -path /var/cache \) -prune \
		-o -type f -print0 2> /dev/null | xargs -0 grep -lF -f "$pats" 2> /dev/null | sort | tr '\n' ' ' || true)
	echo "  all files that contain a secret (any mode): $hits"
	for f in $hits; do
		case "$f" in
			/root/vylarisspace-repo-host/repo-auth | /root/vylarisspace-repo-host/key.pass | /root/vylarisspace-repo-host/CLIENT-INSTALL.txt | /etc/vylarisspace-repo-host/tunnel.env)
				check_eq "  $f has mode" "$(modeof "$f")" 600
				;;
			/tmp/*) ;;
			*) fail "unexpected file with a secret: $f ($(modeof "$f"))" ;;
		esac
	done
}

# ================================================================================================
# profile a
# ================================================================================================
profile_a() {
	banner "A0 API base, state directory and lock checks (before anything is created)"
	ln -s /usr/bin/cloudflared /usr/local/bin/cloudflared # the unit must name the real file, not this link
	mock_reset
	for base in http://evil.example.com/client/v4 'http://127.0.0.1:8787@evil.example.com/client/v4' http://127.0.0.1.evil.example.com/client/v4 ftp://127.0.0.1/x; do
		TEST_CF_BASE=$base run_script api-base --domain "$DOMAIN"
		expect_rc "VYLARIS_CF_API_BASE=$base is refused" 1
		out_has "API base: message" 'VYLARIS_CF_API_BASE must start with https://'
	done
	check_eq "the token never reached any server (no API call at all)" "$(calls '.')" 0
	run_script state-relative --domain "$DOMAIN" --state-dir relative/state
	expect_rc "relative --state-dir" 1
	run_script state-etc --domain "$DOMAIN" --state-dir /etc
	expect_rc "--state-dir /etc (system directory)" 2
	out_has "system directory: message" 'system directory'
	run_script state-dotdot --domain "$DOMAIN" --state-dir /root/a/../b
	expect_rc "--state-dir with .." 1
	run_script state-tmp --domain "$DOMAIN" --state-dir /tmp/state
	expect_rc "--state-dir in /tmp" 1
	run_script repo-system --domain "$DOMAIN" --repo-dir /usr
	expect_rc "--repo-dir /usr (system directory)" 2
	check "nothing was created by these refusals (no state pointer, no state directory)" bash -c "test ! -e /etc/vylarisspace-repo-host && test ! -e $STATE"
	mkdir -p /root/foreign-state
	echo precious > /root/foreign-state/data.txt
	chmod 755 /root/foreign-state
	run_script state-foreign --domain "$DOMAIN" --state-dir /root/foreign-state
	expect_rc "--state-dir that exists, is not empty and is not ours" 2
	out_has "foreign state directory: message" 'was not created by this script'
	check_eq "the foreign directory keeps its mode (never chmod a directory we did not create)" "$(modeof /root/foreign-state)" 755
	check "the foreign directory is untouched (no marker, file intact)" bash -c "ls -A /root/foreign-state | tr '\n' ' ' | grep -qx 'data.txt '"
	mkdir -p /root/empty-state
	chmod 755 /root/empty-state
	run_script state-empty-open --domain "$DOMAIN" --state-dir /root/empty-state
	expect_rc "--state-dir that exists, is empty but readable by others" 2
	out_has "open empty directory: message" 'is not private'
	check_eq "and its mode is unchanged" "$(modeof /root/empty-state)" 755
	check "no state pointer was written by the refusals" test ! -e /etc/vylarisspace-repo-host/state-dir
	rmdir /root/empty-state
	rm -rf /root/foreign-state

	run_script delete-dns-install --domain "$DOMAIN" --delete-dns
	expect_rc "--delete-dns without --uninstall-tunnel is a usage error" 1
	out_has "--delete-dns alone: message" '--delete-dns only works together with --uninstall-tunnel'
	check_eq "--delete-dns alone: no API call, nothing created" "$(calls '.')" 0
	flock -n /run/vylarisspace-repo-host.lock sleep 61 &
	sleep 1
	run_script locked --domain "$DOMAIN"
	expect_rc "a second run while another one holds the lock (/run/vylarisspace-repo-host.lock)" 2
	out_has "lock: message names the file in /run" 'another run of this script is active \(lock /run/vylarisspace-repo-host\.lock\)'
	pkill -f 'sleep 61'
	sleep 0.5
	rm -f /run/vylarisspace-repo-host.lock
	mkdir /run/vylarisspace-repo-host.lock
	run_script lock-unopenable --domain "$DOMAIN"
	expect_rc "the lock file cannot be opened (a directory is in the way)" 3
	out_has "lock: clear message" 'cannot open the lock file /run/vylarisspace-repo-host\.lock'
	rmdir /run/vylarisspace-repo-host.lock

	banner "A1 error cases (each must stop with a clear message and leave nothing half done)"
	nogood() { # no state, no keys, no nginx site, no repo, no tunnel/dns in the mock
		check "$1: no signing key was created" test ! -e "$STATE/keys"
		check "$1: no repository was created" test ! -e "$REPO"
		check "$1: no nginx site was written" test ! -e /etc/nginx/conf.d/vylarisspace-repo.conf
		check "$1: state has no domain" test -z "$(sed -n 's/^DOMAIN=//p' "$STATE/state.env" 2> /dev/null)"
	}
	mock_reset
	# a policy-rc.d that an interrupted run left behind (our marker): removed at the start of the next run
	printf '#!/bin/sh\n# vylarisspace-repo-host: temporary file of setup-repo-host.sh, removed again by it\nexit 101\n' > /usr/sbin/policy-rc.d
	chmod 755 /usr/sbin/policy-rc.d
	TOK=$WRONG run_script wrong-token --domain "$DOMAIN"
	expect_rc "wrong token" 4
	out_has "wrong token: one combined hint" 'Cloudflare refused the API token'
	out_has "wrong token: lists the possible reasons" 'wrong, expired or revoked; it is restricted to other IP addresses; or it lacks a permission'
	out_has "wrong token: shows the Cloudflare code" '\[9109\]'
	nogood "wrong token"
	check "the stale policy-rc.d of an interrupted run was removed (and no policy-rc.d is left over)" test ! -e /usr/sbin/policy-rc.d
	check "the state directory was created with the marker, mode 700" bash -c "test -f $STATE/.vylarisspace-repo-host-state && test \"\$(stat -c %a $STATE)\" = 700"
	check "but it is NOT recorded yet (no key exists in it): no state pointer, no /etc/vylarisspace-repo-host" bash -c "test ! -e /etc/vylarisspace-repo-host"
	out_has "exit 4: says that the same command resumes" 'The run stopped early\. Nothing is lost: run the same command again, it resumes\.'
	TOK=$WRONG run_script wrong-token-otherdir --domain "$DOMAIN" --state-dir /root/other-state1
	expect_rc "a failed first run does not pin its state directory: another --state-dir is not refused" 4
	check "still no state pointer" test ! -e /etc/vylarisspace-repo-host/state-dir
	rm -rf /root/other-state1
	show_tail 6

	mock_set '{"perms":["zone","dns"]}'
	run_script no-tunnel-permission --domain "$DOMAIN"
	expect_rc "missing Tunnel permission" 4
	out_has "missing permission: the same combined hint" 'Cloudflare refused the API token'
	out_has "missing permission: names the permissions and the API names" 'Cloudflare Tunnel > Edit .*Cloudflare Tunnel Write.*Cloudflare One Connectors Write.*Zone > DNS > Edit .*DNS Write.*Zone Read'
	out_has "missing permission: names the resources" 'the account that owns the zone and the zone of the domain \(or all zones\)'
	nogood "missing Tunnel permission"
	mock_set '{"perms":["tunnel","zone"]}'
	run_script no-dns-permission --domain "$DOMAIN"
	expect_rc "missing DNS permission" 4
	out_has "missing DNS permission: message" 'reading the DNS records'
	nogood "missing DNS permission"
	mock_set '{"perms":["tunnel","dns"]}'
	run_script no-zone-permission --domain "$DOMAIN"
	expect_rc "missing Zone Read permission" 4
	nogood "missing Zone permission"
	show_tail 4

	mock_reset
	mock_set '{"perms":["tunnel_read","dns","zone"]}'
	run_script tunnel-read-only --domain "$DOMAIN"
	expect_rc "a token that may only READ tunnels passes the read checks, but the tunnel POST answers 403" 4
	out_has "preflight says read access only" 'read access works .*write permissions .* are checked when they are used'
	out_has_not "the old claim that the permissions are present is gone" 'tunnel, DNS and zone permissions are present'
	out_has "the failure names what was being done" 'creating the tunnel vylarisspace-repo failed'
	out_has "and the permission hint says that Read is not enough" 'Read permissions are not enough'
	out_has "exit 4: says that the same command resumes" 'The run stopped early'
	check_eq "the tunnel POST was tried once (a 403 is not retried)" "$(calls '^POST .*/cfd_tunnel$')" 1
	check_eq "no tunnel exists at Cloudflare" "$(mq "len(d['tunnels'])")" 0
	check_eq "no DNS call that changes something" "$(calls '^(POST|PUT|PATCH|DELETE) .*dns_records')" 0
	nogood "read-only tunnel permission (it failed in step 1: before key, repository, nginx)"
	check "the state does not pin the domain" test -z "$(sed -n 's/^DOMAIN=//p' "$STATE/state.env" 2> /dev/null)"

	mock_reset
	touch /tmp/fake-low-disk
	run_script low-disk --domain "$DOMAIN"
	rm -f /tmp/fake-low-disk
	expect_rc "no package given, none published: the build needs 3000 MB in /var/tmp, 1 MB free" 3
	out_has "disk: message in step 1" 'not enough free disk space to build the panel package'
	out_has "exit 3: says that the same command resumes" 'The run stopped early'
	check_eq "nothing was written at Cloudflare (the check comes before the tunnel)" "$(calls '^(POST|PUT|PATCH|DELETE) ')" 0
	nogood "build disk space"

	echo "stray file" > "$SRC/stray-file.txt"
	run_script dirty-fresh --domain "$DOMAIN"
	expect_rc "a dirty checkout and a build is needed: refused in step 1" 2
	out_has "dirty: message" 'uncommitted changes or untracked files'
	out_has "dirty: says what to do (not git add -A)" 'Commit your changes \(git add <files>; git commit\) or move stray files out of the checkout'
	out_has_not "dirty: no git add -A" 'git add -A'
	out_has_not "exit 2: no extra 'stopped early' line (the error says what to fix)" 'The run stopped early'
	check_eq "nothing was written at Cloudflare" "$(calls '^(POST|PUT|PATCH|DELETE) ')" 0
	nogood "dirty checkout"
	run_script dirty-fresh-deb --domain "$DOMAIN" --deb "$DEB_A"
	expect_rc "a dirty checkout with --deb (the source archive is made from it): refused in step 1 as well" 2
	check_eq "nothing was written at Cloudflare (--deb)" "$(calls '^(POST|PUT|PATCH|DELETE) ')" 0
	nogood "dirty checkout with --deb"
	rm -f "$SRC/stray-file.txt"

	mock_reset
	mkdir -p "$REPO/stray"
	echo precious > "$REPO/stray/file"
	run_script repo-dir-foreign --domain "$DOMAIN" --deb "$DEB_A"
	expect_rc "the repository directory exists, is not empty and is not ours: refused in step 1" 2
	out_has "foreign repo dir: message" 'is not a repository of this tool'
	check_eq "nothing was written at Cloudflare" "$(calls '^(POST|PUT|PATCH|DELETE) ')" 0
	check "the directory is untouched" test "$(cat "$REPO/stray/file")" = precious
	rm -rf "$REPO"

	mock_reset
	mock_set '{"zones":[{"name":"other.test"}]}'
	run_script zone-missing --domain "$DOMAIN"
	expect_rc "domain not in the account" 4
	out_has "zone not found: plain message" 'is not in this Cloudflare account'
	nogood "zone not found"
	show_tail 4

	mock_reset
	mock_set "{\"dns\":[{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"203.0.113.9\",\"proxied\":true}]}"
	run_script foreign-dns --domain "$DOMAIN"
	expect_rc "existing A record" 2
	out_has "foreign DNS record: names the record and --force-dns" 'A 203.0.113.9.*|--force-dns'
	out_has_not "exit 2: no extra 'stopped early' line" 'The run stopped early'
	check_eq "foreign DNS record is untouched" "$(mq "[(r['type'], r['content']) for r in d['dns']]")" "[('A', '203.0.113.9')]"
	nogood "foreign DNS record"
	show_tail 5

	mock_reset
	mock_set "{\"dns\":[{\"type\":\"CNAME\",\"name\":\"$DOMAIN\",\"content\":\"11111111-2222-3333-4444-555555555555.cfargotunnel.com\",\"proxied\":true}]}"
	run_script other-tunnel-cname --domain "$DOMAIN"
	expect_rc "a CNAME to ANOTHER tunnel (*.cfargotunnel.com) is not ours" 2
	out_has "other tunnel CNAME: prints the old content and names --force-dns" 'CNAME 11111111-2222-3333-4444-555555555555\.cfargotunnel\.com;.*|--force-dns'
	check_eq "the CNAME to the other tunnel is untouched" "$(mq "[(r['type'], r['content']) for r in d['dns']]")" "[('CNAME', '11111111-2222-3333-4444-555555555555.cfargotunnel.com')]"
	check_eq "no PATCH, POST or DELETE went to the DNS API" "$(calls '^(PATCH|POST|DELETE) .*dns_records')" 0
	nogood "CNAME to another tunnel"

	mock_reset
	mock_set "{\"tunnels\":[{\"name\":\"vylarisspace-repo\",\"ingress\":[{\"hostname\":\"other.$ZONE\",\"service\":\"http://127.0.0.1:9\"},{\"service\":\"http_status:404\"}]}]}"
	run_script foreign-tunnel --domain "$DOMAIN"
	expect_rc "existing tunnel of the same name serving another host" 2
	out_has "foreign tunnel: message" 'has a configuration .*host names: other\.'
	check_eq "the existing tunnel's ingress is untouched" "$(mq "d['tunnels'][0]['ingress'][0]['hostname']")" "other.$ZONE"
	nogood "foreign tunnel"
	mock_reset
	mock_set '{"tunnels":[{"name":"vylarisspace-repo","ingress":[{"service":"http_status:404"}]}]}'
	run_script catchall-tunnel --domain "$DOMAIN"
	expect_rc "existing tunnel of the same name with only a catch-all rule is not taken over" 2
	out_has "catch-all tunnel: message" 'has a configuration'
	mock_reset
	mock_set '{"tunnels":[{"name":"vylarisspace-repo","config":{"warp-routing":{"enabled":true}}}]}'
	run_script warp-tunnel --domain "$DOMAIN"
	expect_rc "existing tunnel of the same name with warp routing is not taken over" 2
	out_has "warp tunnel: message names the setting" 'has a configuration \(warp-routing'
	check_eq "nothing was created in the mock (no PUT, POST)" "$(calls '^(PUT|POST|DELETE) ')" 0
	nogood "tunnel with a configuration"
	mock_reset
	mock_set '{"tunnels":[{"name":"vylarisspace-repo","config_src":"local"}]}'
	run_script local-tunnel --domain "$DOMAIN"
	expect_rc "existing tunnel with a local config file" 2
	out_has "local-config tunnel: message" 'configured by a local file'

	banner "A1b domain too deep for the free certificate, rate limit longer than 60 s"
	mock_reset
	run_script deep-host --domain "repo.srv.$ZONE"
	expect_rc "a domain two labels below the zone" 2
	out_has "deep host: message" 'more than one label below the zone vylaris.test'
	nogood "deep host"
	mock_set "{\"dns\":[{\"type\":\"A\",\"name\":\"repo.srv.$ZONE\",\"content\":\"203.0.113.5\"}]}"
	run_script deep-host-allowed --domain "repo.srv.$ZONE" --allow-deep-host
	expect_rc "--allow-deep-host passes the depth check (and stops at the foreign DNS record instead)" 2
	out_has "--allow-deep-host: still a warning about the certificate" 'does not cover it'
	out_has "--allow-deep-host: the run went on to the DNS check" 'already has a DNS record'
	nogood "deep host allowed"
	mock_reset
	mock_set '{"fail":[{"method":"GET","contains":"/zones?name","status":429,"times":10,"retry_after":120}]}'
	run_script rate-limit-long --domain "$DOMAIN"
	expect_rc "Retry-After of 120 s is longer than the 60 s the script waits" 4
	out_has "rate limit: clear message" 'asks to wait 120 seconds \(Retry-After\).*more than the 60 seconds'
	check_eq "it did not wait and retry (one call only)" "$(calls '^GET .*zones\?name')" 1
	nogood "long rate limit"

	banner "A2 domain syntax, missing token (no terminal)"
	run_script bad-domain --domain 'not a domain'
	expect_rc "invalid domain" 1
	out_has_not "exit 1: no extra 'stopped early' line" 'The run stopped early'
	TOK='' run_script no-token --domain "$DOMAIN" < /dev/null
	expect_rc "no token and no terminal" 1
	out_has "no token: message" 'token is missing'

	banner "A3 full run (decoys in the mock; an interrupted first run; API errors 500/503/429 once)"
	mock_reset
	# The mock ignores the name filters for this test: a decoy tunnel (listed FIRST) and a decoy DNS record
	# are returned to every list call. Only the exact-name guards of the installer keep it from using them.
	mock_set '{"tunnel_list_ignores_name":true,"dns_ignore_filter":true,"tunnels":[{"name":"other-tunnel","ingress":[{"hostname":"x.vylaris.test","service":"http://127.0.0.1:9"},{"service":"http_status:404"}]},{"name":"vylarisspace-repo","config_src":"cloudflare"}],"dns":[{"type":"A","name":"other.vylaris.test","content":"203.0.113.77","proxied":true}]}'
	mock_set '{"fail":[{"method":"PUT","contains":"configurations","status":400,"times":1}]}'
	run_script main-interrupted --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "first run, interrupted at the tunnel route (HTTP 400)" 4
	out_has "interrupted run: message" 'setting the tunnel route failed'
	out_has "existing empty tunnel was taken over (it is empty; the decoy tunnel was not used)" 'taken over'
	check_eq "state: the adopted tunnel is NOT marked as created by us" "$(state_get TUNNEL_CREATED)" no
	check_eq "state: the login was generated but not shown yet" "$(state_get LOGIN_SHOWN)" no
	local pw user
	user=$(head -n1 "$STATE/repo-auth")
	pw=${user#*:}
	user=${user%%:*}
	# (the test's own curl must not put the password on a command line either: the process sampler would catch it)
	maskpw() { PWMASK=$pw awk '{ n = length(ENVIRON["PWMASK"]); i = index($0, ENVIRON["PWMASK"]); while (i > 0) { $0 = substr($0, 1, i - 1) "<PASSWORD>" substr($0, i + n); i = index($0, ENVIRON["PWMASK"]) } print }'; }
	acurl() { printf 'user = "%s:%s"\n' "$user" "$pw" | curl -K - "$@"; }
	out_has_not_lit "the interrupted run did not print the password" "$pw"
	check_eq "the decoy tunnel is untouched" "$(mq "[(t['name'], t['ingress'][0]['hostname']) for t in d['tunnels'] if t['name']=='other-tunnel']")" "[('other-tunnel', 'x.vylaris.test')]"
	mock_set '{"fail":[{"method":"PUT","contains":"configurations","status":500,"times":1},{"method":"GET","contains":"/zones?name","status":429,"times":1,"retry_after":"0000000002"},{"method":"GET","contains":"/zones?name","status":503,"times":1}]}'
	local t0
	t0=$(date +%s)
	run_script main --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	echo "  (run time $(($(date +%s) - t0)) s)"
	expect_rc "main run (resumes after the interrupted one)" 0
	last_out | grep -E '^(==|  \[|ERROR|  IMPORTANT|=====|URL)' | sed 's/^/    | /' | head -80
	out_has "retry after a server error is shown to the owner" 'trying again in'
	out_has "Retry-After of a 429 is honoured, also written with leading zeros (0000000002 = 2 s, not 'more than 3 digits')" 'rate limit \(HTTP 429\), waiting 2 s as Cloudflare asks'
	grep -E 'attempt [12] failed \(HTTP (500|503|429)\)' "$LOGF" | sed 's/^/    log: /'
	check "the log shows the retries (HTTP 500, 503 and 429)" bash -c "grep -q 'attempt 1 failed (HTTP 500)' $LOGF && grep -q 'attempt 2 failed (HTTP 503)' $LOGF && grep -q 'attempt 1 failed (HTTP 429)' $LOGF"
	check_eq "still exactly one tunnel of this name" "$(mq "len($OT)")" 1
	TUNNEL_ID=$(mq "${OT}[0]['id']")
	check_eq "the tunnel that was taken over is the empty one" "$(mq "${OT}[0]['name']")" vylarisspace-repo
	check_eq "DNS: one record, CNAME to the tunnel, proxied" "$(mq "[(r['type'], r['content'], r['proxied']) for r in $OD]")" "[('CNAME', '$TUNNEL_ID.cfargotunnel.com', True)]"
	check_eq "the decoy DNS record of another name is untouched" "$(mq "[(r['type'], r['content']) for r in d['dns'] if r['name']=='other.vylaris.test']")" "[('A', '203.0.113.77')]"
	check_eq "tunnel route" "$(mq "[(i.get('hostname'), i['service']) for i in ${OT}[0]['ingress']]")" "[('$DOMAIN', 'http://127.0.0.1:$PORT'), (None, 'http_status:404')]"
	check_eq "tunnel is healthy at the (mock) Cloudflare side" "$(mq "${OT}[0]['status']")" healthy
	check_eq "the mock reports no connections (deprecated field): the script decides on the status" "$(mq "${OT}[0]['connections']")" "[]"
	out_has "tunnel healthy message" 'tunnel is healthy'
	out_has_not "no connection count is printed (the field is empty)" 'connection\(s\)'
	check "the DNS list is asked with name.exact and per_page=100" test "$(calls 'dns_records\?name\.exact=repo\.vylaris\.test&per_page=100')" -gt 0
	check_eq "no DNS list with the bare name= filter" "$(calls 'dns_records\?name=')" 0
	check "state: TUNNEL_CREATED=no is kept for the adopted tunnel" test "$(state_get TUNNEL_CREATED)" = no
	check_eq "state: the login is marked as shown" "$(state_get LOGIN_SHOWN)" yes
	out_has_lit "the summary of the first completed run prints the password once" "$pw"
	out_has "and says that it is printed only once" 'printed only this once'
	out_has_not "no ps-visible option form of the login in the output" 'vylaris-repo-auth'
	FPR=$(fpr_of "$STATE/keys/out/pubkey.asc")
	check_eq "key fingerprint is a 40 digit hex string" "$(echo "$FPR" | grep -cE '^[0-9A-F]{40}$')" 1
	echo "  fingerprint: $FPR"
	check "the run lock is free after the run (no daemon started by the script kept it)" flock -n /run/vylarisspace-repo-host.lock true
	check "the lock file is /run/vylarisspace-repo-host.lock (a directory only root can write to), not /run/lock" bash -c "test -f /run/vylarisspace-repo-host.lock && test ! -e /run/lock/vylarisspace-repo-host.lock"
	check "no process holds the lock file open any more (fd 9 was closed for gpg, gpg-agent, reprepro, repo-publish.sh)" bash -c "! ls -l /proc/[0-9]*/fd/ 2>/dev/null | grep -q 'vylarisspace-repo-host.lock'"
	check "static: every external command that may start a daemon has fd 9 closed (gpg --list-secret-keys, repo-publish.sh, the build)" bash -c "grep -n 'list-secret-keys' $SCRIPT | grep -qv '9>&-' && exit 1; grep -n 'repo-publish.sh\"' $SCRIPT | grep -v '^.*#' | grep -qv '9>&-' && exit 1; grep -n 'LOG_FILE.build\" 2>&1' $SCRIPT | grep -qv '9>&-' && exit 1; exit 0"

	banner "A4 files, modes, nginx"
	check_eq "state dir mode" "$(modeof "$STATE")" 700
	check_eq "repo-auth mode" "$(modeof "$STATE/repo-auth")" 600
	check_eq "key.pass mode" "$(modeof "$STATE/key.pass")" 600
	check_eq "CLIENT-INSTALL.txt mode" "$(modeof "$STATE/CLIENT-INSTALL.txt")" 600
	check_eq "state.env mode" "$(modeof "$STATE/state.env")" 600
	check_eq "tunnel.env mode" "$(modeof /etc/vylarisspace-repo-host/tunnel.env)" 600
	check_eq "log file mode" "$(modeof "$LOGF")" 600
	check_eq "state pointer mode" "$(modeof /etc/vylarisspace-repo-host/state-dir)" 600
	check_eq "state pointer content" "$(cat /etc/vylarisspace-repo-host/state-dir)" "$STATE"
	check "no .bak of the nginx site (it was written once, and a file of this script is never worth a copy)" test ! -e /etc/nginx/vylarisspace-repo.conf.bak
	check_eq "htpasswd mode, owner" "$(stat -c '%a %U:%G' /etc/nginx/vylarisspace-repo.htpasswd)" "640 root:www-data"
	check "the passphrase has 64 hex characters" test "$(head -n1 "$STATE/key.pass" | grep -cE '^[0-9a-f]{64}$')" = 1
	check "keys/out has the primary secret key export (passphrase protected, mode 600)" test "$(modeof "$STATE"/keys/out/secret-primary-and-subkey-OFFLINE-BACKUP-*.asc)" = 600
	check "the signing home holds only a stub of the primary key" bash -c "GNUPGHOME=$STATE/keys/gnupg-signing gpg --list-secret-keys 2>/dev/null | grep -q '^sec#'"
	cp /etc/vylarisspace-repo-host/tunnel.env "$OUT/tunnel.env.copy"
	chmod 600 "$OUT/tunnel.env.copy"
	check "nginx listens on 127.0.0.1:$PORT only" bash -c "ss -Hltn | awk '{print \$4}' | grep -qx '127.0.0.1:$PORT' && ! ss -Hltn | awk '{print \$4}' | grep -qE '^(0.0.0.0|\\*|\\[::\\]):$PORT\$'"
	local base=http://127.0.0.1:$PORT
	check_eq "InRelease without login" "$(curl -s -o /dev/null -w '%{http_code}' $base/dists/$CODENAME/InRelease)" 401
	check_eq "InRelease with a wrong password" "$(curl -s -o /dev/null -w '%{http_code}' -u "$user:wrong" $base/dists/$CODENAME/InRelease)" 401
	check_eq "InRelease with the login" "$(acurl -s -o /dev/null -w '%{http_code}' $base/dists/$CODENAME/InRelease)" 200
	check_eq "pubkey.gpg without login" "$(curl -s -o /dev/null -w '%{http_code}' $base/pubkey.gpg)" 200
	check_eq "directory listing /dists/ (with login)" "$(acurl -s -o /dev/null -w '%{http_code}' $base/dists/)" 403
	for p in conf/distributions db/ archive/ logs/publish.log; do
		check_eq "private path /$p (with login)" "$(acurl -s -o /dev/null -w '%{http_code}' "$base/$p")" 404
	done
	check_eq "dot file /.publish.lock (with login)" "$(acurl -s -o /dev/null -w '%{http_code}' "$base/.publish.lock")" 403
	check_eq "POST is refused" "$(acurl -s -o /dev/null -w '%{http_code}' -X POST $base/dists/)" 405
	check_eq "security headers" "$(acurl -sI $base/pubkey.gpg | grep -ci '^x-content-type-options: nosniff')" 1
	check "no nginx version in the Server header" bash -c "! curl -sI $base/pubkey.gpg | grep -qiE '^server: nginx/'"
	acurl -s -o "$OUT/InRelease" $base/dists/$CODENAME/InRelease
	local v
	v=$(gpgv --keyring "$REPO/public/pubkey.gpg" --status-fd 1 "$OUT/InRelease" 2> /dev/null | awk '$2=="VALIDSIG"{print $12;exit}')
	check_eq "InRelease signature (gpgv): primary key" "$v" "$FPR"
	check "InRelease verifies with plain gpg --verify against the exported key" bash -c "gpg --no-default-keyring --keyring $REPO/public/pubkey.gpg --verify $OUT/InRelease 2>&1 | grep -q 'Good signature'"
	check_eq "public URL over https (mock edge) answers the same InRelease" "$(acurl -s https://$DOMAIN/dists/$CODENAME/InRelease | sha256sum | cut -c1-64)" "$(sha256sum < "$OUT/InRelease" | cut -c1-64)"
	check_eq "public URL without login" "$(curl -s -o /dev/null -w '%{http_code}' https://$DOMAIN/dists/$CODENAME/InRelease)" 401
	check_eq "published version" "$(reprepro -b $REPO -T deb list "$CODENAME" hestia | awk '{print $NF}')" "$VER_A"
	check "source archive stored" bash -c "ls $REPO/public/sources/vylarisspace-1.10.5-100-*.tar.gz"
	check "the repository is outside of git and only public/ is the nginx root" grep -q "root $REPO/public;" /etc/nginx/conf.d/vylarisspace-repo.conf

	banner "A5 CLIENT-INSTALL.txt and the cloudflared service"
	local ci="$STATE/CLIENT-INSTALL.txt"
	sed 's/^/    | /' "$ci" | maskpw
	check "CLIENT-INSTALL.txt: installer command with the URL and the fingerprint" grep -qF -- "--vylaris-repo https://$DOMAIN --vylaris-key-fingerprint $FPR" "$ci"
	check "CLIENT-INSTALL.txt: login line equals repo-auth" grep -qxF -f <(printf '%s\n' "Login (user:password) : $user:$pw") "$ci"
	check "CLIENT-INSTALL.txt: the safest form is ONE line joined with && (pasting two lines cannot make read swallow the second)" grep -qxF "     read -r -s -p 'Repository login (user:password): ' VYLARIS_REPO_AUTH && echo && export VYLARIS_REPO_AUTH && bash install/hst-install-ubuntu.sh --vylaris-repo https://$DOMAIN --vylaris-key-fingerprint $FPR" "$ci"
	check "CLIENT-INSTALL.txt: same one line form for client-setup.sh" grep -qxF "     read -r -s -p 'Repository login (user:password): ' VYLARIS_REPO_AUTH && echo && export VYLARIS_REPO_AUTH && bash client-setup.sh --repo https://$DOMAIN --key-fingerprint $FPR --update" "$ci"
	check "CLIENT-INSTALL.txt: no line that ends the read with ; echo (the old two line form)" bash -c "! grep -q 'VYLARIS_REPO_AUTH; echo; export' $ci"
	check "CLIENT-INSTALL.txt: variable form VYLARIS_REPO_AUTH" grep -qF -f <(printf '%s\n' "VYLARIS_REPO_AUTH='$user:$pw' bash install/hst-install-ubuntu.sh") "$ci"
	check "CLIENT-INSTALL.txt: no option form with the password (it would show in ps)" bash -c "! grep -qF -e '--vylaris-repo-auth' $ci"
	check "CLIENT-INSTALL.txt: client-setup.sh command" grep -qF -- "client-setup.sh --repo https://$DOMAIN --key-fingerprint $FPR --update" "$ci"
	check "CLIENT-INSTALL.txt: the spaced fingerprint is there too" grep -qF "$(echo "$FPR" | sed 's/\(....\)/\1 /g; s/ $//')" "$ci"
	for o in --vylaris-repo --vylaris-key-fingerprint --vylaris-repo-auth; do
		check "the option $o exists in install/hst-install-ubuntu.sh and -debian.sh" bash -c "grep -q -- '$o' $SRC/install/hst-install-ubuntu.sh && grep -q -- '$o' $SRC/install/hst-install-debian.sh"
	done
	for o in --repo --key-fingerprint --update; do
		check "the option $o exists in client-setup.sh" grep -q -- "$o" "$SRC/src/vylaris/client-setup.sh"
	done
	check "the terminal summary has the same command" bash -c "grep -qF -- '--vylaris-key-fingerprint $FPR' $OUT/run-*-main.out"
	check "cloudflared was installed from the given deb" bash -c "dpkg -s cloudflared | grep -q '^Version: 2099.1.0'"
	check "the unit's ExecStart names the real file (readlink -f), not the /usr/local/bin link" grep -qx 'ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run' /etc/systemd/system/vylarisspace-tunnel.service
	check_eq "cloudflared service file mode" "$(modeof /etc/systemd/system/vylarisspace-tunnel.service)" 644
	check "the service file has no token" bash -c "! grep -q -F -f <(cut -d= -f2- /etc/vylarisspace-repo-host/tunnel.env) /etc/systemd/system/vylarisspace-tunnel.service"
	check "the service reads the token from the root-only env file" grep -q '^EnvironmentFile=/etc/vylarisspace-repo-host/tunnel.env$' /etc/systemd/system/vylarisspace-tunnel.service
	echo "  cloudflared arguments recorded by the stub:"
	sed 's/^/    | /' "$OUT/cloudflared-argv.txt"
	check_eq "cloudflared was started as: --no-autoupdate tunnel run (no token in the arguments)" "$(sort -u "$OUT/cloudflared-argv.txt" | grep -v -- '--version')" "--no-autoupdate tunnel run"
	check "cloudflared process is running" pgrep -f 'sleep 10000[0]'

	banner "A6 idempotency: second run changes nothing"
	local before after
	snap() {
		echo "fpr=$(fpr_of "$STATE/keys/out/pubkey.asc")"
		echo "tunnel=$(mq "[t['id'] for t in d['tunnels'] if not t['deleted_at']]")"
		sha256sum "$STATE/repo-auth" "$STATE/key.pass" /etc/nginx/vylarisspace-repo.htpasswd /etc/nginx/conf.d/vylarisspace-repo.conf \
			/etc/vylarisspace-repo-host/tunnel.env /etc/systemd/system/vylarisspace-tunnel.service "$STATE"/keys/out/* "$STATE/CLIENT-INSTALL.txt" | sed 's/  / /'
		echo "dns=$(mq "[(r['id'], r['content']) for r in d['dns']]")"
		echo "published=$(reprepro -b $REPO list "$CODENAME" hestia)"
	}
	before=$(snap)
	local posts_t posts_d puts
	posts_t=$(calls '^POST .*/cfd_tunnel$')
	posts_d=$(calls '^POST .*/dns_records')
	puts=$(calls '^PUT ')
	run_script rerun --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "second run" 0
	out_has_not_lit "second run: the password is not printed again" "$pw"
	last_out | grep -E '^(==|  \[)' | sed 's/^/    | /'
	after=$(snap)
	check_eq "nothing changed (key, tunnel, login, password file, nginx, token, unit, dns, published)" "$after" "$before"
	check_eq "no second tunnel was created (POST calls)" "$(calls '^POST .*/cfd_tunnel$')" "$posts_t"
	check_eq "no new DNS record was created" "$(calls '^POST .*/dns_records')" "$posts_d"
	check_eq "no PUT of the tunnel route" "$(calls '^PUT ')" "$puts"
	out_has "second run: signing key skipped" 'signing key exists'
	out_has "second run: tunnel skipped" 'tunnel exists'
	out_has "second run: DNS skipped" 'DNS record is right'
	out_has "second run: login skipped" 'repository login exists'
	out_has "second run: package already published" 'already published'
	out_has_not "second run: nothing generated" '\[done\]     (signing key created|repository login generated|tunnel created)'
	run_script rerun-norflags
	expect_rc "third run with no arguments at all (domain from the saved state)" 0
	check_eq "still the same state after the run without arguments" "$(snap)" "$before"
	out_has_not_lit "third run: the password is not printed either" "$pw"
	run_script rerun-upper --domain "REPO.Vylaris.Test." --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "the domain REPO.Vylaris.Test. (upper case, trailing dot) is the same domain as the saved one" 0
	check_eq "still the same state after the run with the upper case domain" "$(snap)" "$before"
	run_script other-domain --domain other.vylaris.test
	expect_rc "a different domain is refused" 2
	out_has "different domain: message" 'already set up for repo.vylaris.test'
	run_script other-user --domain "$DOMAIN" --auth-user someoneelse
	expect_rc "a different --auth-user is refused (the login is not rotated)" 2
	run_script tunnel-rename --domain "$DOMAIN" --tunnel-name another-tunnel --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "a different --tunnel-name although a tunnel is in the state is refused (like --domain)" 2
	out_has "tunnel rename: message names the old tunnel" 'already uses the tunnel "vylarisspace-repo"'
	check_eq "state: TUNNEL_NAME is not overwritten" "$(state_get TUNNEL_NAME)" vylarisspace-repo
	check_eq "no second tunnel was created" "$(calls '^POST .*/cfd_tunnel$')" "$posts_t"
	check_eq "and nothing else changed" "$(snap)" "$before"
	run_script tunnel-same-name --domain "$DOMAIN" --tunnel-name vylarisspace-repo --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "the same --tunnel-name as the saved one is fine" 0

	banner "A6b the checkout must belong to root or the sudo user, and must not be writable by others"
	chown -R 12345:12345 "$SRC"
	run_script checkout-other-owner --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "checkout owned by another user" 2
	out_has "other owner: message" 'belongs to user id 12345'
	out_has "other owner: says how to fix it" 'chown -R root:'
	out_has "other owner: says that the build runs programs of the checkout as root" 'use your own clean clone'
	check_eq "nothing changed" "$(snap)" "$before"
	SUDO_UID=12345 run_script checkout-sudo-owner --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "checkout owned by the user who started sudo (SUDO_UID) is accepted; git works for exactly this checkout" 0
	# a plain "git clone" as a normal Ubuntu user: directories 775, the private group of that user
	useradd -m -U alice
	local alice_uid
	alice_uid=$(id -u alice)
	chown -R alice:alice "$SRC"
	chmod -R g+w "$SRC"
	check "the clone of the normal user has group-writable directories (775) and files (664)" bash -c "test \"\$(stat -c %a $SRC)\" = 775 && test \"\$(stat -c %a $SRC/.git)\" = 775"
	SUDO_UID=$alice_uid run_script checkout-user-775 --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "a plain git clone of a normal user (775, private group) started with sudo works" 0
	useradd -m -U bob
	usermod -aG alice bob
	SUDO_UID=$alice_uid run_script checkout-group-members --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "the same, but another user (bob) is a member of the group alice: refused" 2
	out_has "group with other members: message" 'can be changed by a group with other members'
	gpasswd -d bob alice > /dev/null
	groupadd shared
	usermod -aG shared bob
	chgrp -R shared "$SRC"
	SUDO_UID=$alice_uid run_script checkout-shared-group --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "group-writable for the group shared (members: bob): refused" 2
	out_has "shared group: message" 'can be changed by a group with other members'
	chgrp -R alice "$SRC"
	chmod -R g-w "$SRC"
	chmod o+w "$SRC"
	SUDO_UID=$alice_uid run_script checkout-world-writable --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "writable by everybody: refused" 2
	out_has "world-writable: message" 'can be changed by every user'
	chmod o-w "$SRC"
	chown -R root:root "$SRC"
	# the other places a root build or a git hook would run code from: .git/config, .git/hooks, src and its entries
	chmod o+w "$SRC/.git/config"
	run_script checkout-config-writable --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc ".git/config writable by everybody: refused" 2
	out_has ".git/config: names the file" '\.git/config can be changed by every user'
	chmod o-w "$SRC/.git/config"
	chmod o+w "$SRC/.git/hooks"
	run_script checkout-hooks-writable --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc ".git/hooks writable by everybody: refused" 2
	out_has ".git/hooks: names the directory" '\.git/hooks can be changed by every user'
	chmod o-w "$SRC/.git/hooks"
	printf '#!/bin/sh\nexit 0\n' > "$SRC/.git/hooks/pre-commit"
	chmod 755 "$SRC/.git/hooks/pre-commit"
	chown 12345 "$SRC/.git/hooks/pre-commit"
	run_script checkout-hook-foreign --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "an active git hook that belongs to another user: refused" 2
	out_has "foreign hook: names it" 'hooks/pre-commit belongs to user id 12345'
	rm -f "$SRC/.git/hooks/pre-commit"
	chown 12345 "$SRC/src"
	run_script checkout-src-foreign --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "src/ belongs to another user: refused" 2
	out_has "src: names the directory" 'src belongs to user id 12345'
	chown root:root "$SRC/src"
	chmod o+w "$SRC/src/hst_autocompile.sh"
	run_script checkout-src-entry-writable --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "src/hst_autocompile.sh writable by everybody: refused" 2
	out_has "src entry: names the file" 'src/hst_autocompile\.sh can be changed by every user'
	chmod o-w "$SRC/src/hst_autocompile.sh"
	chmod o+w "$SRC/src/vylaris"
	run_script checkout-src-subdir-writable --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "src/vylaris writable by everybody: refused" 2
	chmod o-w "$SRC/src/vylaris"
	userdel -r alice > /dev/null 2>&1
	userdel -r bob > /dev/null 2>&1
	groupdel shared
	check_eq "nothing changed by all these refusals" "$(snap)" "$before"
	run_script checkout-clean-again --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "root-owned checkout, nothing writable by others: accepted again" 0

	banner "A6c the state is never replaced: other --state-dir, pointer lost, state lost, key of the repository, login lost"
	run_script state-other --domain "$DOMAIN" --state-dir /root/other-state
	expect_rc "a different --state-dir than the recorded one" 2
	out_has "other state dir: message" "already uses the state directory $STATE"
	check "the other state directory was not created" test ! -e /root/other-state
	mv /etc/vylarisspace-repo-host/state-dir /tmp/state-dir.saved
	run_script state-other-noptr --domain "$DOMAIN" --state-dir /root/other-state
	expect_rc "a new --state-dir although repository, password file and tunnel token of an earlier run exist" 2
	out_has "no key in the new state dir: message" "signing key is missing in the state directory /root/other-state"
	check "no key or password was created there" test ! -e /root/other-state
	mv /tmp/state-dir.saved /etc/vylarisspace-repo-host/state-dir
	mv "$STATE" "$STATE.saved"
	run_script state-lost --domain "$DOMAIN"
	expect_rc "the state directory is gone (moved away), the repository is still there" 2
	out_has "lost state: message" 'signing key is missing in the state directory'
	check "no new key, passphrase or login was generated" bash -c "test ! -e $STATE/keys && test ! -e $STATE/key.pass && test ! -e $STATE/repo-auth"
	rm -rf "$STATE"
	mv "$STATE.saved" "$STATE"
	check_eq "the key is still the old one" "$(fpr_of "$STATE/keys/out/pubkey.asc")" "$FPR"
	cp -p "$REPO/public/pubkey.gpg" /tmp/pubkey.gpg.saved
	mkdir -m 700 /tmp/otherkey
	GNUPGHOME=/tmp/otherkey gpg --batch --pinentry-mode loopback --passphrase '' --quick-gen-key 'other <other@example.invalid>' ed25519 sign never > /dev/null 2>&1
	GNUPGHOME=/tmp/otherkey gpg --batch --export > "$REPO/public/pubkey.gpg"
	run_script repo-other-key --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "the repository's public key is not the key of the state directory" 2
	out_has "other key: message" 'is not the signing key of this state directory'
	cp -p /tmp/pubkey.gpg.saved "$REPO/public/pubkey.gpg"
	GNUPGHOME=/tmp/otherkey gpgconf --kill gpg-agent > /dev/null 2>&1
	rm -rf /tmp/otherkey
	# files that are no key at all (gpg fails): the script says what is wrong instead of stopping without a word
	echo '<html>not a key</html>' > "$REPO/public/pubkey.gpg"
	run_script repo-key-garbage --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "the repository's pubkey.gpg is not a key at all (gpg fails)" 2
	out_has "garbage pubkey.gpg: the message says unreadable" 'fingerprint unreadable\) is not the signing key'
	cp -p /tmp/pubkey.gpg.saved "$REPO/public/pubkey.gpg"
	cp -p "$STATE/keys/out/pubkey.asc" /tmp/pubkey.asc.saved
	echo 'this is not a key' > "$STATE/keys/out/pubkey.asc"
	run_script state-key-garbage --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "the public key in the state directory is not a key at all (gpg fails)" 2
	out_has "garbage pubkey.asc: message" 'cannot read the public key'
	cp -p /tmp/pubkey.asc.saved "$STATE/keys/out/pubkey.asc"
	mv "$STATE/repo-auth" /tmp/repo-auth.saved
	run_script login-lost --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "repo-auth is gone but the password file of the earlier run exists" 2
	out_has "lost login: message" 'password file .* of an earlier run exists'
	check "no new login was generated" test ! -e "$STATE/repo-auth"
	mv /tmp/repo-auth.saved "$STATE/repo-auth"
	check_eq "everything is as before the refusals" "$(snap)" "$before"

	banner "A7 --print-client-command and --status"
	run_script print --print-client-command
	expect_rc "--print-client-command" 0
	out_has_not_lit "--print-client-command does not print the password" "$pw"
	out_has "it names the file with the login instead" "$STATE/repo-auth"
	out_has "and the exact command that prints the login again" "bash $SRC/src/vylaris/setup-repo-host.sh --print-client-command --show-login"
	out_has "and the cat command for the file" "cat $STATE/CLIENT-INSTALL.txt"
	out_has_not "and no longer the vague '--show-login prints it again'" '\--show-login prints it again'
	out_has_not "and has no option form with the login" 'vylaris-repo-auth'
	run_script print-login --print-client-command --show-login
	expect_rc "--print-client-command --show-login" 0
	check_eq "printed text with --show-login equals CLIENT-INSTALL.txt" "$(cat "$OUT"/run-"$(printf '%02d' $RUN_N)"-print-login.out)" "$(cat "$ci")"
	run_script status --status
	expect_rc "--status" 0
	last_out | sed 's/^/    | /'
	out_has "status: nginx" 'nginx +: running'
	out_has "status: local site" 'local site +: answers'
	out_has "status: cloudflared" 'cloudflared +: service vylarisspace-tunnel running'
	out_has "status: tunnel via the API" 'tunnel +: vylarisspace-repo .* status healthy'
	check "status: published versions" bash -c "grep -F '$CODENAME: amd64 $VER_A' $OUT/run-$(printf '%02d' $RUN_N)-status.out"
	TOK=$WRONG run_script status-wrong-token --status
	expect_rc "--status with a wrong token: the API problem is reported, the rest of the status is printed, no failure" 0
	out_has "status, wrong token: tunnel line says not checked and why" 'tunnel +: not checked \(HTTP 401: \[9109\]'
	out_has "status, wrong token: the published versions are still printed" 'published +:'
	mock_set '{"perms":["tunnel","dns"]}'
	run_script status-no-zone --status
	expect_rc "--status with a token without Zone Read: not checked, continues" 0
	out_has "status, no zone permission: not checked, with the reason" 'tunnel +: not checked \(HTTP 403'
	mock_set '{"perms":["tunnel","dns","zone"]}'
	mock POST /_mock/connect "{\"tunnel_id\":\"$TUNNEL_ID\",\"status\":\"degraded\"}" > /dev/null
	run_script status-degraded --status
	expect_rc "--status with a degraded tunnel is not an error" 0
	out_has "degraded tunnel: shown with its meaning" 'status degraded .*reduced redundancy'
	mock POST /_mock/connect "{\"tunnel_id\":\"$TUNNEL_ID\"}" > /dev/null

	banner "A8 secrets"
	scan_secrets

	banner "A9 client: client-setup.sh against the repository (https, login), then apt"
	local cs=$SRC/src/vylaris/client-setup.sh
	apt_state() { apt-cache policy hestia 2> /dev/null; }
	VYLARIS_REPO_AUTH="$user:$pw" bash "$cs" --repo "https://$DOMAIN" --key-fingerprint "$FPR" --update > "$OUT/client-1.out" 2>&1
	check_eq "client-setup.sh --update (https, fingerprint, login)" "$?" 0
	sed 's/^/    | /' "$OUT/client-1.out" | maskpw | tail -n 14
	apt_state > "$OUT/apt-policy.txt"
	sed 's/^/    | /' "$OUT/apt-policy.txt"
	check "apt-cache policy: candidate is the published version" grep -q "Candidate: $VER_A" "$OUT/apt-policy.txt"
	check "apt-cache policy: it comes from https://$DOMAIN" grep -q "https://$DOMAIN $CODENAME/main" "$OUT/apt-policy.txt"
	apt-get install -s hestia > "$OUT/apt-install-s.txt" 2>&1
	grep -E '^Inst hestia|^E:' "$OUT/apt-install-s.txt" | sed 's/^/    | /'
	check "apt-get install -s hestia would install the published version from the own source" grep -q "^Inst hestia (${VER_A} VylarisSpace:$CODENAME" "$OUT/apt-install-s.txt"
	VYLARIS_REPO_AUTH="$user:wrongpass1234" bash "$cs" --repo "https://$DOMAIN" --key-fingerprint "$FPR" --update > "$OUT/client-2.out" 2>&1
	check "client with a wrong password: apt update fails (non-zero)" test "$?" != 0
	VYLARIS_REPO_AUTH="$user:$pw" bash "$cs" --repo "https://$DOMAIN" --key-fingerprint 0000000000000000000000000000000000000000 > "$OUT/client-3.out" 2>&1
	check_eq "client with a wrong fingerprint is refused (exit code)" "$?" 2
	VYLARIS_REPO_AUTH="$user:$pw" bash "$cs" --root /tmp/croot --suite "$CODENAME" --allow-insecure-http --repo "http://127.0.0.1:$PORT" --key-fingerprint "$FPR" > "$OUT/client-4.out" 2>&1
	check_eq "client: login together with plain http is refused" "$?" 2
	grep -E 'Refusing' "$OUT/client-4.out" | sed 's/^/    | /'

	banner "A10 --public, --auth (nginx), then the client over plain http (--allow-insecure-http)"
	run_script public --domain "$DOMAIN" --public --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "--public" 0
	check "the nginx site changed (password protection off) ..." bash -c "! grep -q 'auth_basic \"VylarisSpace' /etc/nginx/conf.d/vylarisspace-repo.conf"
	check "... but no .bak was written: the previous file was written by this script, it is no original worth keeping" bash -c "test ! -e /etc/nginx/vylarisspace-repo.conf.bak && ! ls /etc/nginx/ | grep -q 'conf.bak'"
	check "no .bak in conf.d either (an include of conf.d/* cannot load it twice)" bash -c "! ls /etc/nginx/conf.d | grep -q bak"
	run_script public-saved --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "a run without --public/--auth keeps the saved mode (public)" 0
	out_has "and says so, with the way back" 'The host is saved as public .*: add --auth to switch back'
	run_script public-auth-user --domain "$DOMAIN" --auth-user someone --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "--auth-user while the host is saved as public is a usage error" 1
	out_has "with the way back" 'the host is saved as public: add --auth to switch back'
	out_has_not "exit 1: no extra 'stopped early' line" 'The run stopped early'
	check_eq "the host is still public" "$(curl -s -o /dev/null -w '%{http_code}' $base/dists/$CODENAME/InRelease)" 200
	check_eq "InRelease without login (public)" "$(curl -s -o /dev/null -w '%{http_code}' $base/dists/$CODENAME/InRelease)" 200
	check_eq "the login files were not touched (public)" "$(sha256sum < "$STATE/repo-auth")" "$(printf '%s\n' "$user:$pw" | sha256sum)"
	check "CLIENT-INSTALL.txt (public): no login" bash -c "! grep -q 'Login' $ci && grep -q 'public repository' $ci"
	rm -f /etc/apt/sources.list.d/vylarisspace.list /etc/apt/auth.conf.d/vylarisspace.conf /etc/apt/preferences.d/vylarisspace
	bash "$cs" --repo "http://127.0.0.1:$PORT" --allow-insecure-http --key-fingerprint "$FPR" --update > "$OUT/client-5.out" 2>&1
	check_eq "client-setup.sh --allow-insecure-http --update against http://127.0.0.1:$PORT" "$?" 0
	apt_state > "$OUT/apt-policy-http.txt"
	sed 's/^/    | /' "$OUT/apt-policy-http.txt"
	check "apt: candidate from http://127.0.0.1:$PORT $CODENAME/main" grep -q "http://127.0.0.1:$PORT $CODENAME/main" "$OUT/apt-policy-http.txt"
	apt-get install -s hestia 2> /dev/null | grep -E '^Inst hestia' | sed 's/^/    | /'
	check "apt-get install -s hestia (http): published version" bash -c "apt-get install -s hestia 2>/dev/null | grep -q '^Inst hestia (${VER_A} VylarisSpace:$CODENAME'"
	run_script auth-again --domain "$DOMAIN" --auth --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "--auth again" 0
	check_eq "InRelease without login: 401 again" "$(curl -s -o /dev/null -w '%{http_code}' $base/dists/$CODENAME/InRelease)" 401
	check_eq "the same password works again (not rotated)" "$(acurl -s -o /dev/null -w '%{http_code}' $base/dists/$CODENAME/InRelease)" 200

	banner "A11 second package revision, then --uninstall-tunnel and the resume"
	run_script publish-b --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_B"
	expect_rc "publish a second revision with --deb" 0
	check_eq "published version is the newer one" "$(reprepro -b $REPO -T deb list "$CODENAME" hestia | awk '{print $NF}')" "$VER_B"
	run_script old-deb --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_A"
	expect_rc "publishing an older version is refused" 2
	TOK=$WRONG run_script uninstall-badtoken --uninstall-tunnel --delete-dns --yes
	expect_rc "--uninstall-tunnel --delete-dns with a wrong token stops with the API error" 4
	check "nothing was torn down: the service file is still there" test -f /etc/systemd/system/vylarisspace-tunnel.service
	check "the tunnel token file is still there" test -f /etc/vylarisspace-repo-host/tunnel.env
	check "the cloudflared process is still running" pgrep -f 'sleep 10000[0]'
	check "the state still has the domain" test -n "$(state_get DOMAIN)"
	out_has_not "no [done] line: nothing was stopped or removed" '\[done\]'
	mock_set '{"perms":["tunnel","zone"]}'
	run_script uninstall-nodns --uninstall-tunnel --delete-dns --yes
	expect_rc "--delete-dns with a token that cannot read DNS: stops before anything is removed" 4
	check "still nothing torn down (service file)" test -f /etc/systemd/system/vylarisspace-tunnel.service
	mock_set '{"perms":["tunnel","dns","zone"]}'
	run_script uninstall-noyes --uninstall-tunnel < /dev/null
	expect_rc "--uninstall-tunnel without --yes and without terminal" 2
	check "the service is still there after the refused uninstall" test -f /etc/systemd/system/vylarisspace-tunnel.service
	run_script uninstall --uninstall-tunnel --yes
	expect_rc "--uninstall-tunnel --yes" 0
	check "service file removed" test ! -e /etc/systemd/system/vylarisspace-tunnel.service
	check "tunnel token file removed" test ! -e /etc/vylarisspace-repo-host/tunnel.env
	check "cloudflared process stopped" bash -c "! pgrep -f 'sleep 10000[0]'"
	check_eq "tunnel and DNS record still exist at Cloudflare" "$(mq "(len($OT), len($OD))")" "(1, 1)"
	mock POST /_mock/disconnect "{\"tunnel_id\":\"$TUNNEL_ID\"}" > /dev/null
	run_script resume --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_B"
	expect_rc "resume after the uninstall" 0
	check_eq "still one tunnel after the resume" "$(mq "len($OT)")" 1
	check_eq "same tunnel id" "$(mq "${OT}[0]['id']")" "$TUNNEL_ID"
	check_eq "same key fingerprint" "$(fpr_of "$STATE/keys/out/pubkey.asc")" "$FPR"
	check_eq "tunnel healthy again" "$(mq "${OT}[0]['status']")" healthy
	run_script uninstall-dns --uninstall-tunnel --delete-dns --yes
	expect_rc "--uninstall-tunnel --delete-dns --yes" 0
	last_out | sed 's/^/    | /'
	check_eq "DNS record of the tunnel deleted at Cloudflare" "$(mq "len($OD)")" 0
	check_eq "the decoy DNS record of another name is still there" "$(mq "len([r for r in d['dns'] if r['name']=='other.vylaris.test'])")" 1
	check_eq "the tunnel was adopted (not created by us): it is NOT deleted" "$(mq "len($OT)")" 1
	out_has "uninstall: says that the tunnel was not created by this script" 'was not created by this script: it is left alone'
	check_eq "signing key still there" "$(fpr_of "$STATE/keys/out/pubkey.asc")" "$FPR"
	check "state forgot the domain but keeps the (adopted) tunnel" bash -c "! grep -q '^DOMAIN=' $STATE/state.env && grep -q '^TUNNEL_ID=$TUNNEL_ID' $STATE/state.env"
	run_script after-delete --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_B"
	expect_rc "setting up again reuses the tunnel that was left alone, same key" 0
	check_eq "same tunnel id" "$(mq "${OT}[0]['id']")" "$TUNNEL_ID"
	check_eq "key fingerprint unchanged" "$(fpr_of "$STATE/keys/out/pubkey.asc")" "$FPR"
	check_eq "DNS record again" "$(mq "len($OD)")" 1
	mock_reset # at Cloudflare the tunnel and the records are gone now
	run_script recreate --domain "$DOMAIN" --cloudflared-deb /tmp/cloudflared-stub.deb --deb "$DEB_B"
	expect_rc "the tunnel of the state no longer exists: looked for by name, a NEW one is created" 0
	out_has "recreate: warns that the old tunnel is gone" 'no longer exists at Cloudflare'
	check_eq "new tunnel id differs" "$(mq "${OT}[0]['id'] != '$TUNNEL_ID'")" True
	check_eq "state: the new tunnel is marked as created by us" "$(state_get TUNNEL_CREATED)" yes
	run_script uninstall-dns2 --uninstall-tunnel --delete-dns --yes
	expect_rc "--uninstall-tunnel --delete-dns --yes for a tunnel we created" 0
	check_eq "DNS record deleted at Cloudflare" "$(mq "len($OD)")" 0
	check_eq "tunnel deleted at Cloudflare (it was created by us)" "$(mq "len($OT)")" 0
	check "state forgot the domain, the tunnel and the created flag" bash -c "! grep -q '^DOMAIN=' $STATE/state.env && ! grep -q '^TUNNEL_ID=' $STATE/state.env && ! grep -q '^TUNNEL_CREATED=' $STATE/state.env"
	run_script skip-service --domain "$DOMAIN" --skip-tunnel-service
	expect_rc "--skip-tunnel-service on an installed host (exit code stays 0)" 0
	sed 's/^/    | /' "$OUT/run-$(printf '%02d' $RUN_N)-skip-service.out" | grep -A6 'NOT installed'
	out_has "the headline says the tunnel is NOT started by this script" 'THE TUNNEL IS NOT STARTED BY THIS SCRIPT'
	out_has_not "and there is no 'running' headline" 'FERTIG / DONE'
	out_has_not "and no 'is running' claim" 'repository host is running'
	check_eq "the cloudflared run command is printed in step 6 and repeated in the summary" "$(last_out | grep -c 'docker run -d --name vylarisspace-tunnel')" 2
	out_has "the summary says that https://DOMAIN does not answer before the tunnel runs" 'does not answer yet. Start cloudflared'
}

# ================================================================================================
# profile b
# ================================================================================================
profile_b() {
	banner "B1 port 8088 is taken -> refuse and say what to do"
	mock_reset
	python3 -c 'import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1",8088)); s.listen(); time.sleep(100000)' &
	BLOCK=$!
	sleep 1
	# somebody else's policy-rc.d (no marker of ours) must never be removed
	printf '#!/bin/sh\n# foreign policy\nexit 101\n' > /usr/sbin/policy-rc.d
	chmod 755 /usr/sbin/policy-rc.d
	cp /usr/sbin/policy-rc.d /tmp/policy-rc.d.foreign
	run_script port-busy --domain "$DOMAIN" --staging --public --deb "$DEB_A"
	expect_rc "port taken" 2
	out_has "port taken: message" '--listen-port'
	check "no nginx site was written" test ! -e /etc/nginx/conf.d/vylarisspace-repo.conf
	check "the busy port is refused in step 1: no signing key, no repository yet" bash -c "test ! -e $STATE/keys && test ! -e $REPO"
	check_eq "and nothing was written at Cloudflare (no tunnel either)" "$(calls '^(POST|PUT|PATCH|DELETE) ')" 0
	check "a foreign policy-rc.d is neither replaced nor removed" cmp /usr/sbin/policy-rc.d /tmp/policy-rc.d.foreign
	rm -f /usr/sbin/policy-rc.d
	kill $BLOCK 2> /dev/null

	banner "B2 nginx -t fails (conflicting default_server) -> our site is rolled back, nginx keeps running"
	mkdir -p /etc/nginx/conf.d
	rm -f /etc/nginx/sites-enabled/default # (the stock site wants IPv6, which this container does not have; the script removes it itself in a normal run)
	systemctl start nginx
	check "nginx is running before the conflicting configuration is added" pgrep -x nginx
	printf 'server { listen 127.0.0.1:8089 default_server; server_name conflict.example.invalid; return 404; }\n' > /etc/nginx/conf.d/zz-conflict.conf
	run_script nginx-conflict --domain "$DOMAIN" --listen-port 8089 --staging --public --deb "$DEB_A"
	expect_rc "nginx -t failure" 2
	out_has "nginx -t failure: message" 'nginx -t rejected the new site'
	check "our site file was removed again" test ! -e /etc/nginx/conf.d/vylarisspace-repo.conf
	check "nginx is still running with the old configuration" pgrep -x nginx
	check "nothing listens on 8089 (nginx was not reloaded with the broken configuration)" bash -c "! ss -Hltn | awk '{print \$4}' | grep -q ':8089\$'"
	check "the foreign configuration file is untouched" test -f /etc/nginx/conf.d/zz-conflict.conf
	rm -f /etc/nginx/conf.d/zz-conflict.conf

	banner "B3 --force-dns, --skip-tunnel-service, --public, --staging, --listen-port, two suites"
	mock_reset
	mock_set "{\"dns\":[{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"203.0.113.9\",\"proxied\":true,\"ttl\":300}]}"
	local suffix old_id
	suffix=$(. /etc/os-release && echo "$ID$VERSION_ID")
	old_id=$(mq "d['dns'][0]['id']")
	bash "$SRC/test/vylaris-upgrade/repack-deb.sh" own /debs/hestia_1.10.5-100+ubuntu24.04_amd64.deb /tmp/hestia_1.10.5-100+debian13_amd64.deb 1.10.5-100+debian13 > /dev/null
	# an nginx site of the same name that this script did not write
	printf '# my own site\nserver { listen 127.0.0.1:8095; server_name x.invalid; return 204; }\n' > /etc/nginx/conf.d/vylarisspace-repo.conf
	cp /etc/nginx/conf.d/vylarisspace-repo.conf /tmp/foreign-site.conf
	# the repository directory holds only what repo-init.sh made before it was stopped: empty directories and an
	# empty conf/distributions (an earlier run died there). It must be continued, not refused.
	rm -rf "$REPO"
	mkdir -p "$REPO"/conf "$REPO"/db "$REPO"/logs "$REPO"/archive "$REPO"/public/dists "$REPO"/public/pool "$REPO"/public/sources
	: > "$REPO/conf/distributions"
	run_script foreign-nginx --domain "$DOMAIN" --force-dns --staging --listen-port 8089 --skip-tunnel-service --public --deb /tmp/hestia_1.10.5-100+debian13_amd64.deb
	expect_rc "an nginx site of that name without our header is refused" 2
	out_has "foreign nginx site: message" 'was not written by this script'
	check "the foreign site is untouched" cmp /etc/nginx/conf.d/vylarisspace-repo.conf /tmp/foreign-site.conf
	check_eq "nothing was done at Cloudflare" "$(calls '^(PUT|POST|PATCH|DELETE) ')" 0
	check "the refused run (foreign nginx site) did not touch the repository (still only the skeleton): refused in step 1" bash -c "test ! -s $REPO/conf/distributions && test -z \"\$(find $REPO -type f ! -name distributions)\""
	# a huge nginx -T output after our site: grep -q would end early and nginx -T die of SIGPIPE
	python3 -c "print('# padding line for the nginx -T pipe test\n' * 60000)" > /etc/nginx/conf.d/zz-big.conf
	run_script force-dns --domain "$DOMAIN" --force-dns --force --skip-tunnel-service --public --staging --listen-port 8089 \
		--deb /tmp/hestia_1.10.5-100+debian13_amd64.deb
	expect_rc "--force-dns --force --skip-tunnel-service --public --staging --listen-port 8089 (with a 2 MB nginx -T output)" 0
	out_has "the skeleton of an interrupted repo-init is continued" 'only the beginning of an earlier, stopped repository creation: continuing it'
	check "the repository was created over the skeleton (distributions with the staging suites)" bash -c "grep -q '^Codename: $CODENAME-staging' $REPO/conf/distributions && test -s $REPO/public/dists/$CODENAME/InRelease"
	out_has "skip-tunnel-service: the headline says the tunnel is NOT started by this script" 'THE TUNNEL IS NOT STARTED BY THIS SCRIPT'
	out_has_not "skip-tunnel-service: no 'running' headline" 'FERTIG / DONE'
	check_eq "skip-tunnel-service: the run command appears in step 6 and again in the summary" "$(last_out | grep -c 'docker run -d --name vylarisspace-tunnel')" 2
	check "--force kept the foreign site as the one .bak (outside of conf.d)" cmp /etc/nginx/vylarisspace-repo.conf.bak /tmp/foreign-site.conf
	check "and our site replaced it" grep -q '^# Managed by setup-repo-host.sh' /etc/nginx/conf.d/vylarisspace-repo.conf
	last_out | grep -E '^(==|  \[|  *(docker|set -a|with)|        --env)' | sed 's/^/    | /' | head -50
	local tid
	tid=$(mq "d['tunnels'][0]['id']")
	check_eq "the A record was replaced by the tunnel CNAME" "$(mq "[(r['type'], r['content'], r['proxied']) for r in d['dns']]")" "[('CNAME', '$tid.cfargotunnel.com', True)]"
	check_eq "--force-dns changed the record in place (same id: the new record first, no gap, nothing to delete)" "$(mq "d['dns'][0]['id']")" "$old_id"
	check_eq "DNS calls that change something: one PATCH, no DELETE, no POST" "$(mq "[c.split()[0] for c in d['calls'] if 'dns_records' in c and not c.startswith('GET')]")" "['PATCH']"
	local bk
	bk=$(ls "$STATE"/dns-backup-*.json | head -n1)
	check "the old record was saved first (type, content, ttl, proxied) in a mode 600 file" bash -c "test \"\$(stat -c %a $bk)\" = 600 && jq -e '.[0] | .type == \"A\" and .content == \"203.0.113.9\" and .ttl == 300 and .proxied == true' $bk"
	check "and written to the log" grep -q 'DNS record before --force-dns: A 203.0.113.9 ttl=300 proxied=true' "$LOGF"
	check_eq "tunnel route uses the chosen port" "$(mq "d['tunnels'][0]['ingress'][0]['service']")" "http://127.0.0.1:8089"
	check "no systemd unit was installed" test ! -e /etc/systemd/system/vylarisspace-tunnel.service
	check "cloudflared was not installed" bash -c "! command -v cloudflared"
	out_has "docker/cloudflared command is printed" 'docker run -d --name vylarisspace-tunnel'
	out_has "the printed command refers to the env file, not to the token" '--env-file /etc/vylarisspace-repo-host/tunnel.env'
	check_eq "tunnel.env mode" "$(modeof /etc/vylarisspace-repo-host/tunnel.env)" 600
	out_has_not "the tunnel token is not printed" "$(sed -n 's/^TUNNEL_TOKEN=//p' /etc/vylarisspace-repo-host/tunnel.env | cut -c1-30)"
	check "staging suites exist" grep -q "^Codename: $CODENAME-staging" "$REPO/conf/distributions"
	check_eq "InRelease without login on port 8089 (public)" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8089/dists/$CODENAME/InRelease)" 200
	check_eq "only the suite of the given deb is served" "$(grep -m1 'Serves hestia for' "$STATE/CLIENT-INSTALL.txt" | sed 's/.*: //')" trixie
	check_eq "the verification used the suite that has a package" "$(reprepro -b $REPO -T deb list trixie hestia | awk '{print $NF}')" "1.10.5-100+debian13"
	check "no login in the public client text" bash -c "! grep -q 'Login' $STATE/CLIENT-INSTALL.txt"
	check "public mode: htpasswd/repo-auth were not created" test ! -e "$STATE/repo-auth"
	out_has "public check skipped (no tunnel run by the script)" 'public check: the tunnel is not run'

	banner "B3b --force-dns with an A and an AAAA record: a CNAME cannot stand next to them"
	mock_reset
	mock_set "{\"dns\":[{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"203.0.113.9\",\"proxied\":true},{\"type\":\"AAAA\",\"name\":\"$DOMAIN\",\"content\":\"2001:db8::9\",\"proxied\":true}]}"
	run_script force-dns2 --domain "$DOMAIN" --force-dns --skip-tunnel-service --public --staging --listen-port 8089 \
		--deb /tmp/hestia_1.10.5-100+debian13_amd64.deb
	expect_rc "--force-dns with A + AAAA" 0
	tid=$(mq "d['tunnels'][0]['id']")
	check_eq "both old records are gone, one CNAME to the tunnel is left" "$(mq "[(r['type'], r['content']) for r in d['dns']]")" "[('CNAME', '$tid.cfargotunnel.com')]"
	check_eq "the new record was tried first (PATCH), refused, the other record deleted, then the PATCH again" "$(mq "[c.split()[0] for c in d['calls'] if 'dns_records' in c and not c.startswith('GET')]")" "['PATCH', 'DELETE', 'PATCH']"
	bk=$(ls -t "$STATE"/dns-backup-*.json | head -n1)
	check "both old records were saved before anything changed" bash -c "jq -e 'length == 2 and (map(.type) | sort == [\"A\", \"AAAA\"])' $bk"
	check_eq "the backup file has mode 600" "$(modeof "$bk")" 600
	local fd_args=(--domain "$DOMAIN" --force-dns --skip-tunnel-service --public --staging --listen-port 8089 --deb /tmp/hestia_1.10.5-100+debian13_amd64.deb)

	banner "B3c the missing InRelease is exported by the script itself: readable for nginx (umask 022); a second foreign original"
	rm -rf "$REPO/public/dists/$CODENAME"
	run_script export-umask "${fd_args[@]}"
	expect_rc "the indices of a suite are missing: the script exports them again" 0
	out_has "export message" 'indices exported and signed'
	check_eq "InRelease is readable by everybody (644), not 600 from the umask 077 of the script" "$(modeof "$REPO/public/dists/$CODENAME/InRelease")" 644
	check_eq "the suite directory is 755" "$(modeof "$REPO/public/dists/$CODENAME")" 755
	check_eq "and nginx serves it" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8089/dists/$CODENAME/InRelease)" 200
	printf '# second foreign file\nserver {\n\tlisten 127.0.0.1:8089 default_server;\n\tserver_name y.invalid;\n\treturn 204;\n}\n' > /etc/nginx/conf.d/vylarisspace-repo.conf
	cp /etc/nginx/conf.d/vylarisspace-repo.conf /tmp/foreign-site2.conf
	run_script force-second-original "${fd_args[@]}" --force
	expect_rc "a second foreign nginx site replaced with --force" 0
	check "the first .bak is NOT overwritten" cmp /etc/nginx/vylarisspace-repo.conf.bak /tmp/foreign-site.conf
	check "the second original got a copy of its own (date in the name), outside of conf.d" bash -c "cmp \$(ls /etc/nginx/vylarisspace-repo.conf.bak.* | head -n1) /tmp/foreign-site2.conf && ! ls /etc/nginx/conf.d | grep -q bak"
	run_script after-force-again "${fd_args[@]}"
	expect_rc "a run that rewrites nothing (our own file)" 0
	check_eq "no further copy was made" "$(find /etc/nginx -maxdepth 1 -name 'vylarisspace-repo.conf.bak*' | wc -l)" 2

	banner "B3d --force-dns: a PATCH that fails for another reason than a conflict deletes nothing"
	mock_reset
	mock_set "{\"dns\":[{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"203.0.113.9\",\"proxied\":true},{\"type\":\"AAAA\",\"name\":\"$DOMAIN\",\"content\":\"2001:db8::9\",\"proxied\":true}]}"
	mock_set '{"fail":[{"method":"PATCH","contains":"dns_records","status":500,"times":4}]}'
	run_script force-dns-500 "${fd_args[@]}"
	expect_rc "the PATCH answers 500 four times (all retries)" 4
	out_has "the failure names the DNS change" 'changing the DNS record'
	out_has "and says that nothing was deleted" 'nothing was deleted'
	check_eq "no DNS record was deleted" "$(calls '^DELETE .*dns_records')" 0
	check_eq "both old records are still there" "$(mq "sorted(r['type'] for r in $OD)")" "['A', 'AAAA']"
	mock_set '{"fail":[{"method":"PATCH","contains":"dns_records","status":403,"times":1}]}'
	run_script force-dns-403 "${fd_args[@]}"
	expect_rc "the PATCH answers 403 (token without DNS Edit)" 4
	out_has "403: the permission hint" 'Cloudflare refused the API token'
	check_eq "403: no DNS record was deleted" "$(calls '^DELETE .*dns_records')" 0
	check_eq "403: both old records are still there" "$(mq "sorted(r['type'] for r in $OD)")" "['A', 'AAAA']"
	run_script force-dns-conflict "${fd_args[@]}"
	expect_rc "no failure any more: the conflict (HTTP 400) path deletes the other record and succeeds" 0
	check_eq "after the conflict: one CNAME is left" "$(mq "[r['type'] for r in $OD]")" "['CNAME']"
	check_eq "exactly one record was deleted" "$(calls '^DELETE .*dns_records')" 1

	banner "B4 build path (stand-in for src/hst_autocompile.sh): version, revision, rebuild, dirty tree"
	cat > "$SRC/src/hst_autocompile.sh" << 'STUB'
#!/bin/bash
# test stand-in: records the call and repacks a prebuilt deb with the requested revision
echo "args: $* | BUILD_DIR=$BUILD_DIR DEB_DIR=$DEB_DIR cwd=$(pwd) umask=$(umask)" >> /result/build-calls.txt
rev=1
while [ $# -gt 0 ]; do case "$1" in --pkgrev) rev=$2; shift ;; esac; shift; done
suffix=$(. /etc/os-release && echo "$ID$VERSION_ID")
mkdir -p "$DEB_DIR"
bash /opt/src/test/vylaris-upgrade/repack-deb.sh own /debs/hestia_1.10.5-100+ubuntu24.04_amd64.deb "$DEB_DIR/hestia_1.10.5-${rev}+${suffix}_amd64.deb" "1.10.5-${rev}+${suffix}" > /dev/null
STUB
	(cd "$SRC" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm "stand-in build script")
	: > /result/build-calls.txt
	mock_reset
	# the first DNS record POST is carried out by Cloudflare, but the answer is an HTTP 500
	mock_set '{"fail":[{"method":"POST","contains":"dns_records","status":500,"times":1,"apply":true}]}'
	run_script build-1 --domain "$DOMAIN" --skip-tunnel-service --public --listen-port 8089
	expect_rc "build + publish (and a DNS record that was created although the answer was a 500)" 0
	out_has "DNS POST with a 500 answer: the record is looked for again and found" 'but the record exists'
	check_eq "exactly one DNS record of the domain, ours (no second POST created a duplicate)" "$(mq "len($OD)")" 1
	check_eq "and it is a proxied CNAME to the tunnel" "$(mq "[(r['type'], r['proxied']) for r in $OD]")" "[('CNAME', True)]"
	check "the build ran in a private mktemp directory (not a fixed name)" grep -qE 'BUILD_DIR=/var/tmp/vylarisspace-build\.[A-Za-z0-9]{6}/work ' /result/build-calls.txt
	check "no fixed /var/tmp/vylarisspace-build and no build directory left behind" bash -c "test ! -e /var/tmp/vylarisspace-build && ! ls -d /var/tmp/vylarisspace-build.* 2>/dev/null | grep -q ."
	check_eq "the build script was called once" "$(wc -l < /result/build-calls.txt)" 1
	sed 's/^/    | /' /result/build-calls.txt
	check "the recipe is used: --hestia --noinstall --keepbuild --pkgrev 100 ~localsrc" grep -q -- 'args: --hestia --noinstall --keepbuild --pkgrev 100 ~localsrc ' /result/build-calls.txt
	check "it is run from the checkout" grep -q "cwd=$SRC" /result/build-calls.txt
	check "with the normal umask 0022 (the installer itself runs with 077)" grep -q 'umask=0022' /result/build-calls.txt
	check_eq "published version" "$(reprepro -b $REPO -T deb list "$CODENAME" hestia | awk '{print $NF}')" "1.10.5-100+$suffix"
	run_script build-2 --domain "$DOMAIN" --skip-tunnel-service --public
	expect_rc "second run does not rebuild" 0
	out_has "message: not rebuilt, use --rebuild" 'not rebuilt \(use --rebuild'
	check_eq "the build script was not called again" "$(wc -l < /result/build-calls.txt)" 1
	touch "$SRC/untracked-file.txt"
	run_script build-2-dirty --domain "$DOMAIN" --skip-tunnel-service --public
	expect_rc "already published and nothing to build: an untracked file does not matter (the comparison comes first)" 0
	out_has "build-2-dirty: not rebuilt" 'not rebuilt \(use --rebuild'
	check_eq "build-2-dirty: the build script was not called" "$(wc -l < /result/build-calls.txt)" 1
	rm -f "$SRC/untracked-file.txt"
	run_script build-3 --domain "$DOMAIN" --skip-tunnel-service --rebuild
	expect_rc "--rebuild" 0
	check_eq "the build script was called a second time" "$(wc -l < /result/build-calls.txt)" 2
	check "with the next revision (--pkgrev 101)" grep -q -- '--pkgrev 101 ~localsrc' /result/build-calls.txt
	check_eq "published version is revision 101" "$(reprepro -b $REPO -T deb list "$CODENAME" hestia | awk '{print $NF}')" "1.10.5-101+$suffix"
	touch "$SRC/untracked-file.txt"
	run_script build-untracked --domain "$DOMAIN" --skip-tunnel-service --rebuild
	expect_rc "an untracked file makes the checkout dirty: refused before building" 2
	out_has "untracked file: message" 'untracked files'
	out_has "untracked file: says to commit or move (git add <files>; git commit)" 'git add <files>; git commit'
	check_eq "the build script was not called for the untracked file" "$(wc -l < /result/build-calls.txt)" 2
	rm -f "$SRC/untracked-file.txt"
	echo "# dirty" >> "$SRC/README.md"
	run_script build-dirty --domain "$DOMAIN" --skip-tunnel-service --rebuild
	expect_rc "dirty checkout is refused before building" 2
	out_has "dirty checkout: message" 'uncommitted changes'
	check_eq "the build script was not called for the dirty tree" "$(wc -l < /result/build-calls.txt)" 2
	run_script build-dirty-ok --domain "$DOMAIN" --skip-tunnel-service --rebuild --allow-dirty
	expect_rc "--allow-dirty --rebuild" 0
	check "client text lists both suites now" grep -qE "Serves hestia for.*trixie.*$CODENAME|Serves hestia for.*$CODENAME.*trixie" "$STATE/CLIENT-INSTALL.txt"
	check_eq "published version is revision 102" "$(reprepro -b $REPO -T deb list "$CODENAME" hestia | awk '{print $NF}')" "1.10.5-102+$suffix"
	(cd "$SRC" && git checkout -q README.md)

	banner "B5 the service unit (systemd-analyze verify) with the stub cloudflared"
	run_script service --domain "$DOMAIN" --listen-port 8089 --cloudflared-deb /tmp/cloudflared-stub.deb
	expect_rc "service install (stub cloudflared deb, stub systemctl)" 0
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends systemd > /dev/null 2>&1
	if command -v systemd-analyze > /dev/null; then
		systemd-analyze verify /etc/systemd/system/vylarisspace-tunnel.service > "$OUT/systemd-analyze.txt" 2>&1
		check_eq "systemd-analyze verify of the unit: exit code" "$?" 0
		sed 's/^/    | /' "$OUT/systemd-analyze.txt" | head
	else
		fail "systemd-analyze is not available"
	fi
	sed 's/^/    | /' /etc/systemd/system/vylarisspace-tunnel.service
	banner "B6 the public address does not come up: exit 6 and a clear message; the next run recovers"
	local tid2
	tid2=$(mq "[t['id'] for t in d['tunnels'] if not t['deleted_at']][0]")
	touch /tmp/no-connect
	mock POST /_mock/disconnect "{\"tunnel_id\":\"$tid2\"}" > /dev/null
	systemctl stop vylarisspace-tunnel
	TUNNEL_WAIT=6 VERIFY_WAIT=6 run_script unreachable --domain "$DOMAIN" --listen-port 8089 --cloudflared-deb /tmp/cloudflared-stub.deb
	expect_rc "tunnel never connects" 6
	last_out | grep -E 'warning|normal in the first|Wait a few' | sed 's/^/    | /'
	out_has "tunnel not healthy: warning" 'the tunnel is not healthy after 6s'
	out_has "tunnel not healthy: names the outgoing port 7844 (TCP and UDP)" 'outgoing TCP and UDP port 7844'
	out_has "public address: clear message" 'does not answer correctly yet: https://repo.vylaris.test/dists/.*HTTP 530'
	out_has "public address: says that it takes minutes" 'DNS and the tunnel need a little time'
	out_has "the final line says installed but not reachable yet" 'INSTALLED, BUT NOT REACHABLE YET'
	check "CLIENT-INSTALL.txt was written anyway" test -s "$STATE/CLIENT-INSTALL.txt"
	out_has "unreachable public address: names port 7844 too" 'outgoing TCP and UDP port 7844'
	rm -f /tmp/no-connect
	mock POST /_mock/connect "{\"tunnel_id\":\"$tid2\",\"status\":\"degraded\"}" > /dev/null
	run_script recovered --domain "$DOMAIN" --listen-port 8089 --cloudflared-deb /tmp/cloudflared-stub.deb
	expect_rc "a degraded tunnel (up with reduced redundancy) is a success: the same command ends with 0" 0
	out_has "degraded tunnel: warning that says what it means" 'degraded: it is up with reduced redundancy'
	mock POST /_mock/connect "{\"tunnel_id\":\"$tid2\"}" > /dev/null

	banner "B6b a token that may read but not write DNS: the failure comes late, and the same command resumes"
	mock_reset
	mock_set '{"perms":["tunnel","dns_read","zone"]}'
	run_script dns-read-only --domain "$DOMAIN" --listen-port 8089 --cloudflared-deb /tmp/cloudflared-stub.deb
	expect_rc "DNS Read only: the preflight passes, the DNS POST answers 403" 4
	out_has "dns read-only: names what failed" 'creating the DNS record failed'
	out_has "dns read-only: permission hint" 'Cloudflare refused the API token'
	out_has "dns read-only: says that the same command resumes" 'The run stopped early. Nothing is lost'
	check_eq "left behind: the tunnel (created in step 1) exists" "$(mq "len($OT)")" 1
	check_eq "left behind: its route is set" "$(mq "len(${OT}[0]['ingress'] or [])")" 2
	check_eq "left behind: no DNS record" "$(mq "len($OD)")" 0
	check "left behind: signing key, repository and nginx site are in place" bash -c "test -s $STATE/keys/out/pubkey.asc && test -s $REPO/conf/distributions && test -f /etc/nginx/conf.d/vylarisspace-repo.conf"
	mock_set '{"perms":["tunnel","dns","zone"]}'
	run_script dns-read-only-resume --domain "$DOMAIN" --listen-port 8089 --cloudflared-deb /tmp/cloudflared-stub.deb
	expect_rc "with the permission added, the same command resumes and finishes" 0
	check_eq "the DNS record exists now" "$(mq "[r['type'] for r in $OD]")" "['CNAME']"
	check_eq "still one tunnel" "$(mq "len($OT)")" 1

	banner "B6c the local check fails: exit 5 (a fault of this machine), not 6"
	chmod 600 "$REPO/public/dists/$CODENAME/InRelease"
	run_script local-fail --domain "$DOMAIN" --listen-port 8089 --cloudflared-deb /tmp/cloudflared-stub.deb
	expect_rc "InRelease is not readable by nginx: the local check fails" 5
	out_has "local check: message" 'local check failed: http://127.0.0.1:8089/dists/.*/InRelease answered 403'
	out_has "local check: says that waiting does not help" 'will not fix itself by waiting'
	out_has "local check: the same command resumes" 'The run stopped early. Nothing is lost'
	chmod 644 "$REPO/public/dists/$CODENAME/InRelease"
	run_script local-ok --domain "$DOMAIN" --listen-port 8089 --cloudflared-deb /tmp/cloudflared-stub.deb
	expect_rc "after the fix the same command ends with 0" 0

	banner "B7 token from a file (warning when readable by others), hidden prompt on a terminal, bash -x"
	printf '%s\n' "$GOOD" > /tmp/cf-token
	chmod 644 /tmp/cf-token
	TOK='' run_script tokenfile --status --cf-token-file /tmp/cf-token
	expect_rc "--status with --cf-token-file" 0
	out_has "token file with mode 644: warning" 'readable by others'
	out_has "token from the file works (tunnel status read through the API)" 'tunnel +: vylarisspace-repo .* status healthy'
	chmod 600 /tmp/cf-token
	TOK='' run_script tokenfile2 --status --cf-token-file /tmp/cf-token
	out_has_not "token file with mode 600: no warning" 'readable by others'
	cat > /tmp/pty-run.py << 'PY'
import os, pty, select, sys, time
script, token = sys.argv[1], sys.argv[2]
env = dict(os.environ, VYLARIS_CF_API_BASE="http://127.0.0.1:8787/client/v4")
env.pop("CLOUDFLARE_API_TOKEN", None)
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("bash", ["bash", script, "--status"], env)
buf = b""
sent = False
end = time.time() + 60
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 1)
    if r:
        try:
            d = os.read(fd, 4096)
        except OSError:
            break
        if not d:
            break
        buf += d
        if not sent and b"input is hidden" in buf:
            time.sleep(0.3)
            os.write(fd, token.encode() + b"\n")
            sent = True
os.waitpid(pid, 0)
text = buf.decode(errors="replace")
print(text)
print("PROMPT_SEEN=%s" % ("input is hidden" in text))
print("TOKEN_ECHOED=%s" % (token != "" and token in text))
PY
	python3 /tmp/pty-run.py "$SCRIPT" "$GOOD" > "$OUT/pty.out" 2>&1
	check "the hidden prompt was shown" grep -q 'PROMPT_SEEN=True' "$OUT/pty.out"
	check "the typed token was not echoed to the terminal" grep -q 'TOKEN_ECHOED=False' "$OUT/pty.out"
	check "the status worked with the typed token" grep -qE 'tunnel +: vylarisspace-repo .* status healthy' "$OUT/pty.out"
	check "the prompt says that Enter alone skips the tunnel check" grep -q 'Enter alone skips the tunnel check' "$OUT/pty.out"
	python3 /tmp/pty-run.py "$SCRIPT" "" > "$OUT/pty-enter.out" 2>&1
	check "Enter at the prompt skips the check: 'not checked', and the rest of the status is printed" bash -c "grep -qE 'tunnel +: not checked' $OUT/pty-enter.out && grep -qE 'published +:' $OUT/pty-enter.out"
	CLOUDFLARE_API_TOKEN=$GOOD VYLARIS_CF_API_BASE=http://127.0.0.1:8787/client/v4 bash -x "$SCRIPT" --status > "$OUT/xtrace.out" 2>&1
	check_eq "bash -x --status: exit code" "$?" 0
	check "bash -x: tracing was switched off (note)" grep -q 'shell tracing (bash -x) was switched off' "$OUT/xtrace.out"
	check "bash -x: the token is not in the output" bash -c "! grep -qF '$GOOD' $OUT/xtrace.out"
	check "bash -x: nothing but the first lines were traced" test "$(grep -c '^+' "$OUT/xtrace.out")" -lt 12
	banner "B8 secrets"
	scan_secrets
}

# ================================================================================================
# profile build: the real build
# ================================================================================================
profile_build() {
	banner "BUILD real hst_autocompile.sh build in the container, publish, apt sees it"
	# (only because the CI sandbox has a TLS intercepting proxy whose CA is in the system store: node does not use it)
	export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
	mock_reset
	local t0
	t0=$(date +%s)
	TUNNEL_WAIT=5 run_script real-build --domain "$DOMAIN" --skip-tunnel-service --public
	echo "  (run time $(($(date +%s) - t0)) s)"
	expect_rc "real build and publish" 0
	last_out | grep -E '^(==|  \[|ERROR)' | sed 's/^/    | /'
	tail -n 15 "$LOGF.build" | sed 's/^/    build| /'
	local codename
	codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
	echo "  published: $(reprepro -b $REPO -T deb list "$codename" hestia)"
	echo "  deb in the repository: $(ls -l $REPO/public/pool/main/h/hestia/ 2> /dev/null | tail -n +2)"
	check "the published package has the marker field and the expected version" bash -c "dpkg-deb -f $REPO/public/pool/main/h/hestia/hestia_*.deb Version | grep -q '^1.10.5-100+' && dpkg-deb -f $REPO/public/pool/main/h/hestia/hestia_*.deb Vylaris-Edition | grep -q VylarisSpace"
	check "a hestia package is published" bash -c "reprepro -b $REPO -T deb list \$(. /etc/os-release; echo \$VERSION_CODENAME) hestia | grep -q hestia"
}

# ================================================================================================
# profile cfd: cloudflared from the real Cloudflare apt repository (real network, mock API)
# ================================================================================================
profile_cfd() {
	banner "C1 everything but the service (--skip-tunnel-service)"
	mock_reset
	run_script base --domain "$DOMAIN" --skip-tunnel-service --public --deb "$DEB_A"
	expect_rc "base run" 0

	banner "C2 a fake pkg.cloudflare.com serves a DIFFERENT key: the pinned fingerprint must refuse it"
	echo "127.0.0.2 pkg.cloudflare.com" >> /etc/hosts
	openssl req -newkey rsa:2048 -nodes -subj "/CN=pkg.cloudflare.com" -keyout /etc/ssl/testca/pkg.key -out /etc/ssl/testca/pkg.csr 2> /dev/null
	printf 'subjectAltName=DNS:pkg.cloudflare.com\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > /etc/ssl/testca/ext2.cnf
	openssl x509 -req -in /etc/ssl/testca/pkg.csr -CA /etc/ssl/testca/ca.crt -CAkey /etc/ssl/testca/ca.key -CAcreateserial \
		-days 5 -extfile /etc/ssl/testca/ext2.cnf -out /etc/ssl/testca/pkg.crt 2> /dev/null
	python3 - "$STATE/keys/out/vylarisspace-keyring.gpg" << 'PY' &
import http.server, ssl, sys
data = open(sys.argv[1], "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.2", 443), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/etc/ssl/testca/pkg.crt", "/etc/ssl/testca/pkg.key")
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
	FAKE=$!
	sleep 1
	run_script fake-key --domain "$DOMAIN" --public
	expect_rc "key with another fingerprint" 2
	out_has "refusal message names the expected fingerprint" 'does not have the expected fingerprint .*CC94B39C77AE7342A68B89628A682D308D4E5E73'
	check "no cloudflared source list was written" test ! -e /etc/apt/sources.list.d/cloudflared.list
	check "no Cloudflare keyring was installed" test ! -e /usr/share/keyrings/cloudflare-public-v2.gpg
	check "cloudflared is not installed" bash -c "! command -v cloudflared"
	kill $FAKE 2> /dev/null
	grep -v 'pkg.cloudflare.com' /etc/hosts > /tmp/hosts.new
	cat /tmp/hosts.new > /etc/hosts # (/etc/hosts is a bind mount: no rename)

	banner "C2b key address fallback: cloudflare-public-v2.gpg answers 404, cloudflare-main.gpg has the pinned key"
	curl -fsSL --retry 3 -o /tmp/real-main.gpg https://pkg.cloudflare.com/cloudflare-main.gpg
	check "the real key could be fetched for the fallback test" test -s /tmp/real-main.gpg
	echo "127.0.0.2 pkg.cloudflare.com" >> /etc/hosts
	python3 - /tmp/real-main.gpg << 'PY' &
import http.server, ssl, sys
data = open(sys.argv[1], "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/cloudflare-main.gpg":
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.2", 443), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/etc/ssl/testca/pkg.crt", "/etc/ssl/testca/pkg.key")
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
	FAKE=$!
	sleep 1
	run_script key-fallback --domain "$DOMAIN" --public
	expect_rc "the first key address is gone, the second carries the pinned key: the key is accepted, then apt cannot read the fake repository" 3
	out_has "key taken from the second address" 'Cloudflare package key taken from https://pkg.cloudflare.com/cloudflare-main.gpg'
	check "keyring has exactly the pinned primary key" bash -c "gpg --show-keys --with-colons /usr/share/keyrings/cloudflare-public-v2.gpg | awk -F: '\$1==\"pub\"{p=1;next} p==1&&\$1==\"fpr\"{print \$10;exit}' | grep -qx CC94B39C77AE7342A68B89628A682D308D4E5E73"
	kill $FAKE 2> /dev/null
	grep -v 'pkg.cloudflare.com' /etc/hosts > /tmp/hosts.new
	cat /tmp/hosts.new > /etc/hosts
	rm -f /usr/share/keyrings/cloudflare-public-v2.gpg /etc/apt/sources.list.d/cloudflared.list

	banner "C2c a captive-portal page (HTML, HTTP 200) at the first key address, the real key at the second"
	cat > /tmp/fake-pkg.py << 'PY'
import http.server, ssl, sys
real = open(sys.argv[1], "rb").read()
mode = sys.argv[2]  # html-first: a web page at the first address, the key at the second; html-both: a web page at both
html = b"<html><body>Please log in to the guest network</body></html>"
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/cloudflare-public-v2.gpg" or mode == "html-both":
            data = html
        elif self.path == "/cloudflare-main.gpg":
            data = real
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.2", 443), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/etc/ssl/testca/pkg.crt", "/etc/ssl/testca/pkg.key")
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY
	echo "127.0.0.2 pkg.cloudflare.com" >> /etc/hosts
	python3 /tmp/fake-pkg.py /tmp/real-main.gpg html-first &
	FAKE=$!
	sleep 1
	run_script key-captive --domain "$DOMAIN" --public
	expect_rc "a web page at the first key address does not stop the script: the second address is tried (then apt cannot read the fake repository)" 3
	out_has "the key came from the second address" 'Cloudflare package key taken from https://pkg.cloudflare.com/cloudflare-main.gpg'
	check "keyring has exactly the pinned primary key" bash -c "gpg --show-keys --with-colons /usr/share/keyrings/cloudflare-public-v2.gpg | awk -F: '\$1==\"pub\"{p=1;next} p==1&&\$1==\"fpr\"{print \$10;exit}' | grep -qx CC94B39C77AE7342A68B89628A682D308D4E5E73"
	kill $FAKE 2> /dev/null
	wait $FAKE 2> /dev/null
	rm -f /usr/share/keyrings/cloudflare-public-v2.gpg /etc/apt/sources.list.d/cloudflared.list
	banner "C2d a web page at BOTH key addresses: a message, not a silent stop"
	python3 /tmp/fake-pkg.py /tmp/real-main.gpg html-both &
	FAKE=$!
	sleep 1
	run_script key-html-both --domain "$DOMAIN" --public
	expect_rc "no key at either address (gpg cannot read a web page)" 2
	out_has "refusal message names the expected fingerprint (the script did not stop silently)" 'does not have the expected fingerprint .*CC94B39C77AE7342A68B89628A682D308D4E5E73'
	out_has "and says what was found" 'fingerprint none, 0 key\(s\)'
	check "no cloudflared source list was written" test ! -e /etc/apt/sources.list.d/cloudflared.list
	kill $FAKE 2> /dev/null
	wait $FAKE 2> /dev/null
	grep -v 'pkg.cloudflare.com' /etc/hosts > /tmp/hosts.new
	cat /tmp/hosts.new > /etc/hosts

	banner "C3 the real pkg.cloudflare.com: key checked against the pinned fingerprint, package installed, service unit started"
	TUNNEL_WAIT=8 VERIFY_WAIT=5 run_script real-cloudflared --domain "$DOMAIN" --public
	expect_rc "real cloudflared (the mock tunnel token cannot connect to the real edge): installed, tunnel not healthy" 6
	last_out | grep -E '^(  \[|== Step 6)' | sed 's/^/    | /' | sed -n '/Step 6/,/Step 7/p'
	out_has "cloudflared installed from pkg.cloudflare.com" 'cloudflared [0-9][^ ]* installed from pkg.cloudflare.com \(key CC94 B39C 77AE 7342 A68B 8962 8A68 2D30 8D4E 5E73 '
	check "keyring has exactly the pinned primary key" bash -c "gpg --show-keys --with-colons /usr/share/keyrings/cloudflare-public-v2.gpg | awk -F: '\$1==\"pub\"{p=1;next} p==1&&\$1==\"fpr\"{print \$10;exit}' | grep -qx CC94B39C77AE7342A68B89628A682D308D4E5E73"
	check_eq "the source list" "$(cat /etc/apt/sources.list.d/cloudflared.list)" "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main"
	check "the package comes from pkg.cloudflare.com (apt-cache policy)" bash -c "apt-cache policy cloudflared | grep -q 'pkg.cloudflare.com/cloudflared any/main'"
	echo "  installed: $(dpkg-query -W -f='${Package} ${Version}' cloudflared), binary says: $(cloudflared --version 2> /dev/null | head -n1)"
	check "the real cloudflared binary runs" bash -c "cloudflared --version | grep -qi cloudflared"
	check "service unit was written and started through systemctl (stub)" grep -q 'enable --now vylarisspace-tunnel' "$OUT/systemctl-calls.txt"
	out_has "tunnel not healthy: warning" 'the tunnel is not healthy after 8s'
	out_has "public address not reachable: message" 'does not answer correctly yet'
	if grep -q 'cloudflared --no-autoupdate tunnel run$' "$OUT/ps-samples.txt"; then
		pass "the daemon's command line was exactly: /usr/bin/cloudflared --no-autoupdate tunnel run (seen in the process samples)"
	else
		echo "  (best effort) the process sampler did not catch the real cloudflared command line"
	fi
	banner "C4 secrets"
	scan_secrets
}

setup_environment
case "$PROFILE" in
	a)
		profile_a
		final_checks
		;;
	b)
		profile_b
		final_checks
		;;
	build) profile_build ;;
	cfd) profile_cfd ;;
	*)
		echo "unknown profile $PROFILE"
		exit 2
		;;
esac
kill "$SAMPLER" "$WATCHER" 2> /dev/null
banner "result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
