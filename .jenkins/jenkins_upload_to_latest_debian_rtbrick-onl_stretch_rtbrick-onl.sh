#!/usr/bin/env bash

#
# Based on rtbrick-build-onl/aptly_update_stretch.sh .
# TODO: Clean all this stuff up.
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
# The curl version on Ubuntu 16.04 (xenial) doesn't support --fail-early, we
# need to change this back once we upgrade.
# _curl="$(which curl) --fail --fail-early --silent --show-error";
_curl="$(which curl) --fail --silent --show-error";

ME="jenkins_upload_to_latest_debian_rtbrick-onl_stretch_rtbrick-onl.sh";	# Useful for log messages.

REPO_NAME="latest_debian_rtbrick-onl_stretch_rtbrick-onl";
PUBLISH_PATH="latest/debian/rtbrick-onl";
# https://github.com/aptly-dev/aptly/blob/master/api/publish.go#L44
PUBLISH_PATH_ESCAPED="latest_debian_rtbrick-onl";

APTLY_API_URL="http://pkg.rtbrick.net/aptly-api";
APTLY_API_USER="abjibdevak";
APTLY_API_PASS="ciljOncukmerkyoythiripderm4Opam-";

# shellcheck disable=SC2012
_newest_deb="$(ls -t ./*.deb | head -n 1)";

# TODO: Due to the fact that the aptly api returns "200 OK" even in case of
# errors or problems curl will also return exit code 0 (success). In order to
# detect a problem we need to inspect the returned JSON.
logmsg "Trying to upload package ${_newest_deb} to repository $REPO_NAME" "$ME";
$_curl --user "$APTLY_API_USER:$APTLY_API_PASS"			\
	-XPOST -F "file=@${_newest_deb}" "$APTLY_API_URL/files/$REPO_NAME" | $_jq '.';
$_curl --user "$APTLY_API_USER:$APTLY_API_PASS"			\
	-XPOST "$APTLY_API_URL/repos/$REPO_NAME/file/$REPO_NAME/${_newest_deb}" | $_jq '.';

logmsg "Trying to update published repository at $PUBLISH_PATH" "$ME";
$_curl --user "$APTLY_API_USER:$APTLY_API_PASS"			\
	-XPUT -H 'Content-Type: application/json' 		\
	--data "{\"ForceOverwrite\": true}"			\
	"$APTLY_API_URL/publish/filesystem:nginx:$PUBLISH_PATH_ESCAPED/stretch" | $_jq '.';
