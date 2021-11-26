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
# shellcheck disable=SC2269
_checkinstall="$(which checkinstall)";
_dpkg="$(which dpkg)";
_jq="${_jq:-$(which jq) -er}";
_lsb_release="$(which lsb_release)";
_rtb_itool="$(which rtb-itool)";

ME="jenkins_package.sh";	# Useful for log messages.

# TODO: These are hard-coded values for now. Change them to be part of the
# build conf JSON file.
PAK_FILES_LOCATION="${__jenkins_scripts_dir:-./.jenkins}/packaging";
SYS_FILES_LOCATION="${__jenkins_scripts_dir:-./.jenkins}/system";
SCRIPTS_LOCATION="${__jenkins_scripts_dir:-./.jenkins}/scripts";
SCRIPTS_INSTALL_DEST="/usr/local/bin";
RTBRICK_BD_CONF_DIR="/etc/rtbrick/bd/config";
SYSTEMD_SERVICE_DIR="/lib/systemd/system";
_pkg_maintainer="RtBrick Support <support@rtbrick.com>";
_pkg_license="RtBrick";

# Check variables that should be set by jenkins.sh .
project="$project";
_pkg_name="${pkg_name:-}"; [ -z "$_pkg_name" ] && die "Cannot build a package without a name.";
_pkg_suffix="${pkg_suffix:-}";
_pkg_descr="${pkg_descr:-}"; [ -z "$_pkg_descr" ] && die "Cannot build a package without a descripion.";
_pkg_group="${pkg_group:-}"; [ -z "$_pkg_group" ] && die "Cannot build a package without a group.";
_pkg_provides="${pkg_provides:-}";
_pkg_conflicts="${pkg_conflicts:-}";
_pkg_deps="${pkg_deps:-}";
_pkg_deps_exact="${pkg_deps_exact:-}";
_pkg_srvs="${pkg_services:-}";
_pkg_sw_ver_skip="${pkg_sw_ver_skip:-}";
_ver_str="${ver_str:-}"; [ -z "$_ver_str" ] && die "Cannot build a package without a version.";
_build_ts="${build_ts:-}"; [ -z "$_build_ts" ] && die "Cannot build a package without a build timestamp.";
_build_date="${build_date:-}"; [ -z "$_build_date" ] && die "Cannot build a package without a build date.";
_build_job_hash="${build_job_hash:-}"; [ -z "$_build_job_hash" ] && die "Cannot build a package without a build job hash.";

# We differentiate between -dev and -dbg packages and any other type of package.
_pkg_is_not_dev_dbg="1";
[ -z "$_pkg_suffix" ] && _pkg_is_not_dev_dbg="0";
[ -n "$_pkg_suffix" ] && [ "_$_pkg_suffix" != "_dev" ] && [ "_$_pkg_suffix" != "_dbg" ] && _pkg_is_not_dev_dbg="0";
# Function is useful in if or logic statements.
pkg_is_not_dev_dbg() {
	return "${_pkg_is_not_dev_dbg}";
}

apt_resolv_log="apt_resolv.log";
[ -d "${__jenkins_scripts_dir:-./.jenkins}" ]	\
	&& apt_resolv_log="${__jenkins_scripts_dir:-./.jenkins}/${apt_resolv_log}";

apt_resolv_log_per_cont="${apt_resolv_log}.${DEFAULT_STEP_CONT}";

# Transform the JSON list of dependencies into a comma separated list. This
# happens only for packages different than -dev or -dbg (detected via
# pkg_suffix, where pkg_suffix might also be empty).
_pkg_requires="";
if [ -n "$_pkg_deps" ] && pkg_is_not_dev_dbg; then
	_pkg_deps_len="$(echo "$_pkg_deps" | $_jq '. | length')";
	i="0";
	while [ "$i" -lt "$_pkg_deps_len" ]; do
		dep="$(echo "$_pkg_deps" | $_jq ".[$i]")";
		dep_from_compile="";
		[ -n "$apt_resolv_log_per_cont" ] && [ -n "$_pkg_deps_exact" ] && [ "$_pkg_deps_exact" == "true" ] && {
			dep_from_compile="$(grep -E "^$dep=" "$apt_resolv_log_per_cont" 2>/dev/null || true)";
			[ -n "$dep_from_compile" ] && {
				# https://stackoverflow.com/questions/18365600/how-to-manage-multiple-package-dependencies-with-checkinstall
				# dep_from_compile="$(echo "$dep_from_compile" | sed -E 's/^(.*)=(.*)$/\1 \\(= \2\\)/g')";
				dep_from_compile="$(echo "$dep_from_compile" | sed -E 's/^(.*)=(.*)$/\1 (= \2)/g')";
			}
		}
		[ -n "$dep_from_compile" ] && dep="$dep_from_compile";
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
if [ ! -f "$_git_clone_log" ]; then
  _git_clone_log=""
fi

$_rtb_itool pkg struct gen						\
	--description "$_pkg_descr"					\
	--version "$_ver_str"						\
	--branch "$BRANCH"						\
	--commit "$GIT_COMMIT"						\
	--commit_timestamp "$GIT_COMMIT_TS"				\
	--commit_date "$GIT_COMMIT_DATE"				\
	--build_timestamp "$_build_ts"					\
	--build_date "$_build_date"					\
	--build_job_hash "$_build_job_hash"				\
	--git_dependencies "$_git_clone_log"				\
	--dependencies "$apt_resolv_log_per_cont" > description-pak;

# Apart from running `make install` we might need to install some dynamically
# generated files, like systemd services and/or config files. We will gather
# all install commands in a variable.
_pkg_install_cmd="";

# Create placeholder files for package pre/post install action scripts.
echo -n > "preinstall-pak";
echo -n > "postinstall-pak";
echo -n > "preremove-pak";
echo -n > "postremove-pak";

# Templates for package pre/post install scripts (*-pak) need to run at least
# once for every package. However the logic gets more complex due to the
# presence or absence of package services in which case the templates need to
# run once for each define service.
pak_tmpl_runs="0";

# Check if the software being packaged is supposed to run as a service and if
# yes create the necesary systemd service files and configs. NOTE: this only
# works for systemd based distributions (>= Ubuntu 18.04/bionic) and only
# for the config part only for BDs.
if [ -n "$_pkg_srvs" ] && pkg_is_not_dev_dbg; then
	_pkg_srvs_len="$(echo "$_pkg_srvs" | $_jq '. | length')";
	i="0";
	while [ "$i" -lt "$_pkg_srvs_len" ]; do
		logmsg "Processing package pre/post install action templates for package service #$i ..." "$ME";

		curr_srv_val="$(get_arr_idx "$_pkg_srvs" "$i")";

		srv_systemd_template="$(get_dict_key "$curr_srv_val" "systemd_template" || true)";
		srv_systemd_template="$SYS_FILES_LOCATION/${srv_systemd_template:-systemd.service.tpl}";

		srv_name="$(get_dict_key "$curr_srv_val" "name")";
		[ -z "$srv_name" ] && die "Cannot build a package service without a name.";
		srv_conf="$(get_dict_key "$curr_srv_val" "conf" || true)";
		srv_cmd="$(get_dict_key "$curr_srv_val" "start_cmd")";
		[ -z "$srv_cmd" ] && die "Cannot build a package service without a start cmd.";
		srv_restart="$(get_dict_key "$curr_srv_val" "restart" || true)";
		srv_restart_hold="$(get_dict_key "$curr_srv_val" "restart_hold" || true)";
		srv_restart_intv="$(get_dict_key "$curr_srv_val" "restart_intv" || true)";
		srv_restart_limit="$(get_dict_key "$curr_srv_val" "restart_limit" || true)";
		srv_runas="$(get_dict_key "$curr_srv_val" "runas" || echo "{}")";
		srv_runas_user="$(get_dict_key "$srv_runas" "user" || true)";
		srv_runas_uid="$(get_dict_key "$srv_runas" "uid" || true)";
		srv_runas_group="$(get_dict_key "$srv_runas" "group" || true)";
		srv_runas_gid="$(get_dict_key "$srv_runas" "gid" || true)";
		srv_runas_more_groups="$(get_dict_key "$srv_runas" "more_groups" || true)";

		# This is a weird limitation of checkinstall / installwatch. If
		# the target hierarchy doesn't exist in the system where the
		# package is being built then the install command inside
		# checkinstall will fail.
		mkdir -p "${RTBRICK_BD_CONF_DIR}/";

		pkg_serv_template "$srv_systemd_template"	\
			"${srv_name}.service"			\
			"${srv_name}"				\
			"${srv_cmd}"				\
			"${_pkg_name}"				\
			"${srv_restart}"			\
			"${srv_restart_hold}"			\
			"${srv_restart_intv}"			\
			"${srv_restart_limit}"			\
			"$srv_runas_user"			\
			"$srv_runas_uid"			\
			"$srv_runas_group"			\
			"$srv_runas_gid"			\
			"$srv_runas_more_groups";

		_pkg_install_cmd+=" install -o root -g root -m 0644 -D -t ${SYSTEMD_SERVICE_DIR}/ ${srv_name}.service;";
		[ -n "${srv_conf}" ] && [ "__${srv_conf}" != "__null" ]         \
			&& _pkg_install_cmd+=" install -o root -g root -m 0644 -D -t ${RTBRICK_BD_CONF_DIR}/ ${srv_conf};";

		pkg_serv_template "$PAK_FILES_LOCATION/preinstall-pak.tpl"	\
			"preinstall-pak.$i"			\
			"${srv_name}"				\
			"${srv_cmd}"				\
			"${_pkg_name}"				\
			"${srv_restart}"			\
			"${srv_restart_hold}"			\
			"${srv_restart_intv}"			\
			"${srv_restart_limit}"			\
			"$srv_runas_user"			\
			"$srv_runas_uid"			\
			"$srv_runas_group"			\
			"$srv_runas_gid"			\
			"$srv_runas_more_groups";
		cat "preinstall-pak.$i" >> "preinstall-pak"; rm "preinstall-pak.$i";
		printf "\n#---\n" >> "preinstall-pak";

		pkg_serv_template "$PAK_FILES_LOCATION/postinstall-pak.tpl"	\
			"postinstall-pak.$i"			\
			"${srv_name}"				\
			"${srv_cmd}"				\
			"${_pkg_name}"				\
			"${srv_restart}"			\
			"${srv_restart_hold}"			\
			"${srv_restart_intv}"			\
			"${srv_restart_limit}"			\
			"$srv_runas_user"			\
			"$srv_runas_uid"			\
			"$srv_runas_group"			\
			"$srv_runas_gid"			\
			"$srv_runas_more_groups";
		cat "postinstall-pak.$i" >> "postinstall-pak"; rm "postinstall-pak.$i";
		printf "\n#---\n" >> "postinstall-pak";

		pkg_serv_template "$PAK_FILES_LOCATION/preremove-pak.tpl"	\
			"preremove-pak.$i"			\
			"${srv_name}"				\
			"${srv_cmd}"				\
			"${_pkg_name}"				\
			"${srv_restart}"			\
			"${srv_restart_hold}"			\
			"${srv_restart_intv}"			\
			"${srv_restart_limit}"			\
			"$srv_runas_user"			\
			"$srv_runas_uid"			\
			"$srv_runas_group"			\
			"$srv_runas_gid"			\
			"$srv_runas_more_groups";
		cat "preremove-pak.$i" >> "preremove-pak"; rm "preremove-pak.$i";
		printf "\n#---\n" >> "preremove-pak";

		pkg_serv_template "$PAK_FILES_LOCATION/postremove-pak.tpl"	\
			"postremove-pak.$i"			\
			"${srv_name}"				\
			"${srv_cmd}"				\
			"${_pkg_name}"				\
			"${srv_restart}"			\
			"${srv_restart_hold}"			\
			"${srv_restart_intv}"			\
			"${srv_restart_limit}"			\
			"$srv_runas_user"			\
			"$srv_runas_uid"			\
			"$srv_runas_group"			\
			"$srv_runas_gid"			\
			"$srv_runas_more_groups";
		cat "postremove-pak.$i" >> "postremove-pak"; rm "postremove-pak.$i";
		printf "\n#---\n" >> "postremove-pak";

		pak_tmpl_runs="$(( pak_tmpl_runs + 1))";
		i="$(( i + 1 ))";
	done
fi

if [ "$pak_tmpl_runs" -lt "1" ]; then
	# Create new and empty package pre/post install action scripts. NOTE:
	# the presence of spaces in the last 2 paramethers, these are needed
	# due to a current limitation of the pkg_serv_template function.
	logmsg "Creating empty package pre/post install action scripts" "$ME";

	pkg_serv_template "$PAK_FILES_LOCATION/preinstall-pak.tpl"	\
		"preinstall-pak" " " "" "";

	pkg_serv_template "$PAK_FILES_LOCATION/postinstall-pak.tpl"	\
		"postinstall-pak" " " "" "";

	pkg_serv_template "$PAK_FILES_LOCATION/preremove-pak.tpl"	\
		"preremove-pak" " " "" "";

	pkg_serv_template "$PAK_FILES_LOCATION/postremove-pak.tpl"	\
		"postremove-pak" " " "" "";
fi

# Generate software versions.
if [ -z "$_pkg_sw_ver_skip" ] && pkg_is_not_dev_dbg; then
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
	for f in "${SW_VERS_LOCATION}"/*.json; do
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

# Install additional scripts inside the package
if pkg_is_not_dev_dbg; then
	for f in $(find "${SCRIPTS_LOCATION}/" -type f -iname '*.sh' 2>/dev/null || true); do
		_pkg_install_cmd+=" install -o root -g root -m 0755 -D -t ${SCRIPTS_INSTALL_DEST}/ $f;";
	done
	for f in $(find "${SCRIPTS_LOCATION}/" -type f -iname '*.bash' 2>/dev/null || true); do
		_pkg_install_cmd+=" install -o root -g root -m 0755 -D -t ${SCRIPTS_INSTALL_DEST}/ $f;";
	done
fi

# Get architecture and ubuntu release codename.
rel_arch="$($_dpkg --print-architecture)";
[ -z "$rel_arch" ] && die "Cannot build a package without knowing the arch.";
rel_codename="$($_lsb_release -c -s)";
[ -z "$rel_codename" ] && die "Cannot build a package without knowing the release codename.";

checkinstall_pkg_name="$_pkg_name";
[ -n "$_pkg_suffix" ] && checkinstall_pkg_name="${_pkg_name}-${_pkg_suffix}";

declare -a _checkinstall_args=("--type=debian"			\
	"--backup=no" "-y" "--nodoc" 				\
	"--install=no" "--deldesc=yes"				\
	"--strip=no" "--stripso=no"				\
	"--pkgarch=$rel_arch" "--pkggroup=$_pkg_group"		\
	"--maintainer=$_pkg_maintainer"				\
	"--pkglicense=$_pkg_license"				\
	"--replaces=$checkinstall_pkg_name"			\
	"--requires=$_pkg_requires"				\
	"--pkgname=$checkinstall_pkg_name"			\
	"--pkgversion=$_ver_str"				\
);

[ -n "$_pkg_provides" ]	&& _checkinstall_args+=("--provides=$_pkg_provides");

# Transform the JSON list of conflicts into a comma separated list.
if [ -n "$_pkg_conflicts" ]; then
	conflicts="";
	conflicts_len="$(echo "$_pkg_conflicts" | $_jq '. | length')";
	i="0";
	while [ "$i" -lt "$conflicts_len" ]; do
		con="$(echo "$_pkg_conflicts" | $_jq ".[$i]")";
		if [ -z "$conflicts" ]; then
			conflicts="$con";
		else
			conflicts="${conflicts},$con";
		fi
		i="$(( i + 1 ))";
	done

	_checkinstall_args+=("--conflicts=$conflicts");
fi

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

####
#### Installation commands (mkdir, cp, install etc.) follow BELOW. These are
#### taken automatically from the build configuration pkg_commands variable.
####

# Try to save the current directory so we can restore if after running the build
# commands. Could someone use such a variable name in the build commands ? You
# can never be sure.
____initial_dir="$PWD";

# Avoid shell check SC2154 `referenced but not assigned` but stil rely on value
# passed on by calling script. If variable is not set by calling script this
# should through an error.
pkg_commands="$pkg_commands";
pkg_commands_len="$(echo "$pkg_commands" | $_jq -c '. | values | length')";
i="0";
while [ "$i" -lt "$pkg_commands_len" ]; do
	cmd="$(echo "$pkg_commands" | $_jq -c ". | values | .[$i]"	\
		| grep -Eiv '^[[:blank:]]*null[[:blank:]]*$')";

	[ -n "$cmd" ] && {
		logmsg "Adding pkg command #$i '$cmd'" "$ME";
		_pkg_install_cmd+=" $cmd;";
	}

	i="$(( i + 1 ))";
done

####
#### LAST COMMAND in this file MUST call checkinstall !
####

# Finally execute checkinstall with all the prepared arguments and install
# commands.
$_checkinstall "${_checkinstall_args[@]}" /bin/bash -ue -c "${_pkg_install_cmd}";

# Restore working directory if it was changes by package commands.
cd "${____initial_dir}";
