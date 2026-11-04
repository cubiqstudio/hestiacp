#!/bin/bash

# ======================================================== #
#
# VylarisSpace Installation Routine
# Automatic OS detection wrapper
# VylarisGroupEurope
#
# NOTE: the OS specific installer started from here still installs the
# hestia packages from the upstream HestiaCP apt repository. Do not use it
# on production servers until the own VylarisSpace package repository exists
# (see VYLARIS-PACKAGING.md).
#
# Currently Supported Operating Systems:
#
# Debian 12, 13
# Ubuntu 22.04, 24.04 26.04 LTS
#
# ======================================================== #

# Am I root?
if [ "x$(id -u)" != 'x0' ]; then
	echo 'Error: this script can only be executed by root'
	exit 1
fi

# Check admin user account
if [ ! -z "$(grep ^admin: /etc/passwd)" ] && [ -z "$1" ]; then
	echo "Error: user admin exists"
	echo
	echo 'Please remove admin user before proceeding.'
	echo 'If you want to do it automatically run installer with -f option:'
	echo "Example: bash $0 --force"
	exit 1
fi

# Check admin group
if [ ! -z "$(grep ^admin: /etc/group)" ] && [ -z "$1" ]; then
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

check_wget_curl() {
	# Prefer the OS specific installer that ships next to this script
	if [ -n "${BASH_SOURCE[0]}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
		local_installer="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hst-install-$type.sh"
		if [ -f "$local_installer" ]; then
			bash "$local_installer" "$@"
			exit
		fi
	fi

	# Fallback: download the OS specific installer (still the upstream source, Phase 4)
	echo -e "\e[91mWARNING: hst-install-$type.sh was not found next to this script and is downloaded from the upstream HestiaCP repository\e[0m"

	# Check wget
	if [ -e '/usr/bin/wget' ]; then
		wget -q https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install-$type.sh -O hst-install-$type.sh
		if [ "$?" -eq '0' ]; then
			bash hst-install-$type.sh "$@"
			exit
		else
			echo "Error: hst-install-$type.sh download failed."
			exit 1
		fi
		# fi
	fi

	# Check curl
	if [ -e '/usr/bin/curl' ]; then
		curl -s -O https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install-$type.sh
		if [ "$?" -eq '0' ]; then
			bash hst-install-$type.sh "$@"
			exit
		else
			echo "Error: hst-install-$type.sh download failed."
			exit 1
		fi
		# fi
	fi
}

# Check for supported operating system before proceeding with download
# of OS-specific installer, and throw error message if unsupported OS detected.
if [[ "$release" =~ ^(12|13|22.04|24.04|26.04)$ ]]; then
	check_wget_curl "$@"
else
	no_support_message
fi

exit
