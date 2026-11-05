#!/bin/bash
# Runs all unit tests of this folder in a throw-away ubuntu:24.04 container (no server needed).
#
#   test/vylaris-upgrade-unit/run-in-docker.sh
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec docker run --rm -v "$REPO:/repo:ro" ubuntu:24.04 bash -c '
rc=0
for t in /repo/test/vylaris-upgrade-unit/*.sh; do
	case "$t" in */run-in-docker.sh) continue ;; esac
	echo "=== $(basename "$t")"
	bash "$t" || rc=1
done
exit $rc'
