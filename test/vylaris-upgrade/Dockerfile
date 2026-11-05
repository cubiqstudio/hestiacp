# Base image of the VylarisSpace upgrade test: Ubuntu 24.04 with systemd as PID 1.
# It is the "server" (a real installer run, then the upgrade); no web server, mail or
# database package may be in it, the Hestia installer refuses to run on top of them;
# the "repo" container is built FROM it (Dockerfile.repo).
# Built by run.sh. extra-ca/ holds optional CA certificates that must be trusted by the
# image (needed behind a TLS intercepting proxy, as in the CI sandbox this was written in).
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
COPY extra-ca/ /tmp/extra-ca/
RUN set -e; \
	sed -i 's#http://#https://#' /etc/apt/sources.list.d/ubuntu.sources; \
	opt=""; \
	if ls /tmp/extra-ca/*.crt > /dev/null 2>&1; then cat /tmp/extra-ca/*.crt > /tmp/extra-all.pem; opt="-o Acquire::https::CaInfo=/tmp/extra-all.pem"; fi; \
	apt-get $opt update; \
	apt-get $opt install -y --no-install-recommends ca-certificates; \
	if ls /tmp/extra-ca/*.crt > /dev/null 2>&1; then \
		mkdir -p /usr/local/share/ca-certificates/extra; \
		awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++; f=sprintf("/usr/local/share/ca-certificates/extra/c%04d.crt", n)} f{print > f} /END CERTIFICATE/{close(f); f=""}' /tmp/extra-ca/*.crt; \
		update-ca-certificates; \
	fi; \
	apt-get install -y --no-install-recommends systemd systemd-sysv dbus curl wget gnupg lsb-release \
		strace iproute2 procps openssl psmisc less file xz-utils sudo cron; \
	rm -rf /var/lib/apt/lists/* /tmp/extra-ca /tmp/extra-all.pem; \
	systemctl mask systemd-resolved.service systemd-timesyncd.service systemd-networkd.service \
		systemd-networkd-wait-online.service getty.target console-getty.service \
		systemd-logind.service apt-daily.timer apt-daily-upgrade.timer || true
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
