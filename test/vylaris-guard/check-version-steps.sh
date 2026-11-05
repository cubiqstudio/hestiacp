#!/usr/bin/env bash
# check-version-steps.sh - the highest upgrade step must not be newer than the package version.
#
# install/upgrade/versions/X.sh runs on a server whose recorded VERSION is below X. The package
# version is the Version field of src/deb/hestia/control. If an upstream release is merged
# (it brings a new X.sh) without raising that field, every server runs the step of a release
# that does not exist yet, on every own update. This check fails in that case.
#
# func/upgrade.sh caps the steps at the package version, so a newer step stays dormant and does no
# harm. The check reports it as a NOTICE (exit 0) so that it is visible in CI; with --strict it
# fails (use it for release builds).
#
# Usage: check-version-steps.sh [--strict] [repo-root]
# Exit:  0 ok (or notice), 1 --strict and a step is newer than the package version, 2 the check could not run.
set -euo pipefail

strict=no
if [ "${1:-}" = "--strict" ]; then
	strict=yes
	shift
fi
root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
control="$root/src/deb/hestia/control"
steps="$root/install/upgrade/versions"

[ -f "$control" ] || {
	echo "check-version-steps: $control not found" >&2
	exit 2
}
[ -d "$steps" ] || {
	echo "check-version-steps: $steps not found" >&2
	exit 2
}

base=$(sed -n 's/^Version:[[:space:]]*//p' "$control" | head -n1)
base=${base%%~*}
[[ "$base" =~ ^[0-9]+(\.[0-9]+)*$ ]] || {
	echo "check-version-steps: cannot read a version from $control (got '$base')" >&2
	exit 2
}

highest=''
bad=()
for f in "$steps"/*.sh; do
	[ -e "$f" ] || continue
	v=$(basename "$f" .sh)
	[[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
	if [ -z "$highest" ] || [ "$(printf '%s\n%s\n' "$highest" "$v" | sort -V | tail -n1)" = "$v" ]; then
		highest=$v
	fi
	if [ "$(printf '%s\n%s\n' "$base" "$v" | sort -V | tail -n1)" != "$base" ]; then
		bad+=("$v.sh")
	fi
done

if [ -z "$highest" ]; then
	echo "check-version-steps: no step scripts found in $steps" >&2
	exit 2
fi

if [ "${#bad[@]}" -gt 0 ]; then
	echo "NOTICE: package version in src/deb/hestia/control is $base, but install/upgrade/versions has newer steps: ${bad[*]}" >&2
	echo "        They stay dormant (func/upgrade.sh caps the steps at the package version) until release $highest is merged" >&2
	echo "        and Version in src/deb/hestia/control is raised to $highest." >&2
	[ "$strict" = yes ] && exit 1
	exit 0
fi
echo "OK: highest upgrade step $highest <= package version $base"
