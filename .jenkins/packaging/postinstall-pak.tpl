#!/bin/bash

set -ue;

# We always run a ldconfig , just in case the package installed any
# shared libraries.
ldconfig;

# Find out the codename of the Debian/Ubuntu distribution currently
# running on. This might have already been set.
_codename="${_codename:-$(/usr/bin/lsb_release -s -c || echo 'unknown')}";

# Find out how this script is being called. See man 5 deb-postinst.
# If action == "configure" and param1 is empty then this is the initial
# installation of a package, if param1 is not empty then it should contain
# old-version meaning it's an upgrade of an already installed package.
_deb_script_name="$0";
_deb_action="${1:-}";
_deb_param1="${2:-}";

# Enable and start package service if needed.
# shellcheck disable=SC2050
if [ "__{{ .ServiceName }}" != "__" ] && [ "__{{ .ServiceName }}" != "__ " ]; then
	srv_name="{{ .ServiceName }}";
	>&2 echo "Running enable and start for package service '$srv_name' ...";
	case $_codename in
		bionic|focal)
			_systemctl="$(which systemctl)"	\
				|| _systemctl="echo [systemctl not found]: would have run: systemctl";

			# Any of the systemctl commands might fail if the
			# package is installed inside a docker container where
			# systemd is not running.
			$_systemctl daemon-reload || true;
			$_systemctl enable "$srv_name" || true;
			$_systemctl start "$srv_name" || true;

			# Let's also try to create the required symlinks
			# manually, just in-case any of above commands failed
			# but we do need the service to start at system boot.
			target="/lib/systemd/system/${srv_name}.service";
			[ -f "$target" ] && {
				mkdir -p "/etc/systemd/system/multi-user.target.wants/";

				link="/etc/systemd/system/${srv_name}.service";
				[ -L "$link" ] || {
					ln -v -s "$target" "$link";
				}

				link="/etc/systemd/system/multi-user.target.wants/${srv_name}.service";
				[ -L "$link" ] || {
					ln -v -s "$target" "$link";
				}
			}
			;;
		stretch|buster)
			update-rc.d "$srv_name" defaults;
			# Starting the service will probably fail if the package
			# is installed during an image build.
			service "$srv_name" start || true;
			;;
		*)
			echo "Don't know how to correctly install service on distribution '$_codename'";
			exit 1;
			;;
	esac
fi

# Ensure the script doesn't finish with a non-zero exit code in case the
# previous statement was false.
true;

# Add more commands after this line.

[ ! -f "/etc/tacplus_nss.conf" ] && cp /usr/local/etc/tacplus_nss.conf /etc/tacplus_nss.conf;

# Verify if /etc/nsswitch.conf already contains tacplus. We don't just want to
# overwrite the file since it might be different between Ubuntu vs. Debian, etc.
cat "/etc/nsswitch.conf" | grep -E '^[[:space:]]*passwd:.*tacplus.*' 1>/dev/null 2>/dev/null || {
    sed -E -i 's/^([[:space:]]*passwd:.*)(systemd)/\1tacplus \2 # changed by the rtbrick-libnss-tacplus package/g' "/etc/nsswitch.conf";
}

# Ensure the script doesn't finish with a non-zero exit code in case the
# previous statement was false.
true;
