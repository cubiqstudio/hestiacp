#!/bin/bash
# Unit test for the version step loop of func/upgrade.sh (upgrade_start_routine).
# Needs no server: the real function runs against a fake versions directory.
#
#   test/vylaris-upgrade-unit/upgrade-steps.sh

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Load the real library (it sources syshealth.sh from $HESTIA)
HESTIA="$REPO"
# shellcheck source=func/upgrade.sh
source "$REPO/func/upgrade.sh"

# Point the library at a fake installation
HESTIA="$WORK/hestia"
HESTIA_BACKUP="$WORK/backup"
mkdir -p "$HESTIA/install/upgrade/versions" "$HESTIA_BACKUP"
cp "$REPO/install/upgrade/upgrade.conf" "$HESTIA/install/upgrade/upgrade.conf"

RAN="$WORK/ran.log"
SETV="$WORK/setversion.log"

# Stubs for everything that would touch a server
upgrade_step_message() { :; }
upgrade_refresh_config() { :; }
upgrade_set_version() { echo "$*" >> "$SETV"; }

make_steps() {
	rm -f "$HESTIA"/install/upgrade/versions/*.sh
	for v in "$@"; do
		# Every step logs itself and asks for a rebuild like 1.10.6.sh does
		cat > "$HESTIA/install/upgrade/versions/$v.sh" << STEP
echo "$v" >> "$RAN"
upgrade_config_set_value 'UPGRADE_REBUILD_USERS' 'true'
STEP
	done
}

fails=0
# usage: check NAME VERSION NEW_VERSION EXPECTED_STEPS EXPECTED_REBUILD EXPECTED_SETVERSION
check() {
	local name="$1" installed="$2" package="$3" want_steps="$4" want_rebuild="$5"
	: > "$RAN"
	: > "$SETV"
	rm -f "$HESTIA_BACKUP/upgrade.conf"
	prepare_upgrade_config
	# shellcheck disable=SC2034
	VERSION="$installed"
	# shellcheck disable=SC2034
	new_version="$package"
	upgrade_start_routine > /dev/null
	local got_steps got_rebuild
	got_steps="$(tr '\n' ' ' < "$RAN" | sed 's/ $//')"
	got_rebuild="$(grep -o "UPGRADE_REBUILD_USERS='[a-z]*'" "$HESTIA_BACKUP/upgrade.conf" | cut -d"'" -f2)"
	if [ "$got_steps" = "$want_steps" ] && [ "$got_rebuild" = "$want_rebuild" ]; then
		echo "ok   $name (steps: '${got_steps:-none}', rebuild: $got_rebuild)"
	else
		echo "FAIL $name: steps '$got_steps' (want '$want_steps'), rebuild '$got_rebuild' (want '$want_rebuild')"
		fails=$((fails + 1))
	fi
}

# Tree as shipped: steps up to 1.10.6 present, package base is 1.10.5
make_steps 1.10.4 1.10.5 1.10.6
check "1.10.4 -> package 1.10.5 runs 1.10.5 only" "1.10.4" "1.10.5-100+ubuntu24.04" "1.10.5" "true"
check "1.10.5 -> revision bump 1.10.5-101 runs nothing" "1.10.5" "1.10.5-101+ubuntu24.04" "" "false"
check "1.10.5 -> revision bump 1.10.5-102 runs nothing (again)" "1.10.5" "1.10.5-102+ubuntu24.04" "" "false"
check "1.10.5 -> package 1.10.6 runs 1.10.6 once" "1.10.5" "1.10.6-100+ubuntu24.04" "1.10.6" "true"
check "1.10.6 -> revision bump 1.10.6-101 runs nothing" "1.10.6" "1.10.6-101+ubuntu24.04" "" "false"
check "empty VERSION runs all steps up to the package base" "" "1.10.5-100+ubuntu24.04" "1.10.4 1.10.5" "true"
check "1.10.4 -> 1.10.5 on Ubuntu with dots in the suffix" "1.10.4" "1.10.5-100+ubuntu24.04" "1.10.5" "true"
check "older upstream style upgrade 1.9.0 -> 1.10.5" "1.9.0" "1.10.5-1+debian12" "1.10.4 1.10.5" "true"
check "1.10.5 -> 1.10.6~alpha pre-release runs 1.10.6" "1.10.5" "1.10.6-100+ubuntu24.04~alpha" "1.10.6" "true"
check "1.10.6~alpha -> 1.10.6~alpha re-run of a snapshot runs the step again" "1.10.6~alpha" "1.10.6-101+ubuntu24.04~alpha" "1.10.6" "true"
# VERSION '1.10.5' recorded on a plain revision and the step directory with only newer steps
make_steps 1.10.6
check "only a newer step present, 1.10.5 package: nothing runs" "1.10.5" "1.10.5-101+ubuntu24.04" "" "false"
check "only a newer step present, 1.10.6 package: step runs" "1.10.5" "1.10.6-100+ubuntu24.04" "1.10.6" "true"

# base version helper
for pair in "1.10.5-101+ubuntu24.04|1.10.5" "1.10.5-1+debian12|1.10.5" "1.10.5~alpha|1.10.5" "1.10.5-100+ubuntu24.04~beta|1.10.5" "1.10.5|1.10.5"; do
	in="${pair%%|*}"
	want="${pair##*|}"
	got="$(upgrade_base_version "$in")"
	if [ "$got" = "$want" ]; then
		echo "ok   upgrade_base_version $in -> $got"
	else
		echo "FAIL upgrade_base_version $in -> $got (want $want)"
		fails=$((fails + 1))
	fi
done

if [ "$fails" -eq 0 ]; then
	echo "All checks passed."
else
	echo "$fails check(s) failed."
	exit 1
fi
