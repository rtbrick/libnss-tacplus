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

# Dependencies on other programs which might not be installed. If any of these
# are missing the script will exit here with an error.
_jq="$(which jq) -er";
_checkinstall="$(which checkinstall)";
_dpkg="$(which dpkg)";
_lsb_release="$(which lsb_release)";

# TODO: These are hard-coded values for now. Change them to be part of the
# build conf JSON file.
PAK_FILES_LOCATION="${__jenkins_scripts_dir:-./.jenkins}/packaging";
SYS_FILES_LOCATION="${__jenkins_scripts_dir:-./.jenkins}/system";
RTBRICK_BD_CONF_DIR="/etc/rtbrick/bd/config";
SYSTEMD_SERVICE_DIR="/lib/systemd/system";
_pkg_maintainer="RtBrick Support <support@rtbrick.com>";
_pkg_license="RtBrick";

# Check variables that should be set by jenkins.sh .
_pkg_name="${pkg_name:-}"; [ -z "$_pkg_name" ] && die "Cannot build a package without a name.";
_pkg_descr="${pkg_descr:-}"; [ -z "$_pkg_descr" ] && die "Cannot build a package without a descripion.";
_pkg_group="${pkg_group:-}"; [ -z "$_pkg_group" ] && die "Cannot build a package without a group.";
_pkg_deps="${pkg_deps:-}";
_pkg_srvs="${pkg_services:-}";
_pkg_sw_ver_skip="${pkg_sw_ver_skip:-}";
_ver_str="${ver_str:-}"; [ -z "$_ver_str" ] && die "Cannot build a package without a version.";
_build_ts="${build_ts:-}"; [ -z "$_build_ts" ] && die "Cannot build a package without a build timestamp.";
_build_date="${build_date:-}"; [ -z "$_build_date" ] && die "Cannot build a package without a build date.";
_build_job_hash="${build_job_hash:-}"; [ -z "$_build_job_hash" ] && die "Cannot build a package without a build job hash.";

# Transform the JSON list of dependencies into a comma separated list.
_pkg_requires="";
if [ -n "$_pkg_deps" ]; then
	_pkg_deps_len="$(echo "$_pkg_deps" | $_jq '. | length')";
	i="0";
	while [ "$i" -lt "$_pkg_deps_len" ]; do
		dep="$(echo "$_pkg_deps" | $_jq ".[$i]")";
		if [ -z "$_pkg_requires" ]; then
			_pkg_requires="$dep";
		else
			_pkg_requires="${_pkg_requires},$dep";
		fi
		i="$(( i + 1 ))";
	done
fi

# Copy pak files to the root of the repository. Ignore errors, which usually
# mean that no pak files are found or that they are in another location. Note
# that quoting the entire string will disable shell glob file expansion.
cp "$PAK_FILES_LOCATION"/*-pak ./ || true;

# Generate description-pak
_git_clone_log="${__jenkins_scripts_dir:-./.jenkins}/git_clone_update.log";
echo "$_pkg_descr" > description-pak;
{
	echo "";
	echo "rtbrick_package_properties:";
	echo "    version: $_ver_str";
	echo "    branch: $BRANCH";
	echo "    commit: $GIT_COMMIT";
	echo "    commit_timestamp: $GIT_COMMIT_TS";
	echo "    commit_date: $GIT_COMMIT_DATE";
	echo "    build_timestamp: $_build_ts";
	echo "    build_date: $_build_date";
	echo "    build_job_hash: $_build_job_hash";
	if [ -f "$_git_clone_log" ]; then
		echo "    git_dependencies:";
		cat "$_git_clone_log";
	fi
} >> description-pak;

# Apart from running `make install` we might need to install some dynamically
# generated files, like systemd services and/or config files. We will gather
# all install commands in a variable.
_pkg_install_cmd="";

# Create new and empty package pre/post install action scripts. NOTE: the
# presence of spaces in the last 2 paramethers, these are needed due to a
# current limitation of the pkg_serv_template function.
pkg_serv_template "$PAK_FILES_LOCATION/preinstall-pak.tpl"	\
	"preinstall-pak" " " "";

pkg_serv_template "$PAK_FILES_LOCATION/postinstall-pak.tpl"	\
	"postinstall-pak" " " "";

pkg_serv_template "$PAK_FILES_LOCATION/preremove-pak.tpl"	\
	"preremove-pak" " " "";

pkg_serv_template "$PAK_FILES_LOCATION/postremove-pak.tpl"	\
	"postremove-pak" " " "";

# Check if the software being packaged is supposed to run as a service and if
# yes create the necesary systemd service files and configs. NOTE: this only
# works for systemd based distributions (>= Ubuntu 18.04/bionic) and only
# for the config part only for BDs.
if [ -n "$_pkg_srvs" ]; then
	_pkg_srvs_len="$(echo "$_pkg_srvs" | $_jq '. | length')";
	i="0";
	while [ "$i" -lt "$_pkg_srvs_len" ]; do
		srv_name="$(echo "$_pkg_srvs" | $_jq ".[$i].name")";
		[ -z "$srv_name" ] && die "Cannot build a package service without a name.";
		srv_conf="$(echo "$_pkg_srvs" | $_jq ".[$i].conf" || true)";
		srv_cmd="$(echo "$_pkg_srvs" | $_jq ".[$i].start_cmd")";
		[ -z "$srv_cmd" ] && die "Cannot build a package service without a start cmd.";

		# This is a weird limitation of checkinstall / installwatch. If
		# the target hierarchy doesn't exist in the system where the
		# package is being built then the install command inside
		# checkinstall will fail.
		mkdir -p "${RTBRICK_BD_CONF_DIR}/";

		pkg_serv_template "$SYS_FILES_LOCATION/systemd.service.tpl"	\
			"${srv_name}.service"	\
			"${srv_name}"		\
			"${srv_cmd}";

		_pkg_install_cmd+=" install -o root -g root -m 0644 -D -t ${SYSTEMD_SERVICE_DIR}/ ${srv_name}.service;";
		[ -n "${srv_conf}" ] && _pkg_install_cmd+=" install -o root -g root -m 0644 -D -t ${RTBRICK_BD_CONF_DIR}/ ${srv_conf};";

		pkg_serv_template "$PAK_FILES_LOCATION/preinstall-pak.tpl"	\
			"preinstall-pak.$i"	\
			"${srv_name}"		\
			"";
		printf "\n\n" >> "preinstall-pak";
		cat "preinstall-pak.$i" >> "preinstall-pak"; rm "preinstall-pak.$i";

		pkg_serv_template "$PAK_FILES_LOCATION/postinstall-pak.tpl"	\
			"postinstall-pak.$i"	\
			"${srv_name}"		\
			"";
		printf "\n\n" >> "postinstall-pak";
		cat "postinstall-pak.$i" >> "postinstall-pak"; rm "postinstall-pak.$i";

		pkg_serv_template "$PAK_FILES_LOCATION/preremove-pak.tpl"	\
			"preremove-pak.$i"	\
			"${srv_name}"		\
			"";
		printf "\n\n" >> "preremove-pak";
		cat "preremove-pak.$i" >> "preremove-pak"; rm "preremove-pak.$i";

		pkg_serv_template "$PAK_FILES_LOCATION/postremove-pak.tpl"	\
			"postremove-pak.$i"	\
			"${srv_name}"		\
			"";
		printf "\n\n" >> "postremove-pak";
		cat "postremove-pak.$i" >> "postremove-pak"; rm "postremove-pak.$i";

		i="$(( i + 1 ))";
	done
fi

# Generate software versions
if [ -z "$_pkg_sw_ver_skip" ]; then
	# This is a weird limitation of checkinstall / installwatch. If
	# the target hierarchy doesn't exist in the system where the
	# package is being built then the install command inside
	# checkinstall will fail.
	mkdir -p "${SW_VERS_INSTALL}/";

	sw_ver_template "$SW_VERS_TPL" "${SW_VERS_LOCATION}/${project}.json"	\
		"$project"					\
		"$_ver_str"					\
		"$BRANCH"					\
		"$GIT_COMMIT"					\
		"$GIT_COMMIT_TS"				\
		"$_build_ts";

	# If this project has any gitlab dependencies then their corresponding
	# .json version files have been already generated during the gitlab
	# clone/update phase. However at that time ver_str and build_ts weren't
	# known. We need to go again through all the already generated files.
	# The empty fields are left untouched.
	for f in ${SW_VERS_LOCATION}/*.json; do
		sw_ver_template "" "$f"	\
			""		\
			"$_ver_str"	\
			""		\
			""		\
			""		\
			"$_build_ts";

		_pkg_install_cmd+=" install -o root -g root -m 0644 -D -t ${SW_VERS_INSTALL}/ $f;";
	done
fi

# Get architecture and ubuntu release codename.
rel_arch="$($_dpkg --print-architecture)";
[ -z "$rel_arch" ] && die "Cannot build a package without knowing the arch.";
rel_codename="$($_lsb_release -c -s)";
[ -z "$rel_codename" ] && die "Cannot build a package without knowing the release codename.";

declare -a _checkinstall_args=("--type=debian"			\
	"--backup=no" "-y" "--nodoc" 				\
	"--install=no" "--deldesc=yes"				\
	"--pkgarch=$rel_arch" "--pkggroup=$_pkg_group"		\
	"--maintainer=$_pkg_maintainer"				\
	"--pkglicense=$_pkg_license"				\
	"--replaces=$_pkg_name"					\
	"--requires=$_pkg_requires"				\
	"--pkgname=$_pkg_name"					\
	"--pkgversion=$_ver_str"				\
);

# Only set checkinstall debug flag when global debug is set.
[ "${__global_debug:-0}" -gt "0" ] && {
	_checkinstall_args+=("-d" "$__global_debug");
};

# shellcheck disable=SC2034
_tmp="$(echo "$_ver_str" | grep -Ec -- '-')" && {
	# The Debian policy specifies that if the "upstream version" of a piece
	# of software contains '-' then the .deb package version must also
	# contain a "debian_version" (called "pkg release" in
	# checkinstall terms). See:
	# https://www.debian.org/doc/debian-policy/ch-controlfields.html#version
	_checkinstall_args+=("--pkgrelease=$rel_codename");
};

# Add any install commands to the _pkg_install_cmd variable, don't forget the ;
# between commands and don't forget that this is a string concatenation operation
# ( += ), a simple = will just delete all the commands already present in
# _pkg_install_cmd . Multiple make commands can be added.
_pkg_install_cmd+=" make \"app_ver=$_ver_str\" install;";

# Finally execute checkinstall with all the prepared arguments and install
# commands.
$_checkinstall "${_checkinstall_args[@]}" /bin/sh -ue -c "${_pkg_install_cmd}";
