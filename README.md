# Server Health Check

A lightweight tool for weekly health reports from Ubuntu servers.

The initial scope is APT update availability and reboot status, with email delivery. Each server will send a weekly report, even when no action is required.

The tool will not install package updates or reboot servers.

## Status

Early development. Configuration initialization, validation, test email delivery,
APT update analysis, reboot checks, and manual email reports are available. Scheduled reports are not
implemented yet.

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

To run all implemented checks and summarize their results:

```sh
sudo server-health-check check-all
```

Currently this checks available APT updates (including index refresh) and reboot
status. Checks continue after individual failures. The summary lists the checks performed and counts OK, actionable, and
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
`ACTION REQUIRED`, or `CHECK FAILED OR UNKNOWN`; its body includes the server name, UTC timestamp,
and check results. The report covers only the implemented checks.

After successful email acceptance (or preview), the exit code reflects the checks:
`0` for OK, `3` for maintenance required, `1` for failed/unknown. Configuration or
delivery failure also returns `1`. Weekly scheduling is not implemented yet.

Application errors are also sent to the system log using `logger`, tagged
`server-health-check`. On Ubuntu, view them with:

```sh
sudo journalctl -t server-health-check --since today --no-pager
```

If logging fails, the error remains visible in the terminal along with a warning.
Log retention follows the server's existing logging configuration.

## License

[MIT](LICENSE)
