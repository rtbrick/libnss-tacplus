#!/usr/bin/env bash

# Fail hard and fast. Exit at the first error or undefined variable.
set -ue;

# Load functions from the jenkins_shell_functions.sh file. This looks for the
# functions file either in the current directory or in the ${__jenkins_scripts_dir}
# or in the ./.jenkins/ sub-directory.
# shellcheck disable=SC1091
__shell_funcs="jenkins_shell_functions.sh";
if [ -f "./$__shell_funcs" ]; then
	# shellcheck source=/dev/null
	. "./$__shell_funcs";
else
	if [ -f "${__jenkins_scripts_dir:-./.jenkins}/$__shell_funcs" ]; then
		# shellcheck source=/dev/null
		. "${__jenkins_scripts_dir:-./.jenkins}/$__shell_funcs";
	fi
fi
jenkins_shell_functions_loaded;

# Since the script will exit at the first error try and print details about the
# command which errored. The trap_debug function is defined in
# jenkins_shell_functions.sh. errtrace is bash specific.
[ "${BASH_VERSION:-0}" != "0" ] && set -o errtrace;
trap 'trap_debug "$?" "$BASH_COMMAND" "$LINENO" "${BASH_SOURCE[0]}"' ERR;

# Print debugging information.
[ "${__global_debug:-0}" -gt "0" ] && {
	echo "DEBUG: environment information:";
	echo "---------------------------------------------------------------";
	env;
	echo "---------------------------------------------------------------";
}
[ "${__global_debug:-0}" -gt "1" ] && {
	set -x;
	# functrace is bash specific.
	[ "${BASH_VERSION:-0}" != "0" ] && set -o functrace;
}

# Dependencies on other programs which might not be installed. Here we rely on
# values discovered and passed on by the calling script.
_apt_get="$(which apt-get)";
_chown="$(which chown)";
_chmod="$(which chmod)";
_dpkg="$(which dpkg)";
_getent="$(which getent)";

ME="jenkins_install_apt_dep.sh";	# Useful for log messages.

pkgs=("$@");

initial_dir="$PWD";
tmp_dir="$(mktemp -d)";
$_getent passwd "_apt" 2>/dev/null 1>/dev/null && {
	$_chown "_apt:root" "$tmp_dir";
	$_chmod "0770" "$tmp_dir";
}
cd "$tmp_dir";

$_apt_get download -yqq "${pkgs[@]}";
for deb in *.deb; do
	logmsg "Installing '$deb'" "$ME";
	$_dpkg --force-depends --force-confnew --force-downgrade -i "$deb";
done

cd "$initial_dir";
rm "$tmp_dir"/*.deb || true;
rmdir "$tmp_dir" || true;
