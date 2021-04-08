#!/usr/bin/env bash

# jenkins.sh is the entry point of any Jenkins build job. The build job is
# (roughly) composed of 4 high level steps:
#     - build
#     - package
#     - test
#     - upload
# (although the test high level step is rarely used).
#
# jenkins.sh uses the $build_conf JSON file (which by default is
# .jenkins/jenkins_build_conf.json) to find out the config information for
# different builds (like master vs. development build or 14.04 vs. 18.04 build)
# and for each of the build configs included it in the JSON file it should find
# the shell scripts and/or list of commands for each of the 4 steps described
# above:
#     - ["build_name"]["build_script"]
#     - ["build_name"]["pkg_script"]
#     - ["build_name"]["test_script"]
#     - ["build_name"]["upload_script"]
# AND/OR:
#     - ["build_name"]["build_commands"]: [ "shell cmd 1", "shell cmd 2", "shell cmd 3" ]
#
# More details about the expected structure of the $build_conf JSON file are
# included as comments in the actual JSON file.
#
# If for a specific step there is only a command or a few simple commands they
# can be included in the $build_conf JSON file directly, or a complex script
# can be created and included in the $build_conf JSON as
# ".jenkins/jenkins_step_name_of_specific_script.sh".
#
# If for a specific step we have a standalone script it should be named:
#     - jenkins_build_.....sh
#     - jenkins_package_....sh
#     - jenkins_test_....sh
#     - jenkins_upload_.....sh
#
# For different build configs (like master vs. development) we can have
# different scripts for a step but all the scripts should be named starting
# with the prefixes above.
#
# Or course the build step will almost always rely on (complex) cmake/make
# files. The make files are out of scope for jenkins.sh, it is expected that
# they already exist and work correctly. A make file might expect to receive
# some arguments or environment variables and these should be included/set in
# the respective jenkins_build....sh or jenkins_package_.....sh script (the
# packaging step will mostly like have to call "make install").
#
# If, in addition to make files, a specific build relies also on additional
# shell scripts (like "configure.sh" or "compile.sh", "aptly_upload...", etc.)
# these should be folded (included) into the shell script for that step.
#
# All additional jenkins_.......sh should follow best practices guildlines:
#     - Fail hard and fast (set -ue)
#     - Always quote all strings and arguments & assignments especially that
#       contain variable expansions (there are some exceptions but if you need
#       them you will also know them).
#     - Portable shebang (#!) like in jenkins.sh .
#     - Use shell_check to verify the script:
#           shell_check -a -x -s bash ./jenkins.sh
#           (shell check command is one word without space or _).
#

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
# Since the script will exit at the first error try and print details about the
# command which errored.
custom_trap_debug() {
	local rc="$1";
	local cmd="$2";
	local lineno="$3";
	local file="$4";
	local header="";

	header="$(date "$DATE_FMT") ERROR:";
	[ -t 2 ] && header="\e[91m$header\e[0m";

	>&2 printf "%s command '%s' failed with exit code %d at line %d in %s\n" \
		"$header" "$cmd" "$rc" "$lineno" "$file";

	prom_set "success_job" "0" || true;
	prom_update_duration "duration_total" || true;
	>&2 printf "%s Trying to push Prometheus metrics\n" "$header";
	prom_push "${proj:-}" || true;

	[ "${keep_containers:-0}" -ne "1" ] && {
		prom_add_duration "duration_cleanup" "Duration of the cleanup step in seconds."	\
			"step=\"cleanup\"" "" || true;
		>&2 printf "%s Trying to cleanup docker containers and networks\n"	\
			"$header";
		docker_cleanup "$build_name" "$build_job_hash" || true;
		prom_update_duration "duration_cleanup" || true;
		prom_set "success_job" "0" || true;
		prom_update_duration "duration_total" || true;
		prom_push "${proj:-}" || true;
	}

	return "$rc";
}
trap 'custom_trap_debug "$?" "$BASH_COMMAND" "$LINENO" "${BASH_SOURCE[0]}"' ERR;

# Dependencies on other programs which might not be installed. If any of these
# are missing the script will exit here with an error. Can also rely on values
# discovered and set in jenkins_shell_functions.
_git="$_git";
_jq="$_jq";
_sha256sum="$_sha256sum";

# Prefer podman over docker if available.
_docker="$(which podman)" || _docker="$(which docker)";	export _docker;
_docker_exec="$_docker exec -t";			export _docker_exec;

# Global variables.
# DEFAULT_BUILD_SCRIPT is the script used when a build step (inside of a
# container does not have a specific value for build_script.
DEFAULT_BUILD_SCRIPT="${__jenkins_scripts_dir:-./.jenkins}/jenkins_build.sh";
DEFAULT_PKG_SCRIPT="${__jenkins_scripts_dir:-./.jenkins}/jenkins_package.sh";
#
# DEFAULT_STEP_CONT defines the default container name in which steps like
# package, test, upload will run if a specific container for them is not
# defined in build_conf through a variable like `pkg_cont`.
DEFAULT_STEP_CONT="builder";
# 
# build_conf is the JSON file describing the build. It has a default value but
# it can also be provided via the -C CLI option.
build_conf="${__jenkins_scripts_dir:-./.jenkins}/jenkins_build_conf.json";
build_name="";				# The build name identifying which build
					# from $build_conf will be run. Set with
					# the -B CLI option.
build_step="";				# Limit the build to only one step. Note that
					# all the containers are still started even if
					# build_step is specified as they might provide
					# some ancillary services (like a database server).
highlevel_step="";			# The high level step to run. It can be either
					# build, package or upload. If unset all steps
					# will be executed.
cleanup_hash="";			# build_job_hash used to identify docker containers
					# to cleanup.
keep_containers="";			# Docker containers and networks are cleaned up automatically
					# even for failed builds. If this is set then keep them after
					# a failed build for troubleshooting.
local_build="";				# If this is set via the -L CLI option
					# vars expected from Jenkins are calculated
					# locally and the DEB package is not uploaded.
docker_net_skip="";			# Skip configuring docker networks for containers.
upload_force="0";			# Force the upload of the resulting package
					# even if this is a local build.
ssh_agent_fwd="0";			# Forward the local SSH Agent inside all containers.
__global_debug="0";			# Debug flag. Can be specified multiple times.
ME="jenkins.sh";			# Useful for log messages.

print_usage() {
	local whoami="${0:-}";
	[ -z "$whoami" ] && [ -n "${ME:-}" ] && whoami="$ME";
	[ -z "$whoami" ] && whoami="jenkins.sh";

	printf "\nUsage: %s [-d[d]] [-L [-W]] [-C build_conf_json ] -B build_name [-N build_job_hash] [-K] [-O] [-S build_step] [-T build|package|upload ]\n\n" "$whoami";
	printf "\t-A\t\tForward the local SSH Agent inside all containers.\n";
	printf "\t-L\t\tLocal build. Most of the times this is needed when running %s manually.\n" "$whoami";
	printf "\t-W\t\tForce the upload of the package for local builds, for which normally we don't try to upload the package.\n";
	printf "\t-C filename\tSpecify a different build config JSON file. Default: %s\n" "$build_conf";
	printf "\t-B name\t\tMandatory. Select one of the builds from the build config JSON.\n";
	printf "\t-S build_step\tRun only one of the build steps. Default is to run all build steps.\n";
	printf "\t\t\tNote that all the containers are still started even if build_step is specified\n";
	printf "\t\t\tas they might provide some ancillary services (like a database server).\n";
	printf "\t-T step\t\tRun only one of the 4 high level steps: build, package, test or upload. Default is to run all 4.\n";
	printf "\t-N build_job_hash\tCleanup an existing set of docker containers left over from a previous (failed) build.\n";
	printf "\t-K\t\tKeep failed. Docker containers and networks are cleaned up automatically even for failed builds. If this is set then keep them after a failed build for troubleshooting.\n";
	printf "\t-O\t\tSkip configuring docker networks for the spawned containers.\n";
	printf "\t-d\t\tDebugging, use twice to activate the shell trace option.\n\n";
}

# Parse CLI options.
args=$(getopt hdALWC:B:N:KOS:T: "$@") || {
	>&2 echo "Invalid CLI options.";
	>&2 print_usage "$@";
	exit 2;
}
# shellcheck disable=SC2086
set -- $args;
while [ $# -ne 0 ]; do
	case "$1" in
		-h)
			print_usage "$@";
			exit 0; ;;
		-d)
			__global_debug="$(( __global_debug + 1))"; shift;;
		-A)
			ssh_agent_fwd="1"; shift;;
		-L)
			local_build="1"; shift;;
		-W)
			upload_force="1"; shift;;
		-C)
			build_conf="$2"; shift; shift;;
		-B)
			build_name="$2"; shift; shift;;
		-N)
			cleanup_hash="$2"; shift; shift;;
		-K)
			keep_containers="1"; shift;;
		-O)
			docker_net_skip="1"; shift;;
		-S)
			build_step="$2"; shift; shift;;
		-T)
			highlevel_step="$2"; shift; shift;;
		--)
			shift; break;;
	esac
done

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

# If asked to forward the SSH agent verify that a working agent is available.
[ "$ssh_agent_fwd" -eq "1" ] && {
	[ -n "$SSH_AUTH_SOCK" ] || {
		>&2 echo "-A option used but the ssh-agent information is missing (SSH_AUTH_SOCK is empty).";
		return 100;
	}

	_keys_loaded="$(ssh-add -L)" || {
		>&2 echo "-A option used but SSH_AUTH_SOCK seems to point to an invalid ssh-agent.";
		return 100;
	}

	[ -n "$_keys_loaded" ] || {
		>&2 echo "-A option used but keys loaded into the ssh-agent.";
		return 100;
	}

	>&2 printf "\nWARNING: Starting a docker containers with ssh-agent forwarding enabled !\n";
	>&2 printf "The ssh-agent forwarding will remain active as long as the containers are\n";
	>&2 printf "present on this machine.\n";
	>&2 printf "\nIf the build fails at any point the containers will be left running.\n";
	>&2 printf "Remove them using the -N 'build_job_hash' option.\n";
	>&2 printf "\nWARNING: All users and processes inside the containers will have access\n";
	>&2 printf "to the ssh-agent.\n\n";
}

# Verify whether we are running inside Jenkins if not marked as a local build.
[ -z "$local_build" ] && [ -z "${JENKINS_HOME:-}" ] && {
	>&2 echo "JENKINS_HOME is not set. If you are running this build locally, please use the -L option.";
	>&2 echo "If this is happening inside a Jenkins build then something is wrong.";
	>&2 print_usage "$@";
	exit 2;
}

# Verify the configuration file.
[ -r "$build_conf" ] || {
	>&2 echo "Config '$build_conf' either doesn't exist or it is no readable";
	>&2 print_usage "$@";
	exit 2;
}

# Verify if we received a build_name.
[ -n "$build_name" ] || {
	>&2 echo "Need a build name.";
	>&2 print_usage "$@";
	exit 2;
}

# Verify if the received build_name is present in $build_conf.
get_conf_key "$build_name" 1>/dev/null || {
	>&2 echo "Build '$build_name' doesn't exist in $build_conf";
	>&2 print_usage "$@";
	exit 2;
}

# If we were asked to run only a single high-level step verify it's a correct
# string.
[ -n "$highlevel_step" ] && {
	[ -n "$cleanup_hash" ] && {
		>&2 echo "Cannot do a cleanup and a new build at the same time."
		>&2 echo "Run them as 2 different invocations of $0 .";
		>&2 print_usage "$@";
		exit 2;
	}
	case "$highlevel_step" in
		build)
			;;
		package)
			;;
		test)
			;;
		upload)
			;;
		*)
			>&2 echo "'$highlevel_step' is not a valid option for the high level build step.";
			>&2 print_usage "$@";
			exit 2; ;;
	esac
}

# If we were asked to run only a single build step verify it's a correct
# string.
[ -n "$build_step" ] && {
	[ -n "$cleanup_hash" ] && {
		>&2 echo "Cannot do a cleanup and a new build at the same time."
		>&2 echo "Run them as 2 different invocations of $0 .";
		>&2 print_usage "$@";
		exit 2;
	}
	_build_steps="$(get_build_key_or_def "$build_name" "containers")";
	_exists="$(echo "$_build_steps" | $_jq ".[] | select(.name == \"$build_step\")")" || {
		>&2 echo "build_step '$build_step' doesn't exist in the build conf JSON file.";
		>&2 print_usage "$@";
		exit 2;
	};
	if [ -z "$_exists" ] || [ "$_exists" == "null" ]; then
		>&2 echo "something about build_step '$build_step' is misconfigured the build conf JSON file.";
		>&2 print_usage "$@";
		exit 2;
	fi
}

[ -n "$cleanup_hash" ] && {
	logmsg "Cleaning up any pre-exiting docker networks and containers left over from previous build_job_hash: $cleanup_hash" "$ME";
	docker_cleanup "$build_name" "$cleanup_hash";
	exit 0;
}

# When are we doing this ?
build_ts="$(date '+%s')";
build_date="$(timestamp_format "$build_ts")";

if [ -n "$local_build" ]; then
	# If it is a local build get BRANCH and GIT_COMMIT from the local state
	# of the repo where jenkins.sh is run.
	BRANCH="$($_git branch --no-color | grep -E -m 1 '^[[:space:]]*\*[[:space:]]*'	\
			| sed -E 's/^[[:space:]]*\*[[:space:]]*//g')";
	GIT_COMMIT="$($_git rev-parse HEAD)";
	export BRANCH;
	export GIT_COMMIT;
fi

# Check if this build was triggered by a Gitlab merge request.
if [ "${gitlabActionType:-}" == "MERGE" ]; then
	# Although we know that this is Gitlab triggered, so all of these
	# variables should exit, let's assign them to local vars to avoid
	# shell check from complaining (SC2154).
	gitlabMergeRequestIid="${gitlabMergeRequestIid:-}";
	gitlabSourceRepoName="${gitlabSourceRepoName:-}";
	gitlabSourceBranch="${gitlabSourceBranch:-}";
	gitlabTargetRepoName="${gitlabTargetRepoName:-}";
	gitlabTargetBranch="${gitlabTargetBranch:-}";
	gitlabMergeRequestLastCommit="${gitlabMergeRequestLastCommit:-}";

	if [ -z "$gitlabMergeRequestIid" ]		\
		|| [ -z "$gitlabSourceRepoName" ]	\
		|| [ -z "$gitlabSourceBranch" ]		\
		|| [ -z "$gitlabTargetRepoName" ]	\
		|| [ -z "$gitlabTargetBranch" ]		\
		|| [ -z "$gitlabMergeRequestLastCommit" ]; then

		die "Some of the expected gitlab variables are not set !";
	fi

	logmsg "Build triggered by gitlab merge request !${gitlabMergeRequestIid}: ${gitlabSourceRepoName}:${gitlabSourceBranch} => ${gitlabTargetRepoName}:${gitlabTargetBranch}";

	# It seems that Jenkins will checkout the master branch even for a
	# merge request triggered build, so we need to checkout the source
	# branch manually.
	#
	# TODO: This works out just fine for merge requests between branches
	# in the same repository. But for merge requests between branches in
	# different repositories (like a "fork") we need to do something similar
	# to: https://gitlab.rtbrick.net/help/user/project/merge_requests/index.md#checkout-merge-requests-locally
	$_git checkout "${gitlabSourceBranch}";

	BRANCH="$($_git branch --no-color | grep -E -m 1 '^[[:space:]]*\*[[:space:]]*'	\
			| sed -E 's/^[[:space:]]*\*[[:space:]]*//g')";
	GIT_COMMIT="$($_git rev-parse HEAD)";

	[ "_$BRANCH" == "_$gitlabSourceBranch" ] || die "Can't switch to branch: $gitlabSourceBranch";
	[ "_$GIT_COMMIT" == "_$gitlabMergeRequestLastCommit" ] || die "Latest commit doesn't match: $GIT_COMMIT != $gitlabMergeRequestLastCommit";

	export BRANCH;
	export GIT_COMMIT;
fi

# Sanity check that we have branch and commit information.
if [ -z "$BRANCH" ] || [ -z "$GIT_COMMIT" ]; then
	die "Unknown state of git repository";
fi
BRANCH_SANITIZED="$BRANCH"; export BRANCH_SANITIZED;
GIT_COMMIT_TS="$($_git show --no-patch '--format=%ct' "$GIT_COMMIT")"; export GIT_COMMIT_TS;
GIT_COMMIT_DATE="$(timestamp_format "$GIT_COMMIT_TS")"; export GIT_COMMIT_DATE;
_git_commit_subj="$($_git show --no-patch '--format=%s' "$GIT_COMMIT")";
_git_commit_email="$($_git show --no-patch '--format=%ce' "$GIT_COMMIT")";

logmsg "Continuing build script in branch $BRANCH @ commit $GIT_COMMIT" "$ME";
logmsg "$GIT_COMMIT: $_git_commit_subj - $_git_commit_email" "$ME";

# Get build configuration variables.
proj="$(get_build_key_or_def "$build_name" "project")";
ver_mmr="$(get_build_key_or_def "$build_name" "version_mmr")";
ver_mmr="$(mmr_date_repl "$ver_mmr")";
ver_str="$(mmr_to_str "$ver_mmr")";
[ -z "$ver_str" ] && die "Something went wrong regarding versions";

# Initialize Prometheus metrics.
prom_init "jenkins_build_job" "project=\"$proj\", build_name=\"$build_name\", branch=\"$BRANCH\"";
prom_add "success_job" "Whether the job finished successfully or not (1 for success, 0 for error)." "gauge" "";
prom_set "success_job" "0";
prom_add "start_time_job" "UNIX timestamp of job start." "counter" "";
prom_set "start_time_job" "$build_ts";
prom_add "end_time_job" "UNIX timestamp of job start." "counter" "";
prom_set "end_time_job" "0";
prom_add_duration "duration_total" "Duration of the job (either either job or part of it) in seconds." "step=\"total\"" "$build_ts";

# Get the latest tag that contains a SEMVER 2.0 version string.
tag_mmr="$(git_latest_tag_mmr)";

# Check if this is a Jenkins (non-local) build from the master branch.
if [ -z "$local_build" ] && [ "$BRANCH" == "master" ]; then
	# Check if this build was triggered by a Gitlab tag push. If building
	# from master branch the version specified in the build config file
	# must be the same as the latest tag.
	if [ "${gitlabActionType:-}" == "TAG_PUSH" ]; then
		if [ -n "$tag_mmr" ] && mmr_compare "$ver_mmr" "$tag_mmr"; then
			logmsg "Found matching tag: $tag_mmr" "$ME";
		else
			errmsg "tag version: $tag_mmr != build config version: $ver_mmr";
			echo "While building from master branch we must have a tag";
			echo "containing the same version as the one specified in the";
			echo "build config file ($build_conf).";
			die "tag version: $tag_mmr != build config version: $ver_mmr";
		fi
	else
		# We are building a "daily" from master.
		_short_commit="$(echo "$GIT_COMMIT" | cut -c '1-8')";
		_new_meta="C${_short_commit}";
		_old_meta="$(get_dict_key "$ver_mmr" "meta" || true)";
		[ -n "$_old_meta" ] && _new_meta="${_old_meta}.${_new_meta}";
		ver_mmr="$(echo "$ver_mmr" | $_jq ". + {\"label\": \"xdaily.$(timestamp_format "$build_ts" '%Y%m%d%H%M%S')\", \"meta\": \"$_new_meta\"}")";
		ver_str="$(mmr_to_str "$ver_mmr")";
		[ -z "$ver_str" ] && die "Something went wrong regarding versions";
		logmsg "Daily build from the master branch with version: $ver_str" "$ME";
	fi
else
	# We are either doing a local build or a Jenkins build from a non-master
	# branch. In this case we need to mark the build as appropiate and
	# provide branch and possibly merge request information.
	# TODO: This logic doesn't take into account the possibility that
	# _old_meta might already contain branch information.
	_short_commit="$(echo "$GIT_COMMIT" | cut -c '1-8')";
	_new_meta="";
	_new_label="";

	if [ -n "$local_build" ]; then
		_new_label="private.$(timestamp_format "$build_ts" '%Y%m%d%H%M%S')";
	else
		_new_label="internal.$(timestamp_format "$build_ts" '%Y%m%d%H%M%S')";
	fi

	# We need to sanitize the branch name to make sure we conform with the
	# Debian package versioning restrictions: https://www.debian.org/doc/debian-policy/ch-controlfields.html#version
	# (see the subsection titled "https://www.debian.org/doc/debian-policy/ch-controlfields.html#version").
	_branch_sanitized="$(echo "$BRANCH" | sed -E 's/[^[[:alnum:]]]?//g')";
	# Export the value so it can be re-used in later scripts.
	BRANCH_SANITIZED="$_branch_sanitized"; export BRANCH_SANITIZED;

	if [ "${gitlabMergeRequestIid:-0}" -ne "0" ]; then
		_new_meta="B${_branch_sanitized}.MR${gitlabMergeRequestIid}.C${_short_commit}";
	else
		_new_meta="B${_branch_sanitized}.C${_short_commit}";
	fi

	# If this is a local build add username information.
	[ -n "$local_build" ] && _new_meta="${_new_meta}.U$USER";

	_old_meta="$(get_dict_key "$ver_mmr" "meta" || true)";
	[ -n "$_old_meta" ] && _new_meta="${_old_meta}.${_new_meta}";

	ver_mmr="$(echo "$ver_mmr" | $_jq ". + {\"label\": \"${_new_label}\", \"meta\": \"${_new_meta}\"}")";
	ver_str="$(mmr_to_str "$ver_mmr")";
	[ -z "$ver_str" ] && die "Something went wrong regarding versions";
fi

# Write the version we are building to a file so it can be picked up by
# Jenkins.
[ -z "$local_build" ] && echo "$ver_str" > ".jenkins_build_version.txt";

build_job_hash="$(echo "$proj $build_name $ver_str" | $_sha256sum | cut -c '1-12')";
logmsg "Running for project: ${proj}; build_name: ${build_name}; version: ${ver_str}; build_job_hash: ${build_job_hash}" "$ME";


# Prepare the build envoironment which can be composed of one or more docker
# containers.
logmsg "Launching docker container(s) for this build ..." "$ME";
prom_add_duration "duration_prepare" "Duration of the prepare step in seconds." "step=\"prepare\"" "";
docker_prepare "$build_name" "$build_job_hash" "$ssh_agent_fwd";
prom_update_duration "duration_prepare";

prom_add_duration "duration_build" "Duration of the build step in seconds." "step=\"build\"" "";
# Get build steps. Based on the build_name containers configuration we consider
# a valid build step any container which has a non-empty build_script or
# build_commands setting.
build_steps="$(get_build_key_or_def "$build_name" "containers")";
build_steps_len="$(echo "$build_steps" | $_jq -c '. | values | length')";
skip_build_steps="0";
if [ -n "$highlevel_step" ] && [ "_$highlevel_step" != "_build" ]; then
	skip_build_steps="1";
	logmsg "Skipping all build steps due to high level step being '$highlevel_step'" "$ME";
fi

i="0";
while [ "$i" -lt "$build_steps_len" ] && [ "$skip_build_steps" -eq "0" ]; do
	cont_conf="";
	cont_name="";
	dckr_name="";
	build_script="";
	build_commands="";

	cont_conf="$(echo "$build_steps" | $_jq -c ". | values | .[$i]"	\
		| grep -Eiv '^[[:blank:]]*null[[:blank:]]*$')";
	cont_name="$(get_dict_key "$cont_conf" "name")";
	dckr_name="$( echo "${build_job_hash}_${proj}_${cont_name}"	\
		| sed -E "s/$DOCKER_SANITIZER/_/g")";

	# Both build_script and build_commands can be undefined for the current
	# container (build step). 
	build_script="$(get_dict_key "$cont_conf" "build_script" || true)";
	build_commands="$(get_dict_key "$cont_conf" "build_commands" || true)";
	# If build_commands is not defined default to an empty list.
	[ -z "$build_commands" ] && build_commands="[]";

	# If build_commands is defined in the build configuration and is really
	# a non-empty list we need to verify the build_script or provide a
	# default value.
	[ -n "$build_commands" ] && {
		build_commands_len="$(echo "$build_commands" | $_jq -c '. | values | length')";
		[ "$build_commands_len" -gt "0" ] && [ -z "$build_script" ] && {
			build_script="$DEFAULT_BUILD_SCRIPT";
		}

		[ "$build_commands_len" -gt "0" ] && [ ! -x "$build_script" ] && {
			die "Build script '$build_script' does not exist or is not executable";
		}
	}

	# Run the script for the current build step. We'll execute this either
	# because build_script was defined in the configuration in the first
	# place or because build_script was not defined but build_commands
	# was defined and a non-empty list.
	if [ -n "$build_script" ]; then
		logmsg "Running build step inside container '$cont_name' with build script '$build_script'" "$ME";
		$_docker_exec						\
			-e "build_name=$build_name"			\
			-e "build_conf=$build_conf"			\
			-e "build_step=$cont_name"			\
			-e "build_commands=$build_commands"		\
			-e "dckr_name=$dckr_name"			\
			-e "local_build=$local_build"			\
			-e "proj=$proj"					\
			-e "build_ts=$build_ts"				\
			-e "build_date=$build_date"			\
			-e "ver_mmr=$ver_mmr"				\
			-e "ver_str=$ver_str"				\
			-e "__global_debug=$__global_debug"		\
			-e "BRANCH=$BRANCH"				\
			-e "BRANCH_SANITIZED=$BRANCH_SANITIZED"		\
			-e "GIT_COMMIT=$GIT_COMMIT"			\
			-e "GIT_COMMIT_TS=$GIT_COMMIT_TS"		\
			-e "GIT_COMMIT_DATE=$GIT_COMMIT_DATE"		\
			"$dckr_name"					\
			/bin/sh -c -- "$build_script";
	else
		logmsg "Both build_script and build_commands are empty, skipping build step '$cont_name'" "$ME";
	fi

	i="$(( i + 1 ))";
done
prom_update_duration "duration_build";

prom_add_duration "duration_pkg" "Duration of the pkg step in seconds." "step=\"pkg\"" "";
for pkg_suffix in "" "dev" "dbg"; do
	# Get packaging configuration variables.
	conf_key="pkg_script"; [ -n "$pkg_suffix" ] && conf_key="pkg_${pkg_suffix}_script";
	pkg_script="$(get_build_key_or_def "$build_name" "$conf_key" || true)";
	conf_key="pkg_commands"; [ -n "$pkg_suffix" ] && conf_key="pkg_${pkg_suffix}_commands";
	pkg_commands="$(get_build_key_or_def "$build_name" "$conf_key" || true)";
	# If pkg_commands is not defined default to an empty list.
	[ -z "$pkg_commands" ] && pkg_commands="[]";

	# If pkg_commands is defined in the build configuration and is really
	# a non-empty list we need to verify the pkg_script or provide a
	# default value.
	[ -n "$pkg_commands" ] && {
		pkg_commands_len="$(echo "$pkg_commands" | $_jq -c '. | values | length')";
		[ "$pkg_commands_len" -gt "0" ] && [ -z "$pkg_script" ] && {
			pkg_script="$DEFAULT_PKG_SCRIPT";
		}

		[ "$pkg_commands_len" -gt "0" ] && [ ! -x "$pkg_script" ] && {
			die "Package script '$pkg_script' does not exist or is not executable";
		}
	}

	# Run the packaging step.
	if [ -n "$pkg_script" ]; then
		if [ -z "$highlevel_step" ] || [ "_$highlevel_step" == "_package" ]; then
			# Get more packaging configuration variables.
			pkg_cont="$(get_build_key_or_def "$build_name" "pkg_cont" || true)";
			[ -z "$pkg_cont" ] && pkg_cont="$DEFAULT_STEP_CONT";
			pkg_name="$(get_build_key_or_def "$build_name" "pkg_name")";
			pkg_descr="$(get_build_key_or_def "$build_name" "pkg_descr")";
			pkg_group="$(get_build_key_or_def "$build_name" "pkg_group")";
			pkg_deps="$(get_build_key_or_def "$build_name" "pkg_deps")";
			pkg_deps_exact="$(get_build_key_or_def "$build_name" "pkg_deps_exact" || true)";
			pkg_services="$(get_build_key_or_def "$build_name" "pkg_services" || true)";
			pkg_sw_ver_skip="$(get_build_key_or_def "$build_name" "pkg_sw_ver_skip" || true)";

			dckr_name="$( echo "${build_job_hash}_${proj}_${pkg_cont}"	\
				| sed -E "s/$DOCKER_SANITIZER/_/g")";

			logmsg "Running pkg step inside container '$dckr_name' with pkg script '$pkg_script'" "$ME";
			$_docker_exec						\
				-e "build_name=$build_name"			\
				-e "build_conf=$build_conf"			\
				-e "dckr_name=$dckr_name"			\
				-e "local_build=$local_build"			\
				-e "proj=$proj"					\
				-e "build_ts=$build_ts"				\
				-e "build_date=$build_date"			\
				-e "build_job_hash=$build_job_hash"		\
				-e "pkg_name=$pkg_name"				\
				-e "pkg_suffix=$pkg_suffix"			\
				-e "pkg_descr=$pkg_descr"			\
				-e "pkg_group=$pkg_group"			\
				-e "pkg_deps=$pkg_deps"				\
				-e "pkg_deps_exact=$pkg_deps_exact"		\
				-e "pkg_services=$pkg_services"			\
				-e "pkg_sw_ver_skip=$pkg_sw_ver_skip"		\
				-e "pkg_commands=$pkg_commands"			\
				-e "ver_mmr=$ver_mmr"				\
				-e "ver_str=$ver_str"				\
				-e "__global_debug=$__global_debug"		\
				-e "BRANCH=$BRANCH"				\
				-e "GIT_COMMIT=$GIT_COMMIT"			\
				-e "GIT_COMMIT_TS=$GIT_COMMIT_TS"		\
				-e "GIT_COMMIT_DATE=$GIT_COMMIT_DATE"		\
				"$dckr_name"					\
				/bin/sh -c -- "$pkg_script";
		else
			logmsg "Skipping package high level step" "$ME";
		fi
	else
		logmsg "pkg_script is empty, skipping package step" "$ME";
	fi
done
prom_update_duration "duration_pkg";

prom_add_duration "duration_test" "Duration of the test step in seconds." "step=\"test\"" "";
# Get test configuration variables.
test_cont="$(get_build_key_or_def "$build_name" "test_cont" || true)";
[ -z "$test_cont" ] && test_cont="$DEFAULT_STEP_CONT";
test_script="$(get_build_key_or_def "$build_name" "test_script" || true)";

# Run the test step.
if [ -n "$test_script" ]; then
	if [ -z "$highlevel_step" ] || [ "_$highlevel_step" == "_test" ]; then
		dckr_name="$( echo "${build_job_hash}_${proj}_${test_cont}"	\
			| sed -E "s/$DOCKER_SANITIZER/_/g")";

		logmsg "Running test step inside container '$dckr_name' with test script '$test_script'" "$ME";
		$_docker_exec						\
			-e "build_name=$build_name"			\
			-e "build_conf=$build_conf"			\
			-e "dckr_name=$dckr_name"			\
			-e "local_build=$local_build"			\
			-e "proj=$proj"					\
			-e "build_ts=$build_ts"				\
			-e "build_date=$build_date"			\
			-e "build_job_hash=$build_job_hash"		\
			-e "ver_mmr=$ver_mmr"				\
			-e "ver_str=$ver_str"				\
			-e "__global_debug=$__global_debug"		\
			-e "BRANCH=$BRANCH"				\
			-e "GIT_COMMIT=$GIT_COMMIT"			\
			-e "GIT_COMMIT_TS=$GIT_COMMIT_TS"		\
			-e "GIT_COMMIT_DATE=$GIT_COMMIT_DATE"		\
			"$dckr_name"					\
			/bin/sh -c -- "$test_script";
	else
		logmsg "Skipping test high level step" "$ME";
	fi
else
	logmsg "test_script is empty, skipping test step" "$ME";
fi
prom_update_duration "duration_test";

prom_add_duration "duration_upload" "Duration of the upload step in seconds." "step=\"upload\"" "";
# Get upload configuration variables.
upload_script="$(get_build_key_or_def "$build_name" "upload_script" || true)";
upload_cont="$(get_build_key_or_def "$build_name" "upload_cont" || true)";
[ -z "$upload_cont" ] && upload_cont="$DEFAULT_STEP_CONT";

# Run the upload step.
if [ -n "$upload_script" ]; then
	if [ -z "$highlevel_step" ] || [ "_$highlevel_step" == "_upload" ]; then
		# Only run the upload step if this is a Jenkins build, not a
		# local one.
		if [ -z "$local_build" ] || [ "$upload_force" -eq "1" ]; then
			dckr_name="$( echo "${build_job_hash}_${proj}_${upload_cont}"	\
				| sed -E "s/$DOCKER_SANITIZER/_/g")";

			logmsg "Running upload step inside container '$dckr_name' with upload script '$upload_script'" "$ME";
			$_docker_exec					\
				-e "build_name=$build_name"		\
				-e "build_conf=$build_conf"		\
				-e "local_build=$local_build"		\
				-e "proj=$proj"				\
				-e "build_ts=$build_ts"			\
				-e "build_date=$build_date"		\
				-e "build_job_hash=$build_job_hash"	\
				-e "ver_mmr=$ver_mmr"			\
				-e "ver_str=$ver_str"			\
				-e "__global_debug=$__global_debug"	\
				-e "BRANCH=$BRANCH"			\
				-e "GIT_COMMIT=$GIT_COMMIT"		\
				-e "GIT_COMMIT_TS=$GIT_COMMIT_TS"	\
				-e "GIT_COMMIT_DATE=$GIT_COMMIT_DATE"	\
				"$dckr_name"				\
				/bin/sh -c -- "$upload_script";
		fi
	else
		logmsg "Skipping upload step" "$ME";
	fi
else
	logmsg "upload_script is empty, skipping upload step" "$ME";
fi
prom_update_duration "duration_upload";

[ "${keep_containers:-0}" -ne "1" ] && {
	prom_add_duration "duration_cleanup" "Duration of the cleanup step in seconds." "step=\"cleanup\"" "";
	logmsg "All steps finished without errors, removing docker container(s)" "$ME";
	docker_cleanup "$build_name" "$build_job_hash";
	prom_update_duration "duration_cleanup";
}

prom_set "end_time_job" "$(date '+%s')";
prom_update_duration "duration_total";
prom_set "success_job" "1";
prom_push "$proj";
logmsg "Prometheus metrics pushed" "$ME";
