#
# Shell functions used in the jenkins.sh script.
#

# Fail hard and fast. Exit at the first error or undefined variable.
set -ue;

# Since the script will exit at the first error try and print details about the
# command which errored.
trap_debug() {
	local rc="$1";
	local cmd="$2";
	local lineno="$3";
	local file="$4";
	local header="";

	header="$(date "$DATE_FMT") ERROR:";
	[ -t 2 ] && header="\e[91m$header\e[0m";

	>&2 printf "$header command '%s' failed with exit code %d at line %d in %s\n" \
		"$cmd" "$rc" "$lineno" "$file";
	[ -z "$keep_failed" ] && {
		>&2 printf "$header trying to cleanup docker containers and networks\n";
		docker_cleanup "$build_name" "$build_job_hash";
	}
	return "$rc";
}

# Since the script will exit at the first error try and print details about the
# command which errored. The trap_debug function is defined in
# jenkins_shell_functions.sh. errtrace is bash specific.
[ "${BASH_VERSION:-0}" != "0" ] && set -o errtrace;
trap 'trap_debug "$?" "$BASH_COMMAND" "$LINENO" "${BASH_SOURCE[0]}"' ERR;

# Global definitions.

# SEMVER_MATCH is a regexp that can match a SEMVER 2.0 version string and that
# can be used with capture groups to extract each piece of information:
#     \1 -> major
#     \2 -> minor
#     \3 -> rev (patch)
#     \5 -> qualifier (label)
#     \7 -> metadata
SEMVER_MATCH='([0-9]+)\.([0-9]+)\.([0-9]+)(-([^+]+))?(\+(.+))?';

# DEPVER_MATCH is a regexp that can match a package dependency string which may
# contain a version match operation. Currently only the ~= operation is
# supported, meaning a regexp match on the package version. A valid dependency
# string which specifies a version regexp match is for example:
#
#	"rtbrick-libinfra (~= 2\.2\.2\.*something.*)"
#
# Capture groups are:
#     \1 -> package name or entire dep string if the 2nd part doesn't contain a valid version match
#     \2 -> empty string or entire 2nd part it it's a valid version match string
#     \3 -> match type (only ~ is currently supported)
#     \4 -> version match (version regexp match in case of match type ~)
DEPVER_MATCH='^([^()]+)( \(([~]?)= (.*)\))?$';

# GITLAB_URL is the git remote URL used for repositories stored on
# gitlab.rtbrick.net .
GITLAB_URL="git@gitlab.rtbrick.net";

# GITLAB_REF is a regexp that matches a reference to a Gitlab repository,
# optionally with a branch, tag or commit reference and a destination directory:
#
#     eng/rbfs/librtbutils
#     eng/rbfs/librtbutils @ tsdb-prometheus > librtbutils-2
#     eng/rbfs/librtbutils @ 23f37aae > librtbutils-3
#     eng/rbfs/librtbutils @ librtbutils_v1.0 > librtbutils-4
#
# It can be used with capture groups to extract each piece of information:
#     \1 -> repo_path/repo_name
#     \3 -> reference (branch, tag or commit)
#     \5 -> destination directory (if different than repo_name)
GITLAB_REF="([^@>]+)(@([^>]+))?(>(.+))?";

# Setting for the RtBrick internal docker registry.
DOCKER_RTB_REGISTRY_URL="docker.rtbrick.net";
DOCKER_RTB_USERNAME="jenkins-build-scripts";
DOCKER_RTB_TOKEN="Tz3jMdCUMYb1WV-roSc6"; # Valid until 2020-12-31.

# DOCKER_SANITIZER is used for ensure that docker names (for networks &
# containers) don't contain any illegal characters.
DOCKER_SANITIZER='\?|\+|\.|\\|\/|-|:|;';

# DATE_FMT the format for printing date and time in log messages.
DATE_FMT='+%Y-%m-%d %H:%M:%S %Z';

# Software version files and locations.
SW_VERS_LOCATION="${__jenkins_scripts_dir:-./.jenkins}/software_versions";
SW_VERS_TPL="${__jenkins_scripts_dir:-./.jenkins}/software_versions/version.json.tpl";
SW_VERS_INSTALL="/usr/share/rtbrick/packages";

# Dependencies on other programs which might not be installed. If any of these
# are missing the script will exit here with an error.
_apt="$(which apt)";		export _apt;
_bc="$(which bc)";		export _bc;
_git="$(which git)";		export _git;
_jq="$(which jq) -er";		export _jq;
_perl="$(which perl)";		export _perl;
_sha256sum="$(which sha256sum || which sha256)"; export _sha256sum;

# die will exit the script with a specific message on stderr and exit code 1 or
# as specified by the second parameter.
die() {
	local msg="$1";
	local code="${2:-1}";
	local header="";

	header="$(date "$DATE_FMT") FATAL:";
	[ -t 2 ] && header="\e[95m$header\e[0m";

	>&2 printf "$header exiting with code %d: %s\n" "$code" "$msg";
	exit "$code";
}

# logmsg will print a log message out stdout with a timestamp and possibly a
# module name.
logmsg() {
	local msg="$1";
	local mod="${2:-}";
	local header="";

	header="$(date "$DATE_FMT")";
	[ -n "$mod" ] && header="$header $mod:";
	[ -t 1 ] && header="\e[36m$header\e[0m";

	printf "$header %s\n" "$msg";
}

# timestamp_format takes a unixtimestamp numeric value and converts it to a
# date string representation according to the strftime(3) rules. Should be
# executed in a sub-shell:
#
#     val="$(timestamp_format "419846400")";
#

timestamp_format() {
	local ts="$1";
	local fmt="${2:-}";

	[ -z "$fmt" ] && {
		fmt="$(echo "$DATE_FMT" | sed -E 's/^\+//')";
	}

	$_perl -e "use POSIX qw( strftime ); print(strftime(\"$fmt\", localtime($ts)));";

	# Another option is to pass the timestamp as ARGV[0] to perl.
	# $_perl -e "use POSIX qw( strftime ); print(strftime(\"$fmt\", localtime(\$ARGV[0])));" \
	#	"$ts";
}

# get_conf_key will print the value of the corresponding key from the $build_conf
# file or will exit with an error if the key is not found. Should be executed
# in a sub-shell, like so:
#
#     val="$(get_conf_key "key")"
#
get_conf_key() {
	set -ue;

	# build_conf is set by jenkins.sh , but ensure that we don't run if it
	# is not set.
	local build_conf="${build_conf:-}";
	[ -z "$build_conf" ] && { >&2 echo "can't run without build_conf"; exit 2; }

	local key="$1";
	local val="";

	val="$($_jq ".[\"$key\"]" "$build_conf")";
	if [ -z "$val" ] || [ "_$val" == "_null" ]; then
		return 1;
	fi

	echo "$val";
	return 0;
}

# get_build_key_or_def will print the value of the corresponding key in the
# specific build dict or if the key doesn't exist in that specific build dict
# it will take it's value from the __defaults__ dict. It will still exit with
# an error if the key is not found the __defaults__ dict. Should be executed in
# a sub-shell:
#
#     val="$(get_build_key_or_def "build_name" "key")"
#
get_build_key_or_def() {
	set -ue;

	# build_conf is set by jenkins.sh , but ensure that we don't run if it
	# is not set.
	local build_conf="${build_conf:-}";
	[ -z "$build_conf" ] && { >&2 echo "can't run without build_conf"; exit 2; }

	local build="$1";
	local key="$2";
	local val="";

	val="$($_jq ".[\"$build\"][\"$key\"]" "$build_conf" || true)";
	if [ -z "$val" ] || [ "_$val" == "_null" ]; then
		val="$($_jq ".[\"__defaults__\"][\"$key\"]" "$build_conf")";
		if [ -z "$val" ] || [ "_$val" == "_null" ]; then
			return 1;
		fi
	fi

	echo "$val";
	return 0;
}

# get_dict_key will print the value of the corresponding key from the provided
# json dict or will exit with an error if the key is not found. Should be
# executed in a sub-shell, like so:
#
#     val="$(get_dict_key "json_dict" "key")"
#
get_dict_key() {
	set -ue;

	local dict="$1";
	local key="$2";
	local val="";

	val="$(echo "$dict" | $_jq ".[\"$key\"]")";
	if [ -z "$val" ] || [ "_$val" == "_null" ]; then
		return 1;
	fi

	echo "$val";
	return 0;
}

# apt_pkg_match returns the string required to install a package via
# apt/apt-get. This string might contain an exact version using the
# pkg_name=ver syntax supported by apt/apt-get if the initial dependency
# string contains a version match operation as described in the help for
# DEPVER_MATCH.
#
# apt_pkg_match will return only 1 pkg_name=ver string even if the initial
# dependency version match (which maybe a regex) matches on multiple versions
# of the same package. In case of multiple matching versions apt_pkg_match will
# return the newest (highest) version based on SEMVER 2.0 rules.
#
# Should be executed in a sub-shell, like so:
#
#     apt_install_arg="$(apt_pkg_match "dependency string")"
#
apt_pkg_match() {
	set -ue;

	local dep="$1";
	local pkg_name="";
	local match_full="";
	local match_type="";
	local match_val="";

	[ -z "$dep" ] && { echo ""; return 0; };

	pkg_name="$(echo "$dep" | sed -E "s/$DEPVER_MATCH/\\1/g")";
	match_full="$(echo "$dep" | sed -E "s/$DEPVER_MATCH/\\2/g")";
	match_type="$(echo "$dep" | sed -E "s/$DEPVER_MATCH/\\3/g")";
	match_val="$(echo "$dep" | sed -E "s/$DEPVER_MATCH/\\4/g")";

	# If the dependency string doesn't contain a valid version match string
	# then just return it back. It might be a simple package name or it
	# might be something else.
	[ -z "$match_full" ] && { echo "$dep"; return 0; };

	# We could support different match types: = , == , >= , <= , ~=. However
	# currently we only support the regexp match ~= .
	case "__$match_type" in
		__)
			>&2 logmsg "Unsupported match type '$match_type'" "apt_pkg_match";
			return 1;
			;;
		__~)
			;;
		*)
			>&2 logmsg "Unsupported match type '$match_type'" "apt_pkg_match";
			return 1;
			;;
	esac

	# Look through all the available versions of the package and filter only
	# those that match the received version regexp.
	local _vers_list="";
	_vers_list="$($_apt show -a "^${pkg_name}$" 2>/dev/null |	\
		grep -E '^Version:' | awk '{print $2;}' |		\
		grep -E "$match_val")" || {

		>&2 logmsg "Can't find any package named '$pkg_name' with version matching '$match_type= $match_val'" "apt_pkg_match";
		return 1;
	};

	# Filter only package versions which conform to SEMVER 2.0 .
	declare -a _vers_array=();
	for v in $_vers_list; do
		local _semver="";
		_semver="$(echo "$v" | grep -o -E "$SEMVER_MATCH")" || {
			>&2 logmsg "Ignoring non-SEMVER 2.0 version '$v' for '$pkg_name'" "apt_pkg_match";
			continue;
		};
		_vers_array+=("$_semver");
	done

	[ "${#_vers_array[@]}" -eq "0" ] && {
		>&2 logmsg "Package '$pkg_name' doesn't have any SEMVER 2.0 versions" "apt_pkg_match";
		return 1;
	};

	# Pick the newest (highest) version.
	local _ver_newest="$(
		(
			for v in "${_vers_array[@]}"; do
				echo "$v";
			done
		) | sort -V -r | head -n 1
	)";

	# SEMVER 2.0 specifies that a version which contains a label is considered
	# pre-release. Thus 1.2.3 needs to be preferred (considered newer) over
	# 1.2.3-alpha or 1.2.3-rc0 . sort does a numeric + lexicographic pick,
	# thus for this case we need to do an additional check. The current
	# implementation does NOT respect this. Thus 1.2.3-alpha will be preferred
	# over 1.2.3 . TODO: Fix this, it is a bug !
	echo "$pkg_name=$_ver_newest";
}

# mmr_to_str returns the string representation of the SEMVER 2.0 version
# contained in the JSON dict. Should be executed in a sub-shell, like so:
#
#     val="$(mmr_to_str "json_dict")"
#
mmr_to_str() {
	local ver="$1";
	local str="";

	ver_major="$(get_dict_key "$ver" "major" | $_bc)";
	ver_minor="$(get_dict_key "$ver" "minor" | $_bc)";
	ver_rev="$(get_dict_key "$ver" "rev" | $_bc)";
	ver_label="$(get_dict_key "$ver" "label" || true)";
	ver_meta="$(get_dict_key "$ver" "meta" || true)";

	str="$ver_major.$ver_minor.$ver_rev";
	[ -n "$ver_label" ] && str="$str-$ver_label";
	[ -n "$ver_meta" ] && str="$str+$ver_meta";

	echo "$str";
	return 0;
}

# mmr_from_str returns a string containing the JSON representation of a SEMVER
# 2.0 version from a string. It can fail if the received string is not a valid
# SEMVER 2.0 version. Should be executed in a sub-shell, like so:
#
#     json_dict="$(mmr_from_str "ver_str")"
#
mmr_from_str() {
	local ver_str="$1";
	local major="";
	local minor="";
	local rev="";

	# Check if the received string is valid SEMVER 2.0 .
	ver_str="$(echo "$ver_str" | grep -o -E "$SEMVER_MATCH")" || {
		>&2 logmsg "";
		return 1;
	};

	# Extract major.minor.rev from the version string. Use bc to transform
	# strings like 08 to 8.
	major="$(echo "$ver_str" | sed -E "s/$SEMVER_MATCH/\\1/g" | $_bc)";
	minor="$(echo "$ver_str" | sed -E "s/$SEMVER_MATCH/\\2/g" | $_bc)";
	rev="$(echo "$ver_str" | sed -E "s/$SEMVER_MATCH/\\3/g" | $_bc)";
	label="$(echo "$ver_str" | sed -E "s/$SEMVER_MATCH/\\5/g")";
	meta="$(echo "$ver_str" | sed -E "s/$SEMVER_MATCH/\\7/g")";

	echo "{\"major\": $major, \"minor\": $minor, \"rev\": $rev, \"label\": \"$label\", \"meta\": \"$meta\"}";
	return 0;
}

# mmr_compare compares 2 version json dicts for equality (currently it doesn't
# do lower or higher). It returns 0 both as an output and as a return code if
# the 2 versions are identical (not considering metadata information).
mmr_compare() {
	local ver_a="$1";
	local ver_b="$2";

	ver_a_major="$(get_dict_key "$ver_a" "major" | $_bc)";
	ver_a_minor="$(get_dict_key "$ver_a" "minor" | $_bc)";
	ver_a_rev="$(get_dict_key "$ver_a" "rev" | $_bc)";
	ver_a_label="$(get_dict_key "$ver_a" "label" || true)";

	ver_b_major="$(get_dict_key "$ver_b" "major" | $_bc)";
	ver_b_minor="$(get_dict_key "$ver_b" "minor" | $_bc)";
	ver_b_rev="$(get_dict_key "$ver_b" "rev" | $_bc)";
	ver_b_label="$(get_dict_key "$ver_b" "label" || true)";

	if [ "$ver_a_major" -eq "$ver_b_major" ]; then
		if [ "$ver_a_minor" -eq "$ver_b_minor" ]; then
			if [ "$ver_a_rev" -eq "$ver_b_rev" ]; then
				if [ "_$ver_a_label" == "_$ver_b_label" ]; then
					return 0;
				else
					return 1;
				fi
			else
				return 1;
			fi
		else
			return 1;
		fi
	else
		return 1;
	fi
}

# git_latest_tag_mmr retrieves the most recent tag (from the point of view of
# HEAD) in the repo and if the tag contains a valid SEMVER 2.0 version string
# it returns it as a json dict:
# {"major": 1, "minor": 2, "rev": 3, "label": "alpha", meta: "build meta"} .
# If the most recent tag doesn't contain a valid SEMVER 2.0 version string it
# will try to walk all the tags in reverse lexicographical order and return
# the first SEMVER 2.0 version string. If no tags exist or none contains a valid
# SEMVER 2.0 version string it will return an empty string. Should be executed
# in a sub-shell, like so:
#	tag_mmr_dict="$(git_latest_tag_mmr)"
#
git_latest_tag_mmr() {
	local tag="";
	local major="";
	local minor="";
	local rev="";
	local label="";
	local meta="";

	tag="$($_git describe --tag | grep -o -E "$SEMVER_MATCH")" || true;
	[ -z "$tag" ] && {
		tag="$($_git tag -l | sort -r | grep -o -E "$SEMVER_MATCH" | head -n 1)";
	}

	# If $tag is still empty either no tags exist or none contain a valid
	# SEMVER 2.0 version string.
	[ -z "$tag" ] && return 0;

	# Extract major.minor.rev from the tag string. Use bc to transform
	# strings like 08 to 8.
	major="$(echo "$tag" | sed -E "s/$SEMVER_MATCH/\\1/g" | $_bc)";
	minor="$(echo "$tag" | sed -E "s/$SEMVER_MATCH/\\2/g" | $_bc)";
	rev="$(echo "$tag" | sed -E "s/$SEMVER_MATCH/\\3/g" | $_bc)";
	label="$(echo "$tag" | sed -E "s/$SEMVER_MATCH/\\5/g")";
	meta="$(echo "$tag" | sed -E "s/$SEMVER_MATCH/\\7/g")";

	echo "{\"major\": $major, \"minor\": $minor, \"rev\": $rev, \"label\": \"$label\", \"meta\": \"$meta\"}";
	return 0;
}

# TODO: aptly_get_latest needs to be updated to support SEMVER 2.0 .
# aptly_get_latest retrieves the latest version package in the provided
# repository and returns it as json dict: {"major": 1, "minor": 2, "rev": 3}.
# If the package does NOT exist it will return an empty string. It will exit
# with an error only if the API call fails. Should be executed in a sub-shell,
# like so:
#
#     ver_mmr_dict="$(aptly_get_latest "repo_url" "pkg_name")"
#
aptly_get_latest() {
	set -ue;

	local repo_url="$1";
	local pkg_name="$2";
	local api_resp="";
	local ver_str="";
	local major="";
	local minor="";
	local rev="";

	# We first run curl in order to catch any non-zero exit code which
	# would otherwise be harder to handle in a long pipeline (even with
	# the bash pipefail option).
	api_resp="$(curl -sS "$repo_url/packages?q=$pkg_name")";

	ver_str="$(echo "$api_resp" | $_jq . |					\
		grep -E " $pkg_name [0-9]{1,3}\\.[0-9]{1,3}[\\.-][0-9]{1,3} " |	\
		sort -r | head -n 1 | awk '{print $3;}';)";

	# If $ver_str is empty the package name was not found in the repository.
	[ -z "$ver_str" ] && return 0;

	# Extract major.minor.rev from the aptly API response. Use bc to transform
	# strings like 08 to 8.
	major="$(echo "$ver_str" | sed -E 's/([0-9]{1,3})\.[0-9]{1,3}[\.-][0-9]{1,3}/\1/g' | $_bc)";
	minor="$(echo "$ver_str" | sed -E 's/[0-9]{1,3}\.([0-9]{1,3})[\.-][0-9]{1,3}/\1/g' | $_bc)";
	rev="$(echo "$ver_str" | sed -E 's/[0-9]{1,3}\.[0-9]{1,3}[\.-]([0-9]{1,3})/\1/g' | $_bc)";

	echo "{\"major\": \"$major\", \"minor\": \"$minor\", \"rev\": \"$rev\"}";
	return 0;
}

# TODO: aptly_get_latest_rev needs to be updated to support SEMVER 2.0 .
# aptly_get_latest_rev retrieves the latest revision of package with version
# major.minor in the provided repository and returns it as single number. If
# the package does NOT exist with the specific version major.minor it will
# return an empty string. It will exit with an error only if the API call
# fails. Should be executed in a sub-shell, like so:
#
#     latest_rev="$(aptly_get_latest_rev "repo_url" "pkg_name" "major" "minor")"
#
aptly_get_latest_rev() {
	set -ue;

	local repo_url="$1";
	local pkg_name="$2";
	local api_resp="";
	local ver_str="";
	local major="";
	local minor="";
	local rev="";

	# Use bc for 08 -> 8 transformation for recevied parameters.
	major="$(echo "$3" | $_bc)";
	minor="$(echo "$4" | $_bc)";

	# We first run curl in order to catch any non-zero exit code which
	# would otherwise be harder to handle in a long pipeline (even with
	# the bash pipefail option).
	api_resp="$(curl -sS "$repo_url/packages?q=$pkg_name")";

	# The returned version strings might be in the 19.08-07 format or
	# 19.8-7 or 19.8.7 formats (any combination with or without leading 0
	# and with - or . preceding the revision).
	ver_str="$(curl -sS "$repo_url/packages?q=$pkg_name" | $_jq . |	\
		grep -E " $pkg_name 0?$major\\.0?$minor[\\.-][0-9]{1,3} " |	\
		sort -r | head -n 1 | awk '{print $3;}';)";

	# If $ver_str is empty the package name with major.minor was not found
	# in the repository.
	[ -z "$ver_str" ] && return 0;

	# Use bc for 08 -> 8 transformation.
	rev="$(echo "$ver_str" | sed -E 's/0?[0-9]{1,3}\.0?[0-9]{1,3}[\.-](0?[0-9]{1,3})/\1/g' | $_bc)";

	echo "$rev";
	return 0;
}

# pkg_serv_template takes a source template file and creates destination while
# replacing all variable occurrences. NOTE: this is NOT a generic templating
# function. Should be called directly (not in a sub-shell), like so:
#	pkg_serv_template "src.json.tpl" "dst.json"	\
#		"$service_name"				\
#		"$service_start_cmd";
pkg_serv_template() {
	set -eu;

	local src="${1:-}";
	local dst="${2:-}";
	local service_name="${3:-}";
	local service_start_cmd="${4:-}";

	[ -n "$src" ]			&& cp "$src" "$dst";
	[ -n "${service_name}" ]	&& sed -i "s/{{ .ServiceName }}/${service_name}/g" "$dst";
	[ -n "${service_start_cmd}" ]	&& sed -i "s/{{ .ServiceStartCmd }}/${service_start_cmd}/g" "$dst";

	# The return code of the function is the return code of the last
	# command. Above even if we handle `[ -n "${.......}" ]` being false,
	# thus `set -eu` will not complain, there is still the problem that our
	# function will return false.
	return 0;
}


# sw_ver_template takes a source template file and creates destination while
# replacing all variable occurrences. NOTE: this is NOT a generic templating
# function. Should be called directly (not in a sub-shell), like so:
#	sw_ver_template "src.json.tpl" "dst.json"	\
#		"$project"				\
#		"$ver_str"				\
#		"$branch"				\
#		"$git_commit"				\
#		"$git_commit_ts"			\
#		"$build_ts";
sw_ver_template() {
	set -eu;

	local src="${1:-}";
	local dst="${2:-}";
	local project="${3:-}";
	local ver_str="${4:-}";
	local branch="${5:-}";
	local git_commit="${6:-}";
	local git_commit_ts="${7:-}";
	local build_ts="${8:-}";

	[ -n "$src" ]			&& cp "$src" "$dst";
	[ -n "${project}" ]		&& sed -i "s/{{ .project }}/${project}/g" "$dst";
	[ -n "${ver_str}" ]		&& sed -i "s/{{ .ver_str }}/${ver_str}/g" "$dst";
	[ -n "${branch}" ]		&& sed -i "s/{{ .branch }}/${branch}/g" "$dst";
	[ -n "${git_commit}" ]		&& sed -i "s/{{ .git_commit }}/${git_commit}/g" "$dst";
	[ -n "${git_commit_ts}" ]	&& sed -i "s/{{ .git_commit_ts }}/${git_commit_ts}/g" "$dst";
	[ -n "${build_ts}" ]		&& sed -i "s/{{ .build_ts }}/${build_ts}/g" "$dst";

	# The return code of the function is the return code of the last
	# command. Above even if we handle `[ -n "${build_ts}" ]` being false,
	# thus `set -eu` will not complain, there is still the problem that our
	# function will return false.
	return 0;
}

gitlab_clone_or_update() {
	set -ue;

	local repo="$1";
	local ref="$2";
	local dir="$3";
	local me="gitlab_clone_or_update";
	local remote_url="${GITLAB_URL}:${repo}.git";

	local git_clone_log="${__jenkins_scripts_dir:-./.jenkins}/git_clone_update.log";
	echo "$git_clone_log" | grep -E '^/' 1>/dev/null || {
		git_clone_log="$PWD/$git_clone_log";
	};

	# TODO: Investigate whether it is better (safer ?)
	# to do this via git submodule instead of
	# git clone.

	local _initial_dir="$PWD";
	if [ -d "$dir" ]; then (
		# https://github.com/koalaman/shellcheck/wiki/SC2103
		cd "$dir";
		# Limit git commands to the current directory and not the
		# parent.
		_l_git="$_git --git-dir=$PWD/.git --work-tree=$PWD";
		# Check if this is already a git repository. If it is not it
		# might be empty or something else. That case is handled lower
		# in this function.
		tmp="$($_l_git status 2>&1)" && {
			# Check if it points to the right repository.
			tmp="$($_l_git remote -v | grep -m 1 -E "$remote_url")" || {
				logmsg "Git repository already exists in path '$dir' but points to different remote (was expecting '$remote_url')";
				false;
			}

			logmsg "Updating $repo @ $ref > $dir" "$me";
			tmp="$($_l_git fetch --all 2>&1)" || {
				# Since we are capturing the output it will
				# not show up in the normal trace generated
				# messages.
				>&2 echo "$tmp" && false;
			};
			tmp="$($_l_git checkout "$ref" 2>&1)" || {
				>&2 echo "$tmp" && false;
			};
			tmp="$($_l_git status | grep -E '^HEAD detached at' 2>&1)" || {
				tmp="$($_l_git pull 2>&1)" || {
					>&2 echo "$tmp" && false;
				};
			};

			_l_branch="$($_l_git branch --no-color | grep -E -m 1 '^[[:space:]]*\*[[:space:]]*'  \
					| sed -E 's/^[[:space:]]*\*[[:space:]]*//g')";
			_l_git_commit="$($_l_git rev-parse HEAD)";
			_l_git_commit_ts="$($_l_git show --no-patch '--format=%ct' "$_l_git_commit")";
			_l_git_commit_date="$(timestamp_format "$_l_git_commit_ts")";

			cat <<-EOF >> "$git_clone_log"
			          
			        - git_dep: $repo @ $ref > $dir
			          git_dep_branch: $_l_branch
			          git_dep_commit: $_l_git_commit
			          git_dep_commit_ts: $_l_git_commit_ts
			          git_dep_commit_date: $_l_git_commit_date
			EOF

			sw_ver_template "${_initial_dir}/$SW_VERS_TPL"				\
				"${_initial_dir}/$SW_VERS_LOCATION/$(basename "$repo").json"	\
				"$(basename "$repo")"			\
				""					\
				"$_l_branch"				\
				"$_l_git_commit"			\
				"$_l_git_commit_ts"			\
				"";
		});
	else
		mkdir -p "$dir";
		logmsg "Cloning $repo @ $ref > $dir" "$me";
		tmp="$($_git clone "${GITLAB_URL}:${repo}.git" "$dir" 2>&1)" || {
			>&2 echo "$tmp" && false;
		};
		(
			cd "$dir";
			# Limit git commands to the current directory and not the
			# parent.
			_l_git="$_git --git-dir=$PWD/.git --work-tree=$PWD";
			tmp="$($_l_git checkout "$ref" 2>&1)" || {
				>&2 echo "$tmp" && false;
			};

			_l_branch="$($_l_git branch --no-color | grep -E -m 1 '^[[:space:]]*\*[[:space:]]*'  \
					| sed -E 's/^[[:space:]]*\*[[:space:]]*//g')";
			_l_git_commit="$($_l_git rev-parse HEAD)";
			_l_git_commit_ts="$($_l_git show --no-patch '--format=%ct' "$_l_git_commit")";
			_l_git_commit_date="$(timestamp_format "$_l_git_commit_ts")";

			cat <<-EOF >> "$git_clone_log"
			          
			        - git_dep: $repo @ $ref > $dir
			          git_dep_branch: $_l_branch
			          git_dep_commit: $_l_git_commit
			          git_dep_commit_ts: $_l_git_commit_ts
			          git_dep_commit_date: $_l_git_commit_date
			EOF

			sw_ver_template "${_initial_dir}/$SW_VERS_TPL"				\
				"${_initial_dir}/$SW_VERS_LOCATION/$(basename "$repo").json"	\
				"$(basename "$repo")"			\
				""					\
				"$_l_branch"				\
				"$_l_git_commit"			\
				"$_l_git_commit_ts"			\
				"";
		);
	fi
}

# docker_prepare will start the set of container(s) with the specified image(s)
# and will prepare for the build by installing the necessary build dependencies.
# Not all the containers need to be actively involved in the build steps, some
# may be ancillary containers list used to provide services like databases, etc.
#
# It should be run directly and NOT as a sub-shell:
#
#     docker_prepare "build_name" "build_job_hash"
#
docker_prepare() {
	set -ue;

	local build_name="$1";
	local build_job_hash="$2";
	local global_ssh_agent_fwd="${3:-0}";

	local proj="";
	local new_conts="";
	local new_conts_len="";
	local new_conts_hosts="";
	local new_conts_network="";

	local apt_resolv_script="jenkins_resolve_apt_dep.sh";

	if [ -x "./$apt_resolv_script" ]; then
		apt_resolv_script="./$apt_resolv_script";
	else
		if [ -x "${__jenkins_scripts_dir:-./.jenkins}/$apt_resolv_script" ]; then
			apt_resolv_script="${__jenkins_scripts_dir:-./.jenkins}/$apt_resolv_script";
		fi
	fi

	# Get build configuration variables.
	proj="$(get_build_key_or_def "$build_name" "project")";

	# Create a build specific network.
	new_conts_network="$(echo "${build_job_hash}_${proj}_build_net"	\
		| sed -E "s/$DOCKER_SANITIZER/_/g")";
	logmsg "Creating network '$new_conts_network'" "docker_prepare";
	docker network create --internal --attachable "$new_conts_network";

	# Get the list of containers. We will walk this list multiple times.
	# This seems slightly inefficient and does make the function longer but
	# each step individually is simpler.
	new_conts="$(get_build_key_or_def "$build_name" "containers")";
	new_conts_len="$(echo "$new_conts" | $_jq -c '. | values | length')";

	# Create containers.
	local i="0";
	while [ "$i" -lt "$new_conts_len" ]; do
		local -a dckr_cmd_args=("run");
		local cont_conf="";
		local cont_name="";
		local dckr_name="";
		local dckr_rtb_reg="";
		local cont_image="";
		local cont_start_cmd="";
		local image_start_cmd="";
		local cont_image_info="";

		cont_conf="$(echo "$new_conts" | $_jq -c ". | values | .[$i]"	\
			| grep -Eiv '^[[:blank:]]*null[[:blank:]]*$')";
		cont_name="$(get_dict_key "$cont_conf" "name")";
		dckr_name="$( echo "${build_job_hash}_${proj}_${cont_name}"		\
			| sed -E "s/$DOCKER_SANITIZER/_/g")";
		cont_image="$(get_dict_key "$cont_conf" "image")";
		cont_start_cmd="$(get_dict_key "$cont_conf" "start_cmd" || true)";

		[ -z "$cont_name" ] && {
			logmsg "Can't find build container name (list index $i)." \
				"docker_prepare";
			return 1;
		}

		[ -z "$cont_image" ] && {
			logmsg "Can't find build container image (list index $i)." \
				"docker_prepare";
			return 1;
		}

		# Check if the container image name points to our internal
		# registry.
		# shellcheck disable=SC2034
		dckr_rtb_reg="$(echo "$cont_image" | grep -E "^$DOCKER_RTB_REGISTRY_URL")" && {
			# Check if we are already logged in.
			# shellcheck disable=SC2034
			dckr_rtb_reg="$($_jq '.auths | keys[]' < "$HOME/.docker/config.json" | grep -E "^$DOCKER_RTB_REGISTRY_URL")" || {
				# Try to login.
				docker login -u "$DOCKER_RTB_USERNAME" -p "$DOCKER_RTB_TOKEN" "$DOCKER_RTB_REGISTRY_URL";
			}

			# If this is an internal registry image always try to update it
			# before a build. For external images we only try to download it
			# if the image doesn't already exist. Although for RBFS builds we
			# we must only use images on the internal docker registry.
			docker pull "$cont_image";
		}

		cont_image_info="$(docker image inspect "$cont_image")" || {
			logmsg "Trying to download container image '$cont_image'" \
				"docker_prepare";
			docker pull "$cont_image";
			cont_image_info="$(docker image inspect "$cont_image")";
		};

		# Build the list of arguments for the docker run command.
		dckr_cmd_args+=("--name=$dckr_name" "-d"		\
			"--hostname=$dckr_name"				\
			"--label" "jenkins_build_name=$build_name"	\
			"--label" "jenkins_build_job_hash=$build_job_hash"	\
			"--label" "jenkins_build_proj=$proj"		\
		);

		if [ "$global_ssh_agent_fwd" -eq "1" ]; then
			dckr_cmd_args+=("--label" "ssh_agent_fwd=true"	\
				"-v" "$SSH_AUTH_SOCK:/ssh-agent-sock"	\
				"--env" "SSH_AUTH_SOCK=/ssh-agent-sock"	\
			);
		fi

		dckr_cmd_args+=("-v" "$PWD:/development/$proj"		\
			"-w" "/development/$proj"			\
			"--env" "project=$proj"				\
			"--env" "build_name=$build_name"		\
			"--env" "build_job_hash=$build_job_hash"		\
			"$cont_image"					\
		);

		if [ -z "$cont_start_cmd" ]; then
			# If the build_step config did not provide us with a start
			# command for the container we need to look at what is
			# the default for the image.
			image_start_cmd="$(echo "$cont_image_info"		\
				| jq -er '.[0].Config.Cmd | .[] | values'	\
				| awk '{printf("%s ", $0)}'			\
				| sed -E 's/^[[:blank:]]*//g'			\
				| sed -E 's/[[:blank:]]*$//g')";
			case "__$image_start_cmd" in
				__)
					;;
				__/bin/sh)
					image_start_cmd=""; ;;
				__/bin/bash)
					image_start_cmd=""; ;;
				__/usr/bin/bash)
					image_start_cmd=""; ;;
				__/usr/local/bin/bash)
					image_start_cmd=""; ;;
				*)
					;;
			esac
		fi

		# Start the container.
		logmsg "Starting docker container '$dckr_name'" "docker_prepare";
		if [ -n "$cont_start_cmd" ]; then
			# Use the start command provided by the build_step.
			# shellcheck disable=SC2086
			docker "${dckr_cmd_args[@]}" $cont_start_cmd;
		else
			if [ -n "$image_start_cmd" ]; then
				# Use the default start command of the image.
				docker "${dckr_cmd_args[@]}";
			else
				# Use our custom start command so the container
				# doesn't exit immediately.
				docker "${dckr_cmd_args[@]}"	\
					/bin/sh -c 'while true; do sleep 300; done';
			fi
		fi

		i="$(( i + 1 ))";
	done

	# Verify that all containers are running.
	local i="0";
	while [ "$i" -lt "$new_conts_len" ]; do
		local cont_conf="";
		local cont_name="";
		local dckr_name="";

		cont_conf="$(echo "$new_conts" | $_jq -c ". | values | .[$i]"	\
			| grep -Eiv '^[[:blank:]]*null[[:blank:]]*$')";
		cont_name="$(get_dict_key "$cont_conf" "name")";
		dckr_name="$( echo "${build_job_hash}_${proj}_${cont_name}"	\
			| sed -E "s/$DOCKER_SANITIZER/_/g")";

		local cont_info="";
		local cont_status="";

		cont_info="$(docker inspect "$dckr_name")";
		cont_status="$(echo "$cont_info" | $_jq ".[0].State.Status"	\
			| grep -Eiv '^[[:blank:]]*null[[:blank:]]*$')";
		if [ "_$cont_status" != "_running" ]; then
			logmsg "Container $dckr_name is not running" "docker_prepare";
			return 1;
		fi

		i="$(( i + 1 ))";
	done

	# Install any package dependencies. Note that this works sequentially,
	# we could try and install in all the containers in parallel but that
	# complicates this step. If a container needs a lot of dependencies
	# which take a lot of time to install it is better to build a custom
	# container image with them pre-installed.
	local i="0";
	while [ "$i" -lt "$new_conts_len" ]; do
		local cont_conf="";
		local cont_name="";
		local dckr_name="";

		cont_conf="$(echo "$new_conts" | $_jq -c ". | values | .[$i]"	\
				| grep -Eiv '^[[:blank:]]*null[[:blank:]]*$')";
		cont_name="$(get_dict_key "$cont_conf" "name")";
		dckr_name="$(echo "${build_job_hash}_${proj}_${cont_name}" \
				| sed -E "s/$DOCKER_SANITIZER/_/g")";

		local cont_deps="";

		cont_deps="$(get_dict_key "$cont_conf" "deps" || true)";
		if [ -n "$cont_deps" ]; then
			logmsg "Installing dependencies in container '$dckr_name'" \
				"docker_prepare";
			# What can happen is a that the current build tries to update
			# at the same time another build finishes and is uploading
			# it's package.
			local _apt_retries="3";
			local _apt_retry_wait="3";
			local _apt_update_success="0";
			while [ "$_apt_update_success" -eq "0" ] && [ "$_apt_retries" -gt "0" ]; do
				docker exec -e "DEBIAN_FRONTEND=noninteractive"	\
					"$dckr_name"				\
					apt-get update -qq || {
					# Update failed.
					_apt_retries="$(( _apt_retries - 1 ))";
					_apt_retry_wait="$(( _apt_retry_wait + 2 ))";
					sleep "$_apt_retry_wait";
					continue;
				};
				_apt_update_success="1";
			done

			[ "$_apt_update_success" -ne "1" ] && \
				die "APT update failed even after several retries.";

			declare -a _deps=();
			local _deps_len="";
			local j="0";
			_deps_len="$(echo "$cont_deps" | $_jq '. | length')";
			while [ "$j" -lt "$_deps_len" ]; do
				local _dep="";
				local _dep_resolved="";
				_dep="$(echo "$cont_deps" | $_jq ".[$j]")";
				# Resolving the exact dependency version needs to happen
				# inside the respective container.
				_dep_resolved="$(docker exec						\
					-e "DEBIAN_FRONTEND=noninteractive"				\
					-e "__jenkins_scripts_dir=${__jenkins_scripts_dir:-./.jenkins}"	\
					"$dckr_name"							\
					$apt_resolv_script "$_dep")";

				logmsg "Package dependency '$_dep' resolved to '$_dep_resolved'"  "docker_prepare";

				_deps+=("$_dep_resolved");

				j="$(( j + 1 ))";
			done

			docker exec -e "DEBIAN_FRONTEND=noninteractive"				\
				"$dckr_name"							\
				apt-get install -yqq --allow-downgrades --allow-unauthenticated	\
				"${_deps[@]}";
		fi

		i="$(( i + 1 ))";
	done

	# Install any git repository dependencies from gitlab.rtbrick.net .
	local i="0";
	while [ "$i" -lt "$new_conts_len" ]; do
		local cont_conf="";
		local cont_name="";
		local dckr_name="";

		cont_conf="$(echo "$new_conts" | $_jq -c ". | values | .[$i]"	\
				| grep -Eiv '^[[:blank:]]*null[[:blank:]]*$')";
		cont_name="$(get_dict_key "$cont_conf" "name")";
		dckr_name="$(echo "${build_job_hash}_${proj}_${cont_name}" \
				| sed -E "s/$DOCKER_SANITIZER/_/g")";

		local git_deps="";
		local git_deps_len="";

		git_deps="$(get_dict_key "$cont_conf" "gitlab_repos" || true)";

		if [ -n "$git_deps" ]; then
			logmsg "Cloning gitlab repositories for container '$dckr_name'" \
				"docker_prepare";
			git_deps_len="$(echo "$git_deps" | $_jq '. | length')";
			local git_clone_log="${__jenkins_scripts_dir:-./.jenkins}/git_clone_update.log";
			echo -n > "$git_clone_log";
			j="0";
			while [ "$j" -lt "$git_deps_len" ]; do
				local dep="";
				local repo="";
				local ref="";
				local dir="";
				local tmp="";

				dep="$(echo "$git_deps" | $_jq ".[$j]")";
				dep="$(echo "$dep" | tr -d '[:blank:]' | grep -E -o "$GITLAB_REF")";
				[ -z "$dep" ] && {
					logmsg "Can't find a correct gitlab dependency reference for index $i"	\
						"docker_prepare";
					j="$(( j + 1 ))";
					continue;
				};

				repo="$(echo "$dep" | sed -E "s/$GITLAB_REF/\1/g" | tr -d '[:blank:]')";
				ref="$(echo "$dep" | sed -E "s/$GITLAB_REF/\3/g" | tr -d '[:blank:]')";
				dir="$(echo "$dep" | sed -E "s/$GITLAB_REF/\5/g"| tr -d '[:blank:]')";

				[ -z "$ref" ] && ref="master";
				[ -z "$dir" ] && dir="$(basename "$repo")";

				gitlab_clone_or_update "$repo" "$ref" "$dir";

				j="$(( j + 1 ))";
			done
		fi

		i="$(( i + 1 ))";
	done

	# Connect the container to the build specific network.
	local i="0";
	while [ "$i" -lt "$new_conts_len" ]; do
		local cont_conf="";
		local cont_name="";
		local dckr_name="";

		cont_conf="$(echo "$new_conts" | $_jq -c ". | values | .[$i]"	\
			| grep -Eiv '^[[:blank:]]*null[[:blank:]]*$')";
		cont_name="$(get_dict_key "$cont_conf" "name")";
		dckr_name="$( echo "${build_job_hash}_${proj}_${cont_name}"	\
			| sed -E "s/$DOCKER_SANITIZER/_/g")";

		docker network connect "$new_conts_network" "$dckr_name";

		local cont_info="";
		local cont_addr="";
		local inspect_path=".[0].NetworkSettings.Networks[\"$new_conts_network\"].IPAddress";

		cont_info="$(docker inspect "$dckr_name")";
		cont_addr="$(echo "$cont_info" | $_jq "$inspect_path"	\
			| grep -Eiv '^[[:blank:]]*null[[:blank:]]*$')";
		if [ -z "$cont_addr" ]; then
			logmsg "Can't find container $dckr_name IPv4 address"	\
				"docker_prepare";
			return 1;
		fi
		new_conts_hosts="$(printf "%s\\n%s\\t%s\\t%s\\n"	\
			"$new_conts_hosts" "$cont_addr" "$cont_name" "$dckr_name")";

		i="$(( i + 1 ))";
	done

	# Add the hosts entries so every container can reach every other
	# container by name.
	local i="0";
	while [ "$i" -lt "$new_conts_len" ]; do
		local cont_conf="";
		local cont_name="";
		local dckr_name="";

		cont_conf="$(echo "$new_conts" | $_jq -c ". | values | .[$i]"	\
			| grep -Eiv '^[[:blank:]]*null[[:blank:]]*$')";
		cont_name="$(get_dict_key "$cont_conf" "name")";
		dckr_name="$( echo "${build_job_hash}_${proj}_${cont_name}"	\
			| sed -E "s/$DOCKER_SANITIZER/_/g")";

		# shellcheck disable=SC2016
		docker exec -e "new_conts_hosts=$new_conts_hosts"	\
			"$dckr_name"					\
			/bin/sh -uec 'echo "$new_conts_hosts" >> /etc/hosts';

		i="$(( i + 1 ))";
	done
}

# docker_cleanup will try to stop and remove all containers related to a build.
# It should be run directly and NOT as a sub-shell:
#
#     docker_cleanup "build_name" "build_job_hash"
#
docker_cleanup() {
	set -ue;

	local build_name="$1";
	local build_job_hash="$2";

	local proj="";
	local new_conts="";
	local new_conts_len="";
	local new_conts_hosts="";
	local new_conts_network="";

	# Get build configuration variables.
	proj="$(get_build_key_or_def "$build_name" "project")";

	# Get the list of containers.
	new_conts="$(get_build_key_or_def "$build_name" "containers")";
	new_conts_len="$(echo "$new_conts" | $_jq -c '. | values | length')";

	# Destroy containers.
	local i="0";
	while [ "$i" -lt "$new_conts_len" ]; do
		local cont_conf="";
		local cont_name="";
		local dckr_name="";

		cont_conf="$(echo "$new_conts" | $_jq -c ". | values | .[$i]"	\
			| grep -Eiv '^[[:blank:]]*null[[:blank:]]*$')";
		cont_name="$(get_dict_key "$cont_conf" "name")";
		dckr_name="$( echo "${build_job_hash}_${proj}_${cont_name}"	\
			| sed -E "s/$DOCKER_SANITIZER/_/g")";

		docker_remove "$dckr_name";

		i="$(( i + 1 ))";
	done

	# Remove the build specific network.
	new_conts_network="$(echo "${build_job_hash}_${proj}_build_net"	\
		| sed -E "s/$DOCKER_SANITIZER/_/g")";
	old_net="$(docker network ls | awk '{print $2;}'	\
		| grep -E "^${new_conts_network}$" | awk '{print $1;}')";
	if [ -n "$old_net" ]; then
		logmsg "Removing network '$new_conts_network'" "docker_cleanup";
		docker network rm "$new_conts_network";
	fi
}

# docker_remove will stop and delete a container with name. It should be run
# directly and NOT as a sub-shell:
#
#     docker_remove "cont_name"
#
docker_remove() {
	set -ue;

	local cont_name="$1";
	local old_cont="";
	local rm_in_progress_delay="0";

	# Check if a container with the same name already exists, either running
	# or stopped.
	old_cont="$(docker container ls --all | grep -E "${cont_name}$"	\
		| awk '{print $1;}')";
	if [ -n "$old_cont" ]; then
		logmsg "Stopping container '$dckr_name'" "docker_remove";
		docker container stop "$old_cont";
		rm_in_progress_delay="5";
	fi
	# If the container was created with the --rm option it will be removed
	# automatically by the stop command above, but if not we need to do it.
	# However if the container stop command was called it might take a few
	# seconds to remove the container during which it will return an error.
	sleep "$rm_in_progress_delay";
	old_cont="$(docker container ls --all | grep -E "${cont_name}$"	\
		| awk '{print $1;}')";
	if [ -n "$old_cont" ]; then
		logmsg "Deleting container '$dckr_name'" "docker_remove";
		docker container rm "$old_cont";
	fi
}

# Sentinel function to verify that this file is actually loaded successfully in
# another script.
jenkins_shell_functions_loaded() {
	return 0;
}
