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

# Global definitions.

# SONARQUBE_BUILD_WRAPPER is the wrapper script needed for SonarQube analysis
# of C projects (https://docs.sonarqube.org/latest/analysis/languages/cfamily/).
SONARQUBE_BUILD_WRAPPER="build-wrapper-linux-x86-64";
# SONARQUBE_WRAPPER_OUTDIR is the directory where the SonarQube build wrapper
# script will write it's output if the build wrapper is used.
SONARQUBE_WRAPPER_OUTDIR=".sonarqube_wrapper_outdir";

# Dependencies on other programs which might not be installed. Here we rely on
# values discovered and passed on by the calling script.
_jq="${_jq:-$(which jq) -er}";

ME="jenkins_build.sh";	# Useful for log messages.

sonar_wrapper="";
sonar_conf="${sonar_conf:-}";
sonar_lang="$(get_dict_key "$sonar_conf" "lang" || true)";
[ -n "$sonar_lang" ] && {
	logmsg "Language set to '$sonar_lang' for SonarQube analysis" "$ME";
	if [ "$sonar_lang" == "c" ] || [ "$sonar_lang" == "C" ]; then
		sonar_wrapper="$(which "$SONARQUBE_BUILD_WRAPPER" || true)";
		if [ -z "$sonar_wrapper" ]; then
			warnmsg "SonarQube wrapper script required for language '$sonar_lang' but missing" "$ME";
		else
			sonar_wrapper="$sonar_wrapper --out-dir $SONARQUBE_WRAPPER_OUTDIR";
		fi
	fi
}

####
#### Build/compilation commands (cmake, make, etc.) taken from the build
#### configuration build_commands variable.
####

# Try to save the current directory so we can restore if after running the build
# commands. Could someone use such a variable name in the build commands ? You
# can never be sure.
____initial_dir="$PWD";

# We need to detect which build commands are `make` (versus other commands like
# `cmake`. For `make` we might need to run them through the SonarQube build
# wrapper.
make_cmd_regexp='^[[:space:]]*make';
# But we don't want to run ALL make commands through the wrapper. This could
# also be '^[[:space:]]*make[[:space:]]+(test|clean)' if we would want to exact.
make_ignore_regexp='(test|clean)';

# Avoid shell check SC2154 `referenced but not assigned` but stil rely on value
# passed on by calling script. If variable is not set by calling script this
# should through an error.
# shellcheck disable=SC2269
build_commands="$build_commands";
build_commands_len="$(echo "$build_commands" | $_jq -c '. | values | length')";
i="0";
while [ "$i" -lt "$build_commands_len" ]; do
	cmd="$(echo "$build_commands" | $_jq -c ". | values | .[$i]"	\
		| grep -Eiv '^[[:blank:]]*null[[:blank:]]*$')";

	[ -n "$cmd" ] && {
		if [[ "$cmd" =~ $make_cmd_regexp ]] && [[ ! "$cmd" =~ $make_ignore_regexp ]]; then
			logmsg "Executing build command #$i '$cmd' through SonarQube build wrapper ..." "$ME";
			eval " $sonar_wrapper $cmd;";
		else
			logmsg "Executing build command #$i '$cmd' ..." "$ME";
			eval " $cmd;";
		fi
	}

	i="$(( i + 1 ))";
done

# Restore working directory if it was changes by build commands.
cd "${____initial_dir}";

# Last iteration through the while will end with $i NOT being lower than length
# hence the last executed command of the script will have a non-zero return
# code.
exit 0;
