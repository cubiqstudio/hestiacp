#!/usr/bin/env bash
# run.sh - test the VylarisSpace repository host installer (src/vylaris/setup-repo-host.sh) in Docker
# against a mock of the Cloudflare API. Cloudflare itself is NOT contacted.
#
# Usage: run.sh [options]
#   --image BASE     ubuntu:24.04 (default), ubuntu:22.04, debian:12
#   --profile NAME   a (default): error cases, full run, idempotency, auth, client, secrets, uninstall
#                    b: --force-dns, --skip-tunnel-service, --public, --staging, port and nginx rollback,
#                       the build path with a stand-in for hst_autocompile.sh
#                    cfd: cloudflared from the REAL pkg.cloudflare.com (key pinned; a fake server must be refused)
#                    build: the REAL package build (hst_autocompile.sh) inside the container
#   --debs DIR       directory with hestia_*-100+ubuntu24.04_amd64.deb and the -101 one. Default
#                    /tmp/vylaris-upgrade-test/debs, else they are built with
#                    test/vylaris-upgrade/build-debs.sh (needs Ubuntu 24.04, node, composer).
#   --result DIR     where the logs go. Must not exist or be empty (nothing is ever deleted there).
#                    Default: a new directory from mktemp -d under /tmp (its name is printed).
# Needs a running Docker daemon. VYLARIS_TEST_EXTRA_CA: PEM file with CA certificates the image must
# trust (default /root/.ccr/ca-bundle.crt when it exists).
# Exit status: 0 all checks passed, 1 a check failed, 2 the test could not run.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
base='ubuntu:24.04'
profile='a'
debs=''
result=''
while [ $# -gt 0 ]; do
	case "$1" in
		--image)
			base=$2
			shift 2
			;;
		--profile)
			profile=$2
			shift 2
			;;
		--debs)
			debs=$2
			shift 2
			;;
		--result)
			result=$2
			shift 2
			;;
		*)
			sed -n '2,/^set -euo/p' "$0" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'
			exit 2
			;;
	esac
done
tag_image=$(echo "$base" | tr ':/' '--')
if [ -z "$result" ]; then
	result=$(mktemp -d "/tmp/vylaris-repo-host-test.$profile-$tag_image.XXXXXX")
elif [ -e "$result" ] && { [ ! -d "$result" ] || [ -n "$(ls -A "$result")" ]; }; then
	echo "run.sh: --result $result exists and is not an empty directory. The runner deletes nothing: choose a new or empty directory." >&2
	exit 2
fi
debs=${debs:-/tmp/vylaris-upgrade-test/debs}
if ! ls "$debs"/hestia_*-100+ubuntu24.04_amd64.deb "$debs"/hestia_*-101+ubuntu24.04_amd64.deb > /dev/null 2>&1; then
	echo "run.sh: building the test packages (test/vylaris-upgrade/build-debs.sh)"
	"$root/test/vylaris-upgrade/build-debs.sh" "$root" "${debs%/debs}/build" "$debs"
fi
debs=$(cd "$debs" && pwd)

mkdir -p "$result"
tag="vylaris-repohost-test:$tag_image"
ctx=$(mktemp -d)
trap 'rm -rf "$ctx"' EXIT
mkdir -p "$ctx/extra-ca"
ca=${VYLARIS_TEST_EXTRA_CA:-/root/.ccr/ca-bundle.crt}
[ -f "$ca" ] && cp "$ca" "$ctx/extra-ca/extra.crt"
cp "$here/Dockerfile" "$ctx/"
docker build -q -t "$tag" --build-arg "BASE=$base" "$ctx" > /dev/null

# The checkout under test (tracked + untracked files, not ignored), as one tar file.
(cd "$root" && git ls-files -z --cached --others --exclude-standard | tar --null -T - -cf "$result/src.tar" 2> /dev/null)

name="vyl-repohost-$profile-$$"
set +e
docker run --rm --name "$name" \
	-v "$here:/test:ro" -v "$debs:/debs:ro" -v "$result:/result" \
	-e "PROFILE=$profile" -e "IMAGE=$base" \
	"$tag" bash /test/guest.sh 2>&1 | tee "$result/guest.log"
rc=${PIPESTATUS[0]}
set -e
echo "result files: $result"
exit "$rc"
