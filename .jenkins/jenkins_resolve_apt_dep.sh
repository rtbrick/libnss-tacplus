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
_apt="$_apt";

ME="jenkins_resolve_apt_dep.sh";	# Useful for log messages.

print_usage() {
	printf "Usage: %s 'pkg_match_string' [--with-dev|--no-dev]\n" "$0";
	printf "\t--with-dev\tEnable searching for -dev packages. This is the default.\n";
	printf "\t--no-dev\tDisable searching for -dev packages.\n";
}

dev_pkg_exists() {
	local pkg_name="$1";
	local pkg_resolved="$2";
	local ver_str="";
	local dev_pkg_match="";

	dev_pkg_match="${pkg_name}-dev";
	ver_str="$(echo "$pkg_resolved" | grep -E '^(.*)=(.*)$'	\
		| sed -E 's/^(.*)=(.*)$/\2/g')" || true;
	[ -n "$ver_str" ] && {
		dev_pkg_match="${pkg_name}-dev=${ver_str}";
	}

	$_apt show "$dev_pkg_match" 2>/dev/null 1>/dev/null || {
		warnmsg "Couldn not find -dev package: '$dev_pkg_match'" "$ME";
		return 1;
	}

	echo "$dev_pkg_match";
	return 0;
}

_pkg_dep_str="$1";
_search_dev="${2:---with-dev}";

if [ "$_search_dev" != "--with-dev" ] && [ "$_search_dev" != "--no-dev" ]; then
	errmsg "Invalid CLI flag '$_search_dev'" "$ME";
	>&2 print_usage;
	exit 2;
fi

# We disable searching for -dev packages by setting _search_dev to an empty
# value as it is checked later on using `-n`.
[ "$_search_dev" == "--no-dev" ] && _search_dev="";

pkg_name="$(echo "$_pkg_dep_str" | sed -E "s/$DEPVER_MATCH/\\1/g")";
match_full="$(echo "$_pkg_dep_str" | sed -E "s/$DEPVER_MATCH/\\2/g")";


[ -n "$match_full" ] && {
	pkg_resolved="$(apt_pkg_match "$_pkg_dep_str")";
	printf "%s" "$pkg_resolved";

	[ -n "$_search_dev" ] && dev_resolved="$(dev_pkg_exists "$pkg_name" "$pkg_resolved")" && {
		printf "  %s" "$dev_resolved";
	}

	printf "\n";
	exit "$?";
}


# We are on the else branch meaning [ -z "$match_full" ] === true.
[ "$BRANCH" == "master" ] && {
	pkg_resolved="";
	new_dep_str="$pkg_name (~= xdaily)";
	pkg_resolved="$(apt_pkg_match "$new_dep_str")" || {
		warnmsg "Searching for dependency from master branch failed: '$new_dep_str'" "$ME";

		pkg_resolved="$(apt_pkg_match "$pkg_name")";
	}
	printf "%s" "$pkg_resolved";

	[ -n "$_search_dev" ] && dev_resolved="$(dev_pkg_exists "$pkg_name" "$pkg_resolved")" && {
		printf "  %s" "$dev_resolved";
	}

	printf "\n";
	exit "$?";
}


[ "$BRANCH" == "development" ] && {
	pkg_resolved="";
	new_dep_str="$pkg_name (~= Bdevelopment)";
	pkg_resolved="$(apt_pkg_match "$new_dep_str")" || {
		warnmsg "Searching for dependency from development branch failed: '$new_dep_str'" "$ME";

		new_dep_str="$pkg_name (~= xdaily)";
		pkg_resolved="$(apt_pkg_match "$new_dep_str")" || {
			warnmsg "Searching for dependency from master branch failed: '$new_dep_str'" "$ME";

			pkg_resolved="$(apt_pkg_match "$pkg_name")";
		}
	}
	printf "%s" "$pkg_resolved";

	[ -n "$_search_dev" ] && dev_resolved="$(dev_pkg_exists "$pkg_name" "$pkg_resolved")" && {
		printf "  %s" "$dev_resolved";
	}

	printf "\n";
	exit "$?";
}


# If we ended up down here it means that BRANCH is neither development nor
# master.
pkg_resolved="";
new_dep_str="$pkg_name (~= B$BRANCH_SANITIZED)";
pkg_resolved="$(apt_pkg_match "$new_dep_str")" || {
	warnmsg "Searching for dependency from branch $BRANCH ($BRANCH_SANITIZED) failed: '$new_dep_str'" "$ME";

	new_dep_str="$pkg_name (~= Bdevelopment)";
	pkg_resolved="$(apt_pkg_match "$new_dep_str")" || {
		warnmsg "Searching for dependency from development branch failed: '$new_dep_str'" "$ME";

		new_dep_str="$pkg_name (~= xdaily)";
		pkg_resolved="$(apt_pkg_match "$new_dep_str")" || {
			warnmsg "Searching for dependency from master branch failed: '$new_dep_str'" "$ME";

			pkg_resolved="$(apt_pkg_match "$pkg_name")";
		}
	}
}
printf "%s" "$pkg_resolved";

[ -n "$_search_dev" ] && dev_resolved="$(dev_pkg_exists "$pkg_name" "$pkg_resolved")" && {
	printf "  %s" "$dev_resolved";
}

printf "\n";
exit "$?";
