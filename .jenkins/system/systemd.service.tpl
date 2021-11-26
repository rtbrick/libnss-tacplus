[Unit]
Description={{ .ServiceName }} service

# Together with the Restart... options under the [Service] section these
# settings will allow the service to be restarted 3 times within a 7 minute
# interval as per the default values defined in .jenkins/jenkins_shell_functions.sh
# pkg_serv_template() (lines 609-612). If the process fails a 4th time within
# the same 7 minute interval it will not be restarted automatically anymore:
#     https://www.freedesktop.org/software/systemd/man/systemd.unit.html#StartLimitIntervalSec=interval
#
# Units which are restarted more than burst times within the interval are not
# permitted to start any more, not even as a result of a manual start command
# such as `systemctl start <service>` or `systemctl restart <service>`. In
# order to be able to manually start a service which hit the burst limit the
# `systemctl reset-failed` command must be used prior to try to start/restart
# the service.
#
# Values can be customized per service in .jenkins/jenkins_build_conf.json
# -> pkg_services and those will be propagated in this template:
#
# ```json
# "pkg_services": [
# 	{
# 		"name": "rtbrick-something",
# 		"conf": ".bd_startup_config\\/invalid_bd.json",
# 		"start_cmd": "\\/usr\\/local\\/bin\\/rtbrick-something-service \\/etc\\/rtbrick\\/bd\\/config\\/invalid_bd.json"
# 		"restart": "on-failure",
# 		"restart_hold": "30000ms",
# 		"restart_intv": "420",
# 		"restart_limit": "3"
# 	}
# ],
#
StartLimitIntervalSec={{ .StartLimitIntervalSec }}
StartLimitBurst={{ .StartLimitBurst }}

# The user and group as which the service will run are __root__ by default but
# can be customized per service in .jenkins/jenkins_build_conf.json
# -> pkg_services and those will be propagated in this template:
#
# ```json
# "pkg_services": [
# 	{
#         "name": "rtbrick-something",
#         "runas": {
#            "user": "rtbrick_something",
#            "uid": 7901,
#            "group": "rtbrick_something",
#            "gid": 7901,
#            "more_groups": ""
# 	  }
#       }
# ],
# ```
[Service]
Type=simple
TimeOutSec=90
User={{ .RunAs.User }}
Group={{ .RunAs.Group }}
Environment="USER={{ .RunAs.User }}"
Environment="GROUP={{ .RunAs.Group }}"
ExecStart={{ .ServiceStartCmd }}

# EMS (RBMS) Service Registration events:
ExecStartPost=+/bin/bash -c '[ -f "/usr/local/bin/rtbrick-ems-service-event" ] && { /usr/bin/python3 /usr/local/bin/rtbrick-ems-service-event -e start -s "{{ .ServiceName }}" -p "{{ .PackageName }}"; }; /bin/true;'
ExecReload=+/bin/bash -c '[ -f "/usr/local/bin/rtbrick-ems-service-event" ] && { /usr/bin/python3 /usr/local/bin/rtbrick-ems-service-event -e restart -s "{{ .ServiceName }}" -p "{{ .PackageName }}"; }; /bin/true;'
ExecStopPost=+/bin/bash -c '[ -f "/usr/local/bin/rtbrick-ems-service-event" ] && { /usr/bin/python3 /usr/local/bin/rtbrick-ems-service-event -e stop -s "{{ .ServiceName }}" -p "{{ .PackageName }}"; }; /bin/true;'

# Logging stdout, stderr to a file (append mode):
#     https://www.freedesktop.org/software/systemd/man/systemd.exec.html#StandardOutput=
#
# StandardOutput=append:/var/log/{{ .ServiceName }}-service-out.log
# StandardError=append:/var/log/{{ .ServiceName }}-service-err.log
StandardOutput=file:/var/log/{{ .ServiceName }}-service-out.log
StandardError=file:/var/log/{{ .ServiceName }}-service-err.log

# If set to on-failure, the service will be restarted when the process exits
# with a non-zero exit code or is terminated by a signal (including on core dump,
# but excluding signals SIGHUP, SIGINT, SIGTERM or SIGPIPE):
#     https://www.freedesktop.org/software/systemd/man/systemd.service.html#Restart=
#
Restart={{ .ServiceRestart }}

# hold-off timer, sleep 30 seconds before restarting a service (as configured
# with Restart=):
#     https://www.freedesktop.org/software/systemd/man/systemd.service.html#RestartSec=
#
RestartSec={{ .ServiceRestartSec }}

[Install]
WantedBy=multi-user.target
Alias={{ .ServiceName }}.service
