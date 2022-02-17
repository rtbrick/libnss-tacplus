#!/bin/bash

set -ue;

# Find out the codename of the Debian/Ubuntu distribution currently
# running on. This might have already been set.
_codename="${_codename:-$(/usr/bin/lsb_release -s -c || echo 'unknown')}";

# Stop and disable package service if needed.
if [ "__{{ .ServiceName }}" != "__" ] && [ "__{{ .ServiceName }}" != "__ " ]; then
	>&2 echo "Running stop and disable for package service '{{ .ServiceName }}' ...";
	case $_codename in
		bionic|focal|jammy)
			_systemctl="$(which systemctl)"	\
				|| _systemctl="echo [systemctl not found]: would have run: systemctl";

			# Any of the systemctl commands might fail if the
			# package is installed inside a docker container where
			# systemd is not running.
			$_systemctl stop "{{ .ServiceName }}" || true;
			$_systemctl disable "{{ .ServiceName }}" || true;
			;;
		# We use the Debian release code-names to detect when a package
		# is being installed in ONL. Newer Debian versions actually use
		# systemd just like Ubuntu but the ONL build even if it's based
		# on newer Debian versions still uses SysVinit . 
		stretch|buster|bullseye)
			service "{{ .ServiceName }}" stop || true;
			update-rc.d "{{ .ServiceName }}" remove || true;
  			;;
		*)
			echo "Don't know how to correctly uninstall service on distribution '$_codename'";
			exit 1;
  			;;
	esac
fi

# Ensure the script doesn't finish with a non-zero exit code in case the
# previous statement was false.
true;

# Add more commands after this line.

# Verify if /etc/nsswitch.conf contains tacplus and try to cleanup if it does.
cat "/etc/nsswitch.conf" | grep -E '^[[:space:]]*passwd:.*tacplus.*' 1>/dev/null 2>/dev/null && {
	sed -E -i 's/# changed by the rtbrick-libnss-tacplus package//g' "/etc/nsswitch.conf";
	sed -E -i 's/^([[:space:]]*passwd:.*)tacplus(.*)/\1 \2/' "/etc/nsswitch.conf";
}

# Ensure the script doesn't finish with a non-zero exit code in case the
# previous statement was false.
true;
