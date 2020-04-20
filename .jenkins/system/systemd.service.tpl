[Unit]
Description={{ .ServiceName }} service

# Together with the Restart... options under the [Service] section these
# settings will allow the service to be restarted 3 times within a 60 sec
# interval. If the process fails a 4th time it will not be restarted
# automatically anymore.
#     https://www.freedesktop.org/software/systemd/man/systemd.unit.html#StartLimitIntervalSec=interval
#
# Units which are started more than burst times within an interval time interval are not permitted to start any more.
#
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
Environment="USER=root"
ExecStart={{ .ServiceStartCmd }}

# Logging stdout, stderr to a file (append mode):
#     https://www.freedesktop.org/software/systemd/man/systemd.exec.html#StandardOutput=
#
# StandardOutput=append:/var/log/{{ .ServiceName }}-service-out.log
# StandardError=append:/var/log/{{ .ServiceName }}-service-err.log
StandardOutput=file:/var/log/{{ .ServiceName }}-service-out.log
StandardError=file:/var/log/{{ .ServiceName }}-service-err.log

# If set to on-failure, the service will be restarted when the process exits
# with a non-zero exit code, is terminated by a signal (including on core dump,
# but excluding signals SIGHUP, SIGINT, SIGTERM or SIGPIPE.
#     https://www.freedesktop.org/software/systemd/man/systemd.service.html#Restart=
#
Restart=on-failure

# The time to sleep before restarting a service (as configured with Restart=).
#     https://www.freedesktop.org/software/systemd/man/systemd.service.html#RestartSec=
#
RestartSec=10000ms

[Install]
WantedBy=multi-user.target
Alias={{ .ServiceName }}.service
