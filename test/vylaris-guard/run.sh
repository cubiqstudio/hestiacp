#!/usr/bin/env bash
# run.sh - run the package guard test (guest.sh) in a Docker container.
#
# Usage: run.sh [--image BASE] [--debs DIR] [--no-build-image]
#   --image BASE   base image: ubuntu:24.04 (default), ubuntu:22.04, debian:12
#   --debs DIR     directory with the two VylarisSpace packages built from this tree:
#                  hestia_*-100*.deb (older) and hestia_*-101*.deb (newer). They are made by
#                  test/vylaris-upgrade/build-debs.sh <checkout> <work> <out>.
# Needs a running Docker daemon. VYLARIS_TEST_EXTRA_CA: PEM file with CA certificates the image
# must trust (default /root/.ccr/ca-bundle.crt when it exists).
# Exit status: 0 all checks passed, 1 a check failed, 2 the test could not run.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
base='ubuntu:24.04'
debs=''
build_image=1
while [ $# -gt 0 ]; do
	case "$1" in
		--image)
			base=$2
			shift 2
			;;
		--debs)
			debs=$2
			shift 2
			;;
		--no-build-image)
			build_image=0
			shift
			;;
		*)
			sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'
			exit 2
			;;
	esac
done
[ -n "$debs" ] && [ -d "$debs" ] || {
	echo "run.sh: --debs DIR is required" >&2
	exit 2
}
debs=$(cd "$debs" && pwd)
old=$(ls "$debs"/hestia_*-100+*.deb 2> /dev/null | head -n1 || true)
new=$(ls "$debs"/hestia_*-101+*.deb 2> /dev/null | head -n1 || true)
[ -f "$old" ] && [ -f "$new" ] || {
	echo "run.sh: $debs needs hestia_*-100+*.deb and hestia_*-101+*.deb" >&2
	exit 2
}

tag="vylaris-guard-test:$(echo "$base" | tr ':/' '--')"
if [ "$build_image" -eq 1 ]; then
	ctx=$(mktemp -d)
	trap 'rm -rf "$ctx"' EXIT
	mkdir -p "$ctx/extra-ca"
	ca=${VYLARIS_TEST_EXTRA_CA:-/root/.ccr/ca-bundle.crt}
	[ -f "$ca" ] && cp "$ca" "$ctx/extra-ca/extra.crt"
	cp "$here/Dockerfile" "$ctx/"
	docker build -q -t "$tag" --build-arg "BASE=$base" "$ctx" > /dev/null
fi

docker run --rm -v "$here/guest.sh:/guest.sh:ro" -v "$old:/debs/own-old.deb:ro" -v "$new:/debs/own-new.deb:ro" \
	-v "$here/../../bin/v-check-package-source:/src/v-check-package-source:ro" "$tag" bash /guest.sh
