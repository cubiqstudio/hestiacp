#!/bin/bash

# ======================================================== #
#
# VylarisSpace Installation Routine
# Automatic OS detection wrapper
# VylarisGroupEurope
#
# NOTE: the OS specific installer (hst-install-<distro>.sh, next to this
# script) installs the panel package from the own VylarisSpace package
# repository. The repository is chosen by the owner, there is no default:
#
#   bash hst-install.sh --vylaris-repo https://<host>/<path> \
#        --vylaris-key-fingerprint <40 hex digits> [options]
#   (or env VYLARIS_REPO_URL, VYLARIS_REPO_KEY_FPR, VYLARIS_REPO_KEY, VYLARIS_REPO_AUTH)
#   The fingerprint of the primary key is required for a key that is downloaded
#   (gpg --show-keys --with-fingerprint pubkey.asc, on the owner's machine). The
#   repository must be https:// (--allow-insecure-http for tests only).
#   bash hst-install.sh --with-debs <dir with hestia_*.deb> [options]
#
# Without a package source the installer stops before it changes anything
# (see VYLARIS-PACKAGING.md). Nothing is downloaded from upstream here.
#
# Currently Supported Operating Systems:
#
# Debian 12, 13
# Ubuntu 22.04, 24.04 26.04 LTS
#
# ======================================================== #

# Repository credentials must never reach a trace: when the shell traces (bash -x, set -x) and
# credentials may be present (environment or option -A / --vylaris-repo-auth), tracing is
# switched off for the whole run.
case $- in
	*x*)
		set +x
		vyl_trace='on'
		[ -z "${VYLARIS_REPO_AUTH:-}" ] || vyl_trace='off'
		for vyl_a in "$@"; do
			case "$vyl_a" in
				--vylaris-repo-auth | --vylaris-repo-auth=* | -*A*) vyl_trace='off' ;;
			esac
		done
		if [ "$vyl_trace" = 'on' ]; then
			set -x
		else
			echo "Note: tracing (set -x) is switched off, repository credentials are in use." >&2
		fi
		unset vyl_a vyl_trace
		;;
esac

# Am I root?
if [ "x$(id -u)" != 'x0' ]; then
	echo 'Error: this script can only be executed by root'
	exit 1
fi

# Package source: stop early (before anything is changed) when none was given.
# The OS specific installer checks and validates it again.
has_package_source() {
	local arg
	[ -n "${VYLARIS_REPO_URL:-}" ] && return 0
	for arg in "$@"; do
		case "$arg" in
			--vylaris-repo | --with-debs | --allow-upstream-hestia | -D | -R | -U) return 0 ;;
		esac
	done
	return 1
}

if ! has_package_source "$@"; then
	echo -e "\e[91mInstallation aborted\e[0m"
	echo "===================================================================="
	echo "No VylarisSpace package source was given, nothing has been changed."
	echo
	echo "Without it the upstream HestiaCP interface would be installed."
	echo "Use one of:"
	echo "  --vylaris-repo <url>     VylarisSpace package repository, https:// (or env VYLARIS_REPO_URL)"
	echo "                           with --vylaris-key-fingerprint <fingerprint of the primary key> (or env"
	echo "                           VYLARIS_REPO_KEY_FPR), required unless --vylaris-key is a local file"
	echo "  --with-debs <dir>        directory with hestia_*.deb built from this source"
	echo "  --allow-upstream-hestia  developers only: install the UPSTREAM hestia package"
	exit 1
fi

# The admin user/group checks below can be skipped with -f/--force. They used to be skipped
# by any argument, which would now always be the case (a package source is required).
force_requested() {
	local arg
	for arg in "$@"; do
		case "$arg" in
			-f | --force) return 0 ;;
		esac
	done
	return 1
}

# Check admin user account
if [ ! -z "$(grep ^admin: /etc/passwd)" ] && ! force_requested "$@"; then
	echo "Error: user admin exists"
	echo
	echo 'Please remove admin user before proceeding.'
	echo 'If you want to do it automatically run installer with -f option:'
	echo "Example: bash $0 --force"
	exit 1
fi

# Check admin group
if [ ! -z "$(grep ^admin: /etc/group)" ] && ! force_requested "$@"; then
	echo "Error: group admin exists"
	echo
	echo 'Please remove admin group before proceeding.'
	echo 'If you want to do it automatically run installer with -f option:'
	echo "Example: bash $0 --force"
	exit 1
fi

# Detect OS
if [ -e "/etc/os-release" ] && [ ! -e "/etc/redhat-release" ]; then
	type=$(grep "^ID=" /etc/os-release | cut -f 2 -d '=')
	if [ "$type" = "ubuntu" ]; then
		# Check if lsb_release is installed
		if [ -e '/usr/bin/lsb_release' ]; then
			release="$(lsb_release -s -r)"
			VERSION='ubuntu'
		else
			echo "lsb_release is currently not installed, please install it:"
			echo "apt-get update && apt-get install lsb-release"
			exit 1
		fi
	elif [ "$type" = "debian" ]; then
		release=$(cat /etc/debian_version | grep -o "[0-9]\{1,2\}" | head -n1)
		VERSION='debian'
	else
		type="NoSupport"
	fi
else
	type="NoSupport"
fi

no_support_message() {
	echo "****************************************************"
	echo "Your operating system (OS) is not supported by"
	echo "VylarisSpace. Officially supported releases:"
	echo "****************************************************"
	echo "  Debian 12, 13"
	echo "  Ubuntu 22.04, 24.04, 26.04 LTS"
	echo ""
	exit 1
}

if [ "$type" = "NoSupport" ]; then
	no_support_message
fi

ensure_utf8_locale() {
	local locale_file="/etc/default/locale"

	if locale | grep -qi 'utf-8'; then
		return
	fi

	echo "[ * ] Enabling UTF-8 locale support via C.UTF-8"
	if ! locale-gen C.UTF-8; then
		echo "[ ! ] Failed to generate C.UTF-8 locale. Leaving existing locale untouched."
		return
	fi

	if ! update-locale LANG=C.UTF-8; then
		echo "[ ! ] Failed to update LANG in $locale_file. Leaving existing locale untouched."
		return
	fi

	export LANG=C.UTF-8
}

ensure_utf8_locale

run_os_installer() {
	# Only the OS specific installer that ships next to this script is used.
	# It is never downloaded from the upstream HestiaCP repository.
	if [ -n "${BASH_SOURCE[0]}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
		local_installer="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hst-install-$type.sh"
		if [ -f "$local_installer" ]; then
			bash "$local_installer" "$@"
			exit
		fi
	fi

	echo "Error: hst-install-$type.sh was not found next to this script."
	echo "Use the complete install directory of the VylarisSpace source or release archive"
	echo "(install/hst-install.sh together with install/hst-install-$type.sh) and run:"
	echo "  bash install/hst-install.sh --vylaris-repo https://<host>/<path>"
	echo "The installer is not downloaded from the upstream HestiaCP repository."
	exit 1
}

# Check for supported operating system before proceeding with the
# OS-specific installer, and throw error message if unsupported OS detected.
if [[ "$release" =~ ^(12|13|22.04|24.04|26.04)$ ]]; then
	run_os_installer "$@"
else
	no_support_message
fi

exit
