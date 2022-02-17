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
} >&2;
[ "${__global_debug:-0}" -gt "1" ] && {
	set -x;
	# functrace is bash specific.
	[ "${BASH_VERSION:-0}" != "0" ] && set -o functrace;
}

# Global definitions.

# SONARQUBE_URL is the SonarQube server URL.
SONARQUBE_URL="https://sqube.rtbrick.net";
# SONARQUBE_WORKDIR is the value for the `sonar.working.directory` CLI flag
# which sets the working directory for the analysis. Path must be relative,
# and unique for each project. Beware: the specified folder is deleted before
# each analysis.
SONARQUBE_WORKDIR=".scannerwork";
# SONARQUBE_WRAPPER_OUTDIR is the directory where the SonarQube build wrapper
# script will write it's output if the build wrapper is used.
SONARQUBE_WRAPPER_OUTDIR=".sonarqube_wrapper_outdir";

# Dependencies on other programs which might not be installed. Here we rely on
# values discovered and passed on by the calling script.
_git="${_git:-$(which git)}";
_jq="${_jq:-$(which jq) -er}";
_nproc="$(which nproc)";

# shellcheck disable=SC2034
ME="jenkins_sonarqube.sh";	# Useful for log messages.

proj="${proj:-}"; [ -z "$proj" ] && die "Cannot run a SonarQube analysis without the 'proj' variable.";
build_name="${build_name:-}"; [ -z "$build_name" ] && die "Cannot run a SonarQube analysis without the 'build_name' variable.";
build_job_hash="${build_job_hash:-}"; [ -z "$build_job_hash" ] && die "Cannot run a SonarQube analysis without the 'build_job_hash' variable.";
branch="${BRANCH:-}"; [ -z "$branch" ] && die "Cannot run a SonarQube analysis without a git branch.";
sonarqube_token="${SONARQUBE_TOKEN:-}"; [ -z "$sonarqube_token" ] && die "Cannot run a SonarQube analysis without a SonarQube login token.";
sonar_scanner="$(which sonar-scanner || true)"; [ -z "$sonar_scanner" ] && die "Cannot run a SonarQube analysis without sonar-scanner.";
sonar_conf="${sonar_conf:-}"; [ -z "$sonar_conf" ] && die "Cannot run a SonarQube analysis without a SonarQube config.";
sonar_lang="$(get_dict_key "$sonar_conf" "lang" || true)";
# SonarQube `sources` will have a default of `.` meaning current directory.
sonar_sources="$(get_dict_key "$sonar_conf" "sources" || echo ".")";
sonar_exclusions="$(get_dict_key "$sonar_conf" "exclusions" || true)";
sonar_version="${sonar_version:-}"; [ -z "$sonar_version" ] && die "Cannot run a SonarQube analysis without a version.";

sonar_proj_name="$(get_dict_key "$sonar_conf" "projectName" || true)";
[ -z "$sonar_proj_name" ] && {
	sonar_proj_name="$($_git remote get-url origin			\
				| sed -E 's/^https?:\/\/[^/]+\///'	\
				| sed -E 's/^.*://g'			\
				| sed -E 's/\.git$//g'			\
				| tr '[:upper:]' '[:lower:]')";
}
sonar_proj_key="$(get_dict_key "$sonar_conf" "projectKey" || true)";
[ -z "$sonar_proj_key" ] && {
	sonar_proj_key="$(echo "$sonar_proj_name"			\
				| tr -c '[:alnum:]' '_'			\
				| sed -E 's/_{2,}/_/g'			\
				| sed -E 's/_+$//g')";
}

declare -a sonar_cli_args=(
	"-Dsonar.host.url=$SONARQUBE_URL"				\
	"-Dsonar.login=$sonarqube_token"				\
	"-Dsonar.projectKey=$sonar_proj_key"				\
	"-Dsonar.projectName=$sonar_proj_name"				\
	"-Dsonar.projectVersion=$sonar_version"				\
	"-Dsonar.working.directory=$SONARQUBE_WORKDIR"			\
	"-Dsonar.sources=$sonar_sources"				\
);

[ -n "$sonar_exclusions" ] && {
	sonar_cli_args+=("-Dsonar.exclusions=$sonar_exclusions");
}

[ -n "$sonar_lang" ] && [ "$sonar_lang" == "c" ] || [ "$sonar_lang" == "C" ] && {
	sonar_cli_args+=("-Dsonar.cfamily.cache.enabled=false"				\
		"-Dsonar.cfamily.build-wrapper-output=$SONARQUBE_WRAPPER_OUTDIR"	\
		"-Dsonar.cfamily.threads=$($_nproc)"					\
	);
}

# Check if this build was triggered by a Gitlab merge request.
if [ "${gitlabActionType:-}" == "MERGE" ]; then
	sonar_cli_args+=(						\
		"-Dsonar.pullrequest.key=$gitlabMergeRequestIid"	\
		"-Dsonar.pullrequest.branch=$gitlabSourceBranch"	\
		"-Dsonar.pullrequest.base=$gitlabTargetBranch"		\
	);
else
	sonar_cli_args+=("-Dsonar.branch.name=$branch");
fi

# Get any other keys from the embedded SonarQube config and turn them into
# CLI options. We need to exclude keys that we have already handled or any
# custom keys that are not actually valid SonarQube options (like `lang`).
# NOTE: grep will return an error if the output is empty (all lines have been
# filtered).
keys="$(echo "$sonar_conf" | $_jq 'keys[]'		\
	| grep -E -iv '^lang$'				\
	| grep -E -iv '^host\.url'			\
	| grep -E -iv '^login'				\
	| grep -E -iv '^project(Key|Name|Version)'	\
	| grep -E -iv '^working\.directory'		\
	| grep -E -iv '^sources'			\
	| grep -E -iv '^exclusions'			\
	| grep -E -iv '^pullrequest'			\
	| grep -E -iv '^cfamily\.cache\.enabled'	\
	| grep -E -iv '^cfamily\.build-wrapper-output'	\
	| grep -E -iv '^cfamily\.threads' || true)";
for k in $keys; do
	v="$(echo "$sonar_conf" | $_jq ".\"$k\"")";
	sonar_cli_args+=("-Dsonar.${k}=${v}");
done

####
#### Run the SonarQube analysis.
####
$sonar_scanner "${sonar_cli_args[@]}";
