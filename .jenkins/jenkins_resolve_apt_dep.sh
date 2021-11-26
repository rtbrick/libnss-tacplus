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

# Dependencies on other programs which might not be installed. Here we might
# rely on values discovered and passed on by the calling script.
_rtb_itool="${_rtb_itool:-$(command -v rtb-itool)}";
_rtb_itool_pkg_resolve="$_rtb_itool pkg resolve";
_jq="${_jq:-$(command -v jq) -er}";

ME="jenkins_resolve_apt_dep.sh";	# Useful for log messages.

# Verify first CLI flag.
[ "_${1:-}" == "_--with-dev" ] && {
	_rtb_itool_pkg_resolve="$_rtb_itool_pkg_resolve --with-dev";
	shift;
}

# Get dependencies JSON array.  
deps_json="${1:-}";
[ -z "$deps_json" ] && { die "Dependencies CLI argument cannot be empty."; }
deps_len="$(echo "$deps_json" | $_jq -c '. | values | length')";
[ "$deps_len" -lt "1" ] && { die "Dependencies JSON array cannot be empty."; }

# Verify if must have variables are passed on from the calling script as
# environment variables. This will fail if a environment variable is not set.
# shellcheck disable=SC2269
GITLAB_TOKEN="$GITLAB_TOKEN";
# shellcheck disable=SC2269
BRANCH_SANITIZED="$BRANCH_SANITIZED";
# shellcheck disable=SC2269
pkg_name="$pkg_name";
# shellcheck disable=SC2269
pkg_group="$pkg_group";

source_etc_os_release;
# Get distribution and release from the environment (initially from build conf)
# or rely on host OS values.
pkg_distribution="${pkg_distribution:-$OS_RELEASE_ID}";
pkg_release="${pkg_release:-$OS_RELEASE_VERSION_CODENAME}";

declare -a deps_to_be_resolved=();
declare -a result=();
i="0";
while [ "$i" -lt "$deps_len" ]; do
	dep="$(echo "$deps_json" | $_jq ".[$i]")";

	# Check if this is an rtbrick package dependency
	# or not.
	case "$dep" in
		*:::rtbrick-*)
			pkg_group_override="$(echo "$dep" | sed -E 's/^([^:]+):::(.+)$/\1/g')";
			dep="$(echo "$dep" | sed -E 's/^([^:]+):::(.+)$/\2/g')";

			if [ -z "$pkg_group_override" ] || [ -z "$dep" ]; then
				die "In pkg group override case: pkg_group_override='$pkg_group_override' dep='$dep'";
			fi

			dep_resolved="$($_rtb_itool_pkg_resolve --as-deb-dep	\
				--bubble --latest				\
				--version "$BRANCH_SANITIZED"			\
				--pkg-distribution "$pkg_distribution"		\
				--pkg-release "$pkg_release"			\
				--pkg-group "$pkg_group_override"		\
				"$dep")";

			for d in $dep_resolved; do
				logmsg "rtbrick package dependency with pkg group override '$pkg_group_override' resolved to: [$d]"  "$ME";
				result+=("$d");
			done
		;;

		rtbrick-*)
			deps_to_be_resolved+=("$dep");
		;;

		*)
			# We treat any non rtbrick- packages as passthrough and
			# will try to install them later with the usual APT tooling.
			# shellcheck disable=SC2206
			result+=("$dep");
		;;
	esac

	i="$(( i + 1 ))";
done

deps_resolved="";
[ "${#deps_to_be_resolved[@]}" -gt "0" ] && {
	deps_resolved=$($_rtb_itool_pkg_resolve --log-level=debug --as-deb-dep	\
		--bubble --latest				\
		--version "$BRANCH_SANITIZED"			\
		--pkg-distribution "$pkg_distribution"		\
		--pkg-release "$pkg_release"			\
		--pkg-group "$pkg_group"			\
		"${deps_to_be_resolved[@]}");
}

for d in $deps_resolved; do
	logmsg "rtbrick package dependency resolved to: [$d]"  "$ME";
	result+=("$d");
done

[ "${#result[@]}" -gt "0" ] && {
	for d in "${result[@]}"; do
		printf "%s\n" "$d";
	done
}

# Do not finish with an error if the last comparison was false. 
true;
