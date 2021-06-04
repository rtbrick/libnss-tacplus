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
_rtb_itool="$(which rtb-itool)";

ME="jenkins_resolve_apt_dep.sh";	# Useful for log messages.

# Verify if must have variables are passed on from the calling script as
# environment variables.
GITLAB_TOKEN="${GITLAB_TOKEN:-}"; export GITLAB_TOKEN;
BRANCH_SANITIZED="$BRANCH_SANITIZED";
pkg_name="$pkg_name";
pkg_group="$pkg_group";

source_etc_os_release;
# Get distribution and release from the environment (initially from build conf)
# or rely on host OS values.
pkg_distribution="${pkg_distribution:-$OS_RELEASE_ID}";
pkg_release="${pkg_release:-$OS_RELEASE_VERSION_CODENAME}";

$_rtb_itool pkg resolve --as-deb-dep --bubble --latest	\
	--version "$BRANCH_SANITIZED"			\
	--pkg-distribution "$pkg_distribution"		\
	--pkg-release "$pkg_release"			\
	--pkg-group "$pkg_group"			\
	"$@";
