# Server Health Check

A lightweight tool for weekly health reports from Ubuntu servers.

The initial scope is APT update availability and reboot status, with email delivery. Each server will send a weekly report, even when no action is required.

The tool will not install package updates or reboot servers.

## Status

Early development. Configuration initialization, validation, test email delivery,
and reboot checks are available. APT checks and scheduled reports are not implemented yet.

## Usage

From the project directory on an Ubuntu server:

```sh
./bin/server-health-check --help
sudo ./bin/server-health-check init
sudo ./bin/server-health-check validate-config
```

The `init` command creates `/etc/server-health-check.conf` from the example with
root-only access. If the path already exists, it stops without changing it.
Edit the created file to set your server name and email credentials. Keep real
credentials outside the repository.

For a project installed at `/opt/server-health-check`, create a command shortcut:

```sh
sudo ln -s /opt/server-health-check/bin/server-health-check /usr/local/bin/server-health-check
```

Then run `server-health-check --help` or `sudo server-health-check init` from any
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
checks. It does not prevent `init` from creating a configuration file.

Actual email delivery requires `curl`. Success means Mailgun accepted the message for delivery;
confirm arrival in the recipient inbox. Requests time out after 30 seconds and
are not retried automatically. Credentials are passed through standard input,
without a named temporary credentials file. API response bodies are not printed.

To check reboot status without sending email:

```sh
sudo server-health-check check
```

Currently this checks only `/run/reboot-required`; it does not assess overall
server health and does not need the email configuration. Exit code `0` means no
reboot marker was found, `3` means a reboot is required, and `1` means the result
could not be determined. The command never reboots the server.

Application errors are also sent to the system log using `logger`, tagged
`server-health-check`. On Ubuntu, view them with:

```sh
sudo journalctl -t server-health-check --since today --no-pager
```

If logging fails, the error remains visible in the terminal along with a warning.
Log retention follows the server's existing logging configuration.

## License

[MIT](LICENSE)
