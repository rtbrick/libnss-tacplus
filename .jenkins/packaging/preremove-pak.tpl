#!/bin/bash

set -ue;

# Find out the codename of the Debian/Ubuntu distribution currently
# running on. This might have already been set.
_codename="${_codename:-$(/usr/bin/lsb_release -s -c || echo 'unknown')}";

# Stop and disable package service if needed.
if [ "__{{ .ServiceName }}" != "__" ] && [ "__{{ .ServiceName }}" != "__ " ]; then
	>&2 echo "Running stop and disable for package service '{{ .ServiceName }}' ...";
	case $_codename in
		bionic)
			_systemctl="$(which systemctl)"	\
				|| _systemctl="echo [systemctl not found]: would have run: systemctl";

			$_systemctl stop "{{ .ServiceName }}";
			$_systemctl disable "{{ .ServiceName }}";
			;;
		stretch)
			service "{{ .ServiceName }}" stop;
			update-rc.d "{{ .ServiceName }}" remove;
  			;;
		*)
			echo "Don't know how to correctly uninstall service on distribution '$_codename'";
			exit 1;
  			;;
	esac
fi

# Add more commands after this line.
