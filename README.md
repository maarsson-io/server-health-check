# Server Health Check

A lightweight tool for weekly health reports from Ubuntu servers.

The initial scope is APT update availability and reboot status, with email delivery. Each server will send a weekly report, even when no action is required.

The tool will not install package updates or reboot servers.

## Status

Early development. Configuration initialization, validation, test email delivery,
APT update analysis, reboot, unattended-upgrades, failed-service and clock
synchronization and logrotate checks, email reports, and a weekly systemd timer are available.

## Usage

From the project directory on an Ubuntu server:

```sh
./bin/server-health-check --help
sudo ./bin/server-health-check init-config
sudo ./bin/server-health-check validate-config
```

The `init-config` command creates `/etc/server-health-check.conf` from the example with
root-only access. If the path already exists, it stops without changing it.
Edit the created file to set your server name and email credentials. Keep real
credentials outside the repository.

For a project installed at `/opt/server-health-check`, create a command shortcut:

```sh
sudo ln -s /opt/server-health-check/bin/server-health-check /usr/local/bin/server-health-check
```

Then run `server-health-check --help` or `sudo server-health-check init-config` from any
directory.

After editing the configuration, run `sudo server-health-check validate-config`.
It checks file ownership, permissions, required settings, and basic value syntax
without printing credentials. The example API key must be replaced. Successful
validation does not verify Mailgun credentials or email delivery.

To send a test email to the configured recipient:

```sh
sudo server-health-check test-email
```

To preview the same subject and body without sending:

```sh
sudo server-health-check test-email --without-sending
```

`--without-sending` is a shared email-delivery option, accepted before or after the
command. It displays each email's subject and body instead of contacting Mailgun.
All other command actions still run, including configuration validation and health
checks. It does not prevent `init-config` from creating a configuration file.

Emails use the sender name `Health Checker Service` and the address in `MAIL_FROM`.
Actual email delivery requires `curl`. Success means Mailgun accepted the message for delivery;
confirm arrival in the recipient inbox. Requests time out after 30 seconds and
are not retried automatically. Credentials are passed through standard input,
without a named temporary credentials file. API response bodies are not printed.

To check reboot status without sending email:

```sh
sudo server-health-check check-reboot
```

Currently this checks only `/run/reboot-required`; it does not assess overall
server health and does not need the email configuration. Exit code `0` means no
reboot marker was found, `3` means a reboot is required, and `1` means the result
could not be determined. The command never reboots the server.

To refresh APT package indexes without installing packages:

```sh
sudo server-health-check check-apt-index
```

Repository failures (including partial failures), lock conflicts, and timeouts
produce an unknown/failed result. Existing APT processes are left alone. The
refresh has a 120-second limit, with up to 5 additional seconds for forced cleanup.
Raw APT output is not printed or logged because it may contain private repository
URLs; errors include an exit code. Run `sudo apt-get update --error-on=any` manually
on the server if detailed diagnostics are needed. This command only refreshes indexes.

To check available updates without installing packages:

```sh
sudo server-health-check check-apt-updates
```

This refreshes indexes first, then simulates `apt-get upgrade` with a 60-second
limit (plus up to 5 seconds for cleanup). It lists eligible upgrades with versions,
phased updates, and packages kept back for other reasons. Holds and phasing are
respected. Eligible upgrades and other held-back packages require maintenance
review (exit `3`); phased updates alone do not (exit `0`). A failed refresh or
simulation, or an unrecognized result, is unknown (exit `1`). This does not assess
whether unattended upgrades will install a package automatically.

To verify recent automatic-upgrade execution without running upgrades:

```sh
sudo server-health-check check-unattended-upgrades
```

This checks the standard Ubuntu daily APT timer and periodic settings, then
requires both a successful APT `upgrade-stamp` and a matching completed
unattended-upgrades log within 36 hours. A successful run with no updates counts.
The OK result shows the successful run time as `YYYY-MM-DD HH:MM` in the server's local timezone.
The previous rotated log (plain or gzip) is also read when present.

Disabled automation or an explicitly failed attempt requires attention (exit `3`).
Missing, stale, unreadable, inconsistent, or unrecognized evidence is unknown
(exit `1`), as are warnings, simulations, and a run still in progress. Custom
schedulers or log locations are not verified by this initial implementation.
The check does not change settings or audit the allowed security-update origins.

To list failed system-wide systemd services:

```sh
sudo server-health-check check-failed-services
```

No failed services returns `0`. Failed services (including failed oneshot services)
are listed for journal review and return `3`. Inactive or disabled services are
not failures on their own. A failed or unrecognized query returns unknown (`1`).
The query has a 15-second limit plus up to 2 seconds for cleanup, and never
changes service state. It does not check user services or whether configured
critical services are running.

To check system clock synchronization:

```sh
sudo server-health-check check-time-sync
```

This reads the system synchronization state reported by `timedatectl`, without
requiring a particular NTP daemon. Synchronized returns `0`, unsynchronized
requires attention (`3`), and an unavailable or unrecognized result is unknown
(`1`). The query has a 15-second limit plus up to 2 seconds for cleanup. It does
not change the clock or service settings, or measure the clock offset itself.

To verify recent logrotate execution without rotating logs:

```sh
sudo server-health-check check-logrotate
```

This checks the standard Ubuntu logrotate timer and oneshot service, and requires
a successful execution recorded in the system journal within 36 hours. The OK
result includes the completion time in the server's local timezone. A disabled
timer or failed execution requires attention (`3`). Missing or unreadable history,
an unsupported setup, or an unfinished run is unknown (`1`). Journal history is
checked across boots when retained; an enabled timer alone does not prove success.
Each systemd/journal query has a five-second limit plus up to two seconds for
cleanup. The check never runs logrotate, rotates files, or changes services.

To run all implemented checks and summarize their results:

```sh
sudo server-health-check check-all
```

Currently this checks available APT updates (including index refresh), reboot
status, unattended upgrades, failed services, time synchronization, and logrotate. Checks
continue after individual failures. The summary lists the checks performed and counts OK, actionable, and
failed/unknown results. A failed or unknown result takes precedence (exit `1`),
followed by action required (exit `3`); otherwise the exit code is `0`.
The summary covers only the checks performed. No email is sent.

To run the same checks and email their results:

```sh
sudo server-health-check report
sudo server-health-check report --without-sending
```

The second command previews the email without sending. Both validate the email
configuration first and run all implemented checks. A report is sent even when
healthy or a check fails. Its subject is `[{server-name}] {STATUS}`, with `OK`,
`ACTION REQUIRED`, or `CHECK FAILED OR UNKNOWN`; its body includes the server name, local server time (with timezone abbreviation and UTC offset),
and check results. The report covers only the implemented checks.

Reports include plain text and a responsive HTML version with a status badge,
result counts, a check overview, and details grouped by check. APT package lists
separate eligible, phased, and other held-back updates. Status colors are green
for OK, red for ACTION REQUIRED, and amber for CHECK FAILED OR UNKNOWN. Both
formats use the same collected check results. The terminal preview shows the
plain-text version. Keep `templates/report.html` with the installed project.

After successful email acceptance (or preview), the exit code reflects the checks:
`0` for OK, `3` for maintenance required, `1` for failed/unknown. Configuration or
delivery failure also returns `1`.

## Weekly scheduling

Install the project at `/opt/server-health-check`. On production servers, keep
the project owned by root and not writable by other users: the service runs it
as root. Validate the configuration and test a manual report before enabling
the timer.

From the project directory:

```sh
sudo install -o root -g root -m 0644 systemd/server-health-check.service systemd/server-health-check.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now server-health-check.timer
systemctl list-timers --all server-health-check.timer
```

The timer runs every Sunday at 04:30 in the server's local timezone, with up to
one minute of scheduling tolerance. Check the timezone with `timedatectl`.
After downtime, a missed schedule triggers one current report when the timer
starts; this may also happen on first activation. It does not replay every
missed week. Failed reports are not retried automatically.

The service has a five-minute time limit, followed by up to ten seconds for
termination. systemd prevents overlapping executions of this service; separate
direct CLI invocations are not covered by this protection. Exit `3` is accepted
as a completed run with maintenance findings, while exit `1` marks the service
as failed. A service timeout may prevent email delivery.

To run the scheduled service manually (sends email) and inspect its logs:

```sh
sudo systemctl start server-health-check.service
systemctl status server-health-check.service
sudo journalctl -u server-health-check.service --since today --no-pager
```

An inactive service after a successful run is normal: it runs once and exits.
To disable future scheduled runs:

```sh
sudo systemctl disable --now server-health-check.timer
```

Disabling the timer does not stop a report that is already running.

Application errors are also sent to the system log using `logger`, tagged
`server-health-check`. On Ubuntu, view them with:

```sh
sudo journalctl -t server-health-check --since today --no-pager
```

If logging fails, the error remains visible in the terminal along with a warning.
Log retention follows the server's existing logging configuration.

## License

[MIT](LICENSE)
