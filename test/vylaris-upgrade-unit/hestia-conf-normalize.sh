#!/bin/bash
# Unit test for syshealth_normalize_config_file (used by syshealth_repair_system_config):
# values with '#', '=', '&', '|', backslash and spaces must stay byte-exact, comment
# lines pass through, duplicated keys are merged. Needs no server.
#
#   test/vylaris-upgrade-unit/hestia-conf-normalize.sh

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck disable=SC2034
HESTIA="$REPO"
# shellcheck source=func/syshealth.sh
source "$REPO/func/syshealth.sh"

fails=0
expect_equal() {
	if cmp -s "$2" "$3"; then
		echo "ok   $1"
	else
		echo "FAIL $1"
		diff "$2" "$3" | sed 's/^/     /'
		fails=$((fails + 1))
	fi
}

# 1. A realistic file with special values: it must come out byte-identical
cat > "$WORK/special.conf" << 'CONF'
# Do not edit this comment line
   # indented comment
WEB_SYSTEM='nginx'
SERVER_SMTP_PASSWD='pa#ss'
SERVER_SMTP_USER='mailer'
APP_NAME='My #1 Panel = best & fast | cheap \ stuff'
TITLE='Hosting - a=b'
FROM_NAME='Support #team'
SUBJECT_EMAIL='[#{host}] Alert & more'
EMPTY_VALUE=''
SPACES='  keep  inner  spaces  '
SLASHES='a/b|c&d\1\&'
CONF
syshealth_normalize_config_file "$WORK/special.conf" "$WORK/special.out"
expect_equal "special values and comment lines are byte-exact" "$WORK/special.conf" "$WORK/special.out"

# 2. Duplicates: last value wins, position of the first one is kept, values with | & \ are safe
cat > "$WORK/dup.conf" << 'CONF'
# comment
A='one'
B='keep'
A='two | & \ # end'
C='x'
B='keep'
CONF
cat > "$WORK/dup.expected" << 'CONF'
# comment
A='two | & \ # end'
B='keep'
C='x'
CONF
syshealth_normalize_config_file "$WORK/dup.conf" "$WORK/dup.out"
expect_equal "duplicate keys are merged, last value wins" "$WORK/dup.expected" "$WORK/dup.out"

# 3. Unquoted values and trailing spaces are normalised as before, a missing final newline is handled
printf "X=plain\nY='quoted'   \nZ='last'" > "$WORK/odd.conf"
printf "X='plain'\nY='quoted'\nZ='last'\n" > "$WORK/odd.expected"
syshealth_normalize_config_file "$WORK/odd.conf" "$WORK/odd.out"
expect_equal "unquoted value, trailing spaces, no final newline" "$WORK/odd.expected" "$WORK/odd.out"

# 4. Second run does not change anything (idempotent), so no repair is reported on a healthy file
syshealth_normalize_config_file "$WORK/dup.out" "$WORK/dup.out2"
expect_equal "idempotent" "$WORK/dup.out" "$WORK/dup.out2"

# 5. A line without a key must not abort the function; the line is kept as it is
printf "=x\nB='2'\n" > "$WORK/nokey.conf"
if syshealth_normalize_config_file "$WORK/nokey.conf" "$WORK/nokey.out" 2> /dev/null; then
	expect_equal "line without a key is kept, rest is normalised" "$WORK/nokey.conf" "$WORK/nokey.out"
else
	echo "FAIL a line without a key aborted the function"
	fails=$((fails + 1))
fi

if [ "$fails" -eq 0 ]; then
	echo "All checks passed."
else
	echo "$fails check(s) failed."
	exit 1
fi
