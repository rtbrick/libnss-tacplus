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
_jq="$_jq";

ME="jenkins_build.sh";	# Useful for log messages.

####
#### Build/compilation commands (cmake, make, etc.) taken from the build
#### configuration build_commands variable.
####

# Avoid shell check SC2154 `referenced but not assigned` but stil rely on value
# passed on by calling script. If variable is not set by calling script this
# should through an error.
build_commands="$build_commands";
build_commands_len="$(echo "$build_commands" | $_jq -c '. | values | length')";
i="0";
while [ "$i" -lt "$build_commands_len" ]; do
	cmd="$(echo "$build_commands" | $_jq -c ". | values | .[$i]"	\
		| grep -Eiv '^[[:blank:]]*null[[:blank:]]*$')";

	[ -n "$cmd" ] && {
		logmsg "Executing build command #$i '$cmd' ..." "$ME";
		eval "$cmd";
	}

	i="$(( i + 1 ))";
done

# Last iteration through the while will end with $i NOT being lower than length
# hence the last executed command of the script will have a non-zero return
# code.
exit 0;
