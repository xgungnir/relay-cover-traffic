# Relay Cover Traffic

Debian 12+ shell scripts for relay nodes and receiver nodes that run low-priority TCP/UDP iperf3 cover traffic alongside a `realm` relay path.

```text
Client --> relay node:realm.service --> receiver node:sing-box service(s)
                              \
                               \--low-priority cover traffic--> receiver node:iperf3 receiver(s)
```

The receiver should usually be installed first. Multiple relay nodes can send cover traffic to one or more receiver nodes, and one relay can list multiple receivers in `COVER_TARGETS`.

## What It Manages

Relay side:

- Installs relay dependencies.
- Installs or upgrades `/usr/local/bin/realm` from `REALM_TARBALL_URL` when needed.
- Creates `/etc/realm/config.toml` only when missing, and never overwrites a non-empty config.
- Installs `relay-cover-qos.service`.
- Installs `relay-cover-sender.service` and `relay-cover-sender.timer`.

Receiver side:

- Installs receiver dependencies.
- Installs the `sing-box` package from the Sagernet APT repo when needed.
- Adds the Sagernet APT key/repo if missing, even when `sing-box` is already installed.
- The repo package normally provides `/lib/systemd/system/sing-box.service` by default.
- Does not generate or overwrite `/etc/sing-box/config.json`.
- Installs IPv4/IPv6 `relay-cover-receiver-*` iperf3 services.
- Applies project-only firewall rules for `COVER_RECEIVER_PORT`.

## Layout

```text
relay-cover-traffic/
├── common/lib.sh
├── config/
│   ├── relay.env.example
│   └── receiver.env.example
├── relay/
│   ├── install.sh
│   ├── install-deps.sh
│   ├── setup-realm-service.sh
│   ├── setup-qos.sh
│   ├── install-qos-service.sh
│   ├── install-cover-sender.sh
│   ├── status.sh
│   └── uninstall.sh
└── receiver/
    ├── install.sh
    ├── install-deps.sh
    ├── setup-iperf3-receiver.sh
    ├── setup-firewall.sh
    ├── status.sh
    └── uninstall.sh
```

Local `config/*.env` files are ignored by Git. Runtime env files live under:

```text
/etc/relay-cover-traffic/receiver.env
/etc/relay-cover-traffic/relay.env
```

## First Install

Receiver:

```bash
git clone <repo-url> relay-cover-traffic
cd relay-cover-traffic/receiver
sudo ./install.sh
```

If `/etc/relay-cover-traffic/receiver.env` does not exist, `install.sh` creates it from `config/receiver.env.example`, installs dependencies, then stops. Edit the env file and rerun:

```bash
sudo nano /etc/relay-cover-traffic/receiver.env
sudo ./install.sh
```

Relay:

```bash
git clone <repo-url> relay-cover-traffic
cd relay-cover-traffic/relay
sudo ./install.sh
```

If `/etc/relay-cover-traffic/relay.env` does not exist, `install.sh` creates it from `config/relay.env.example`, installs dependencies, then stops. Edit the env file and rerun:

```bash
sudo nano /etc/relay-cover-traffic/relay.env
sudo ./install.sh
```

If `/etc/realm/config.toml` is missing, relay `install.sh` creates an empty file and stops after installing `realm`. Edit it, restart `realm.service`, then rerun the installer:

```bash
sudo nano /etc/realm/config.toml
sudo systemctl restart realm.service
sudo ./install.sh
```

The installer refuses to continue when env files still contain example placeholder addresses.

## Services

Relay:

```text
realm.service
relay-cover-qos.service
relay-cover-sender.service
relay-cover-sender.timer
```

Receiver:

```text
relay-cover-receiver-v4.service
relay-cover-receiver-v6.service
```

Status:

```bash
cd relay && sudo ./status.sh
cd receiver && sudo ./status.sh
```

## Cover Sender

`relay-cover-sender.timer` starts `/usr/local/sbin/relay-cover-sender-hourly.sh` hourly. Each run chooses a random delay, random total duration, random target order, and per-target segments capped by `COVER_MAX_SEGMENT_SECONDS`.

`COVER_TYPE` controls each individual iperf3 process:

```text
auto  choose UDP or TCP randomly before every iperf3 process
udp   always use UDP
tcp   always use TCP
```

UDP:

```bash
iperf3 -c "$host" -u -b "$effective_rate" -l 1200 -t "$segment_duration" -p "$port" --connect-timeout "$connect_timeout_ms"
```

TCP:

```bash
iperf3 -c "$host" -b "$effective_rate" -t "$segment_duration" -p "$port" --connect-timeout "$connect_timeout_ms"
```

If a segment fails, the sender waits `COVER_RETRY_DELAY_SECONDS` and retries until that target window ends. A target fails the service only when no segment succeeds during its allocated window.

## QoS And Firewall

Relay QoS applies only to egress on `EGRESS_DEV`.

```text
1:10  relay traffic class
1:20  cover traffic class
1:30  default class
```

Receiver firewall rules protect only `COVER_RECEIVER_PORT`. With nftables the project creates `table inet relay_cover_traffic`; with iptables legacy it creates `RELAY_COVER_TRAFFIC`. It allows whitelisted TCP/UDP cover traffic and drops other TCP/UDP traffic to that port.

## After Env Changes

Relay changes:

```text
REALM_TARBALL_URL
  cd relay && sudo ./setup-realm-service.sh

/etc/realm/config.toml
  sudo systemctl restart realm.service

RELAY_QOS_TARGETS, TC_TOTAL_RATE, TC_RELAY_*, TC_COVER_*, TC_DEFAULT_*
  sudo systemctl restart relay-cover-qos.service

COVER_TARGETS
  sudo systemctl restart relay-cover-qos.service
  next timer run uses the new targets automatically
  to run now: sudo systemctl stop relay-cover-sender.service && sudo systemctl start relay-cover-sender.service

COVER_RATE, COVER_TYPE, COVER_MIN_SECONDS, COVER_MAX_SECONDS, COVER_RETRY_DELAY_SECONDS, COVER_MAX_SEGMENT_SECONDS
  next timer run uses the new values automatically
  to run now: sudo systemctl stop relay-cover-sender.service && sudo systemctl start relay-cover-sender.service

ALLOW_COVER_RATE_ABOVE_5M
  affects sender runs immediately on next start
  also restart relay-cover-qos.service if TC_COVER_CEIL is above 5mbit

EGRESS_DEV
  before editing env: sudo systemctl stop relay-cover-qos.service
  after editing env:  sudo systemctl restart relay-cover-qos.service
```

Receiver changes:

```text
COVER_SOURCE_WHITELIST_V4, COVER_SOURCE_WHITELIST_V6, FIREWALL_BACKEND
  cd receiver && sudo ./setup-firewall.sh

COVER_BIND_ADDRESS_V4, COVER_BIND_ADDRESS_V6
  cd receiver && sudo ./setup-iperf3-receiver.sh

COVER_RECEIVER_PORT
  cd receiver && sudo ./setup-iperf3-receiver.sh && sudo ./setup-firewall.sh
  also update relay COVER_TARGETS, then restart relay-cover-qos.service on each relay

SING_BOX_SERVICE_PORT
  project reference only; no relay-cover service restart is needed

/etc/sing-box/config.json
  sudo systemctl restart sing-box
```

After pulling code changes to installed helper scripts, rerun the relevant installer:

```bash
cd relay && sudo ./install.sh
cd receiver && sudo ./install.sh
```

## Uninstall

Relay:

```bash
cd relay
sudo ./uninstall.sh
sudo ./uninstall.sh --purge
```

Receiver:

```bash
cd receiver
sudo ./uninstall.sh
sudo ./uninstall.sh --purge
```

`--purge` removes the role env file under `/etc/relay-cover-traffic`. Non-empty `/etc/realm/config.toml`, `/usr/local/bin/realm`, the sing-box package, and `/etc/sing-box/config.json` are preserved.
