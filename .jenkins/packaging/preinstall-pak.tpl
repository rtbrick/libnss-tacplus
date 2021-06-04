#!/bin/bash

set -ue;

_chmod="$(which chmod)";
_chown="$(which chown)";
_getent="$(which getent)";
_groupadd="$(which groupadd)";
_mkdir="$(which mkdir)";
_useradd="$(which useradd)";

runas_user="{{ .RunAs.User }}";
runas_uid="{{ .RunAs.UID }}";
runas_group="{{ .RunAs.Group }}";
runas_gid="{{ .RunAs.GID }}";
runas_more_groups="{{ .RunAs.MoreGroups }}";

[ "$runas_gid" -ne "0" ] && {
	$_getent group "$runas_group" >/dev/null 2>&1		\
		|| $_groupadd --gid "$runas_gid" "$runas_group";
}

[ "$runas_uid" -ne "0" ] && {
	$_getent passwd "$runas_user" >/dev/null 2>&1 || {
		declare -a ua_args=("--uid" "$runas_uid"	\
			"--gid" "$runas_gid"			\
			"--system"				\
			"--home" "/dev/null"			\
			"--no-create-home"			\
			"--shell" "/bin/false"			\
		);
		[ -n "$runas_more_groups" ]			\
			&& ua_args+=("--groups" "$runas_more_groups");
		ua_args+=("$runas_user");

		$_useradd "${ua_args[@]}";
	}
}

# Ensure the script doesn't finish with a non-zero exit code in case
# runas_uid == 0.
true;

# Add more commands after this line if needed.
