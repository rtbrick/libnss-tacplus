#!/usr/bin/env bash

# Fail hard and fast. Exit at the first error or undefined variable.
set -euo pipefail;

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
} >&2;
[ "${__global_debug:-0}" -gt "1" ] && {
	set -x;
	# functrace is bash specific.
	[ "${BASH_VERSION:-0}" != "0" ] && set -o functrace;
}

# Dependencies on other programs which might not be installed. If any of these
# are missing the script will exit here with an error. We can also rely on
# values discovered and exporter by jenkins_shell_functions .
_curl="$(command -v curl) -fsSL";
_dpkg_deb="$(command -v dpkg-deb)";
_jq="$(command -v jq) -er";
_rtb_itool="${_rtb_itool:-$(command -v rtb-itool-jenkins || command -v rtb-itool)}";

ME="jenkins_upload_to_internal.sh";	# Useful for log messages.

APTLY_API_URL="https://pkg.rtbrick.net/aptly-api";
PKG_TRACKR_URL="https://pkg.rtbrick.net/pkgtrackr/api";

apt_resolv_log="apt_resolv.log";
[ -d "${__jenkins_scripts_dir:-./.jenkins}" ]	\
	&& apt_resolv_log="${__jenkins_scripts_dir:-./.jenkins}/${apt_resolv_log}";
apt_resolv_log_per_cont="${apt_resolv_log}.${DEFAULT_STEP_CONT}";
git_clone_log="${__jenkins_scripts_dir:-./.jenkins}/git_clone_update.log";
[ -f "$git_clone_log" ] || git_clone_log="";

# Check variables that should be set by jenkins.sh .
pkg_name="${pkg_name:-}"; [ -z "$pkg_name" ] && die "Cannot work with a package without a name.";
distri="${pkg_distribution:-}"; [ -z "$distri" ] && die "Cannot work with a package without the Linux distribution."; 
rel="${pkg_release:-}"; [ -z "$rel" ] && die "Cannot work with a package without the Linux release.";
compo="${pkg_group:-}"; [ -z "$compo" ] && die "Cannot work with a package without a group.";
ver_str="${ver_str:-}"; [ -z "$ver_str" ] && die "Cannot work with a package without a version.";
build_ts="${build_ts:-}"; [ -z "$build_ts" ] && die "Cannot work with a package without a build timestamp.";
build_date="${build_date:-}"; [ -z "$build_date" ] && die "Cannot work with a package without a build date.";
build_job_hash="${build_job_hash:-}"; [ -z "$build_job_hash" ] && die "Cannot work with a package without a build job hash.";

aptly_repo_name="latest_${distri}_${compo}_${rel}_${compo}";
aptly_publish_path="latest/${distri}/${compo}";
# https://github.com/aptly-dev/aptly/blob/master/api/publish.go#L44
aptly_publish_path_escaped="latest_${distri}_${compo}";

do_upload() {
	local deb="${1}";
	local pkg_name="";
	local pkg_uuid="";
	local pkg_rtb_metadata="";

	pkg_name="$($_dpkg_deb -I "$deb" 			\
		| grep -E '^[[:space:]]*Package:[[:space:]]*'	\
		| sed -E 's/^[[:space:]]*Package:[[:space:]]*//g')";
	[ -z "$pkg_name" ] && die "Can't find package name from .deb .";

	pkg_uuid="$($_dpkg_deb -I "$deb" 				\
		| grep -E '^.*RtBrick package tracker UUID='		\
		| sed -E 's/^.*RtBrick package tracker UUID=//g')";
	[ -z "$pkg_uuid" ] && die "Package description must contain an UUID.";

	# TODO: Due to the fact that the aptly api returns "200 OK" even in case of
	# errors or problems curl will also return exit code 0 (success). In order to
	# detect a problem we need to inspect the returned JSON.
	logmsg "Trying to upload package ${deb} to Aptly repository $aptly_repo_name" "$ME";
	$_curl -XPOST -F "file=@${deb}" "$APTLY_API_URL/files/$aptly_repo_name"	\
		| $_jq '.[0]' | grep -F "$pkg_name" | grep -F "$ver_str";
	$_curl -XPOST "$APTLY_API_URL/repos/$aptly_repo_name/file/$aptly_repo_name/${deb}"	\
		| $_jq '."Report"."Added"[0]' | grep -F "$pkg_name" | grep -F "$ver_str";
	
	logmsg "Trying to update published Aptly repository at $aptly_publish_path" "$ME";
	$_curl -XPUT -H 'Content-Type: application/json' 					\
		--data "{\"ForceOverwrite\": true}"						\
		"$APTLY_API_URL/publish/filesystem:nginx:$aptly_publish_path_escaped/${rel}"	\
		| $_jq '."Sources"[0]."Name"' | grep -F "$aptly_repo_name";

	logmsg "Trying to upload package ${deb} metadata to package tracker server ..." "$ME";
	pkg_rtb_metadata="$($_rtb_itool pkg struct gen		\
		--uuid "$pkg_uuid" --name "$pkg_name"		\
		--version "$ver_str" --distri "$distri"		\
		--release "$rel" --compo "$compo"		\
		--branch "$BRANCH" --commit "$GIT_COMMIT"	\
		--commit_timestamp "$GIT_COMMIT_TS"		\
		--build_timestamp "$build_ts"			\
		--build_job_hash "$build_job_hash"		\
		--git_dependencies "$git_clone_log"		\
		--dependencies "$apt_resolv_log_per_cont")";
	$_curl -XPOST -H 'Content-Type: application/json'	\
		--data "$pkg_rtb_metadata"			\
		"$PKG_TRACKR_URL/pkgs";
}

# shellcheck disable=SC2012
deb="$(ls -t ./"${pkg_name}"*.deb		\
	| grep -F "$ver_str"			\
	| grep -E -v '^.\/rtbrick.*-(dev|dbg)_'	\
	| head -n 1)";
do_upload "$deb";

# Special handling for any -dev and -dbg packages.
compo="${pkg_group}-dev";

aptly_repo_name="latest_${distri}_${compo}_${rel}_${compo}";
aptly_publish_path="latest/${distri}/${compo}";
# https://github.com/aptly-dev/aptly/blob/master/api/publish.go#L44
aptly_publish_path_escaped="latest_${distri}_${compo}";

deb="";
# shellcheck disable=SC2012
if deb="$(ls -t ./"${pkg_name}"*.deb	\
	| grep -F "$ver_str"		\
	| grep -E '^.\/rtbrick.*-dev_'	\
	| head -n 1)"; then
	do_upload "$deb";
else
	warnmsg "No -dev package found";
fi

deb="";
# shellcheck disable=SC2012
if deb="$(ls -t ./"${pkg_name}"*.deb	\
	| grep -F "$ver_str"		\
	| grep -E '^.\/rtbrick.*-dbg_'	\
	| head -n 1)"; then
	do_upload "$deb";
else
	warnmsg "No -dbg package found";
fi

logmsg "Finished uploading package(s)" "$ME";
