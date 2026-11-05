# Test image of the repository host installer test: a plain Debian/Ubuntu with only what the TEST needs
# (python3 for the Cloudflare mock, openssl for the throw-away test CA, git for the checkout copy).
# Everything the installer needs (nginx, reprepro, curl, jq, gnupg, ...) is deliberately NOT in the
# image: setup-repo-host.sh installs it, like on a fresh server. Built by run.sh.
# extra-ca/ holds optional CA certificates (needed behind a TLS intercepting proxy).
ARG BASE=ubuntu:24.04
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive
COPY extra-ca/ /tmp/extra-ca/
RUN set -e; \
	apt-get update; \
	apt-get install -y --no-install-recommends ca-certificates python3 openssl git procps; \
	if ls /tmp/extra-ca/*.crt > /dev/null 2>&1; then \
		mkdir -p /usr/local/share/ca-certificates/extra; \
		awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++; f=sprintf("/usr/local/share/ca-certificates/extra/c%04d.crt", n)} f{print > f} /END CERTIFICATE/{close(f); f=""}' /tmp/extra-ca/*.crt; \
		update-ca-certificates; \
	fi; \
	rm -rf /var/lib/apt/lists/* /tmp/extra-ca
