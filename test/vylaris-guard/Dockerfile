# Test image of the package guard test: a plain Debian/Ubuntu with the dependencies of the hestia
# package pre-installed, so the test itself needs no network. Built by run.sh.
# extra-ca/ holds optional CA certificates (needed behind a TLS intercepting proxy).
ARG BASE=ubuntu:24.04
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive
COPY extra-ca/ /tmp/extra-ca/
RUN set -e; \
	printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d; chmod +x /usr/sbin/policy-rc.d; \
	opt=""; \
	if ls /tmp/extra-ca/*.crt > /dev/null 2>&1; then cat /tmp/extra-ca/*.crt > /tmp/extra-all.pem; opt="-o Acquire::https::CaInfo=/tmp/extra-all.pem"; fi; \
	sed -i 's#http://#https://#' /etc/apt/sources.list.d/*.sources /etc/apt/sources.list 2> /dev/null || true; \
	apt-get $opt update; \
	apt-get $opt install -y --no-install-recommends ca-certificates; \
	apt-get $opt install -y --no-install-recommends acl sysstat zstd lsb-release idn2 jq bubblewrap at rsync \
		dpkg-dev apt-utils procps file; \
	rm -rf /var/lib/apt/lists/* /tmp/extra-ca /tmp/extra-all.pem
