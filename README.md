# Server Health Check

A lightweight tool for weekly health reports from Ubuntu servers.

The initial scope is APT update availability and reboot status, with email delivery. Each server will send a weekly report, even when no action is required.

The tool will not install package updates or reboot servers.

## Status

Early development. Configuration initialization is available; health checks and
email delivery are not implemented yet.

## Usage

From the project directory on an Ubuntu server:

```sh
./bin/server-health-check --help
sudo ./bin/server-health-check init
```

The `init` command creates `/etc/server-health-check.conf` from the example with
root-only access. If the path already exists, it stops without changing it.
Edit the created file to set your server name and email credentials. Keep real
credentials outside the repository.

## License

[MIT](LICENSE)
