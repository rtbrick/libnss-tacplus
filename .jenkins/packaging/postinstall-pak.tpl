#!/bin/bash

set -ue;

# We always run a ldconfig , just in case the package installed any
# shared libraries.
ldconfig;

# Find out the codename of the Debian/Ubuntu distribution currently
# running on. This might have already been set.
_codename="${_codename:-$(/usr/bin/lsb_release -s -c || echo 'unknown')}";

# Enable and start package service if needed.
if [ "__{{ .ServiceName }}" != "__" ] && [ "__{{ .ServiceName }}" != "__ " ]; then
	>&2 echo "Running enable and start for package service '{{ .ServiceName }}' ...";
	case $_codename in
		bionic)
			_systemctl="$(which systemctl)"	\
				|| _systemctl="echo [systemctl not found]: would have run: systemctl";
	
			$_systemctl daemon-reload;
			$_systemctl enable "{{ .ServiceName }}";
			$_systemctl start "{{ .ServiceName }}";
			;;
		stretch)
			update-rc.d "{{ .ServiceName }}" defaults;
			service "{{ .ServiceName }}" start;
  			;;
		*)
			echo "Don't know how to correctly install service on distribution '$_codename'";
			exit 1;
  			;;
	esac
fi

# Add more commands after this line.

[ ! -f "/etc/tacplus_nss.conf" ] && cp /usr/local/etc/tacplus_nss.conf /etc/tacplus_nss.conf;

# Verify if /etc/nsswitch.conf already contains tacplus. We don't just want to
# overwrite the file since it might be different between Ubuntu vs. Debian, etc.
cat "/etc/nsswitch.conf" | grep -E '^[[:space:]]*passwd:.*tacplus.*' 1>/dev/null 2>/dev/null || {
    sed -E -i 's/^([[:space:]]*passwd:.*)(systemd)/\1tacplus \2 # changed by the rtbrick-libnss-tacplus package/g' "/etc/nsswitch.conf";
}
