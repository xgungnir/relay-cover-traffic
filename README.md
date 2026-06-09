# Relay Cover Traffic

Debian 12+ shell scripts for relay nodes and receiver nodes that run low-priority TCP/UDP iperf3 cover traffic alongside a manually configured `sing-box` relay path.

```text
Client --> relay node:sing-box.service --> receiver node:sing-box service(s)
                              \
                               \--low-priority cover traffic--> receiver node:iperf3 receiver(s)
```

The receiver should usually be installed first. Multiple relay nodes can send cover traffic to one or more receiver nodes, and one relay can list multiple receivers in `COVER_TARGETS`.

## What It Manages

Relay side:

- Installs relay dependencies.
- Installs the `sing-box` package from the Sagernet APT repo when needed.
- Adds the Sagernet APT key/repo if missing, even when `sing-box` is already installed.
- Enables the packaged `sing-box.service`.
- Checks `/etc/sing-box/config.json` with `sing-box check -D /var/lib/sing-box -C /etc/sing-box`.
- Restarts `sing-box.service` only after the config check passes.
- Does not generate or overwrite `/etc/sing-box/config.json`.
- Installs `relay-cover-qos.service`.
- Installs `relay-cover-sender.service` and `relay-cover-sender.timer`.

Receiver side:

- Installs receiver dependencies.
- Installs the `sing-box` package from the Sagernet APT repo when needed.
- Adds the Sagernet APT key/repo if missing, even when `sing-box` is already installed.
- Enables the packaged `sing-box.service`; it does not start it before you configure sing-box.
- Does not generate or overwrite `/etc/sing-box/config.json`.
- Installs IPv4/IPv6 `relay-cover-receiver-*` iperf3 services.
- Applies project-only firewall rules for `COVER_RECEIVER_PORT`.

## Layout

```text
relay-cover-traffic/
├── common/
│   ├── lib.sh
│   └── sb.sh
├── config/
│   ├── relay.env.example
│   ├── relay.env
│   ├── receiver.env.example
│   └── receiver.env
├── relay/
│   ├── install.sh
│   ├── install-deps.sh
│   ├── setup-sb-service.sh
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
    ├── check-dns.sh
    ├── status.sh
    └── uninstall.sh
```

Local `config/*.env` files are ignored by Git. Prepare the real env files under `config/`; `install.sh` copies them to the runtime location on every run:

```text
/etc/relay-cover-traffic/receiver.env
/etc/relay-cover-traffic/relay.env
```

Do not edit the runtime copies directly unless you are deliberately bypassing the installer, because the next `install.sh` run overwrites them from `config/*.env`.

The installer does not create `config/*.env` for you. If the role env file is missing, it exits before installing dependencies.

## First Install

Receiver:

```bash
git clone <repo-url> relay-cover-traffic
cd relay-cover-traffic
cp config/receiver.env.example config/receiver.env
nano config/receiver.env
cd receiver
sudo ./install.sh
```

Relay:

```bash
git clone <repo-url> relay-cover-traffic
cd relay-cover-traffic
cp config/relay.env.example config/relay.env
nano config/relay.env
cd relay
sudo ./install.sh
```

Relay `install.sh` installs the `sing-box` package and enables `sing-box.service`. If `/etc/sing-box/config.json` already existed and was non-empty before package setup, the installer verifies it with:

```bash
sing-box check -D /var/lib/sing-box -C /etc/sing-box
```

When that check passes, the installer restarts `sing-box.service`. If no config was present before package setup, the installer treats sing-box config as pending: it enables `sing-box.service`, does not check or restart the packaged default config, and stops the service in case the package started it. Edit `/etc/sing-box/config.json`, then start the real relay config:

```bash
sudo systemctl restart sing-box.service
```

You can also run `cd relay && sudo ./setup-sb-service.sh` after editing the config to run the project check and restart path.

The installer refuses to continue when env files still contain example placeholder addresses.

On first dependency install, Debian's `iperf3` package can emit maintainer-script messages such as `deb-systemd-helper was not called from dpkg` or `Failed to stop iperf3.service: Unit iperf3.service not loaded`. The installer filters those known harmless lines during dependency install and default `iperf3` service cleanup; if `apt-get` really fails, the script still stops.

## Relay sing-box Config Example

This is only a route structure example. The real relay inbound/outbound types, ports, and remote targets are part of your own sing-box design. Project scripts never generate or overwrite `/etc/sing-box/config.json`.

```json
{
  "log": {
    "level": "warn"
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "local"
      }
    ],
    "final": "local"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": 1081
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "socks-out",
      "server": "relay-backend.example.com",
      "server_port": 1080
    },
    {
      "type": "direct",
      "tag": "direct",
      "domain_resolver": {
        "server": "local",
        "strategy": "prefer_ipv4"
      }
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": [
          "socks-in"
        ],
        "action": "route",
        "outbound": "socks-out"
      }
    ],
    "final": "direct"
  }
}
```

Keep `RELAY_QOS_TARGETS` aligned with the effective remote endpoints configured manually in `/etc/sing-box/config.json`, because relay QoS classification uses those host:port values.

## Services

Relay:

```text
sing-box.service
relay-cover-qos.service
relay-cover-sender.service
relay-cover-sender.timer
```

Receiver:

```text
sing-box.service
relay-cover-receiver-v4.service
relay-cover-receiver-v6.service
```

Status:

```bash
(cd relay && sudo ./status.sh)
(cd receiver && sudo ./status.sh)
```

Receiver DNS check/repair:

```bash
(cd receiver && sudo ./check-dns.sh)
```

`receiver/check-dns.sh` is a standalone recovery helper for resolver breakage caused by installing or removing `openresolv`, `resolvconf`, or `systemd-resolved`. It exits without changes when DNS already works. When DNS is broken, it prefers a working `systemd-resolved`, then `resolvconf`/`openresolv`, and finally writes a simple static `/etc/resolv.conf`. Override fallback servers with `sudo env DNS_SERVERS="1.1.1.1 8.8.8.8" ./check-dns.sh`.

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

Firewall persistence depends on `FIREWALL_BACKEND`:

```text
nftables
  uses nftables.service and /etc/nftables.conf
  setup-firewall.sh writes /etc/nftables.d/relay-cover-traffic.nft
  if needed, it adds a marked include block for /etc/nftables.d/*.nft

iptables-legacy
  uses netfilter-persistent with the iptables-persistent IPv4/IPv6 plugins
  setup-firewall.sh installs netfilter-persistent and iptables-persistent when missing
  rules are saved to /etc/iptables/rules.v4 and /etc/iptables/rules.v6
```

## After Env Changes

Edit `config/relay.env` or `config/receiver.env`, then run the matching repo-side script below. Those scripts sync the relevant env file into `/etc/relay-cover-traffic/` before reading it. Rerunning the full installer also works, but is usually more than needed:

```bash
(cd relay && sudo ./install.sh)
(cd receiver && sudo ./install.sh)
```

Relay changes:

```text
/etc/sing-box/config.json
  cd relay && sudo ./setup-sb-service.sh

RELAY_QOS_TARGETS, TC_TOTAL_RATE, TC_RELAY_*, TC_COVER_*, TC_DEFAULT_*
  cd relay && sudo ./setup-qos.sh

COVER_TARGETS
  cd relay && sudo ./setup-qos.sh
  next timer run uses the new targets automatically
  to run now: sudo systemctl stop relay-cover-sender.service && sudo systemctl start relay-cover-sender.service

COVER_RATE, COVER_TYPE, COVER_MIN_SECONDS, COVER_MAX_SECONDS, COVER_RETRY_DELAY_SECONDS, COVER_MAX_SEGMENT_SECONDS
  cd relay && sudo ./install-cover-sender.sh
  next timer run uses the new values automatically
  to run now: sudo systemctl stop relay-cover-sender.service && sudo systemctl start relay-cover-sender.service

ALLOW_COVER_RATE_ABOVE_5M
  cd relay && sudo ./install-cover-sender.sh
  affects sender runs immediately on next start
  also run cd relay && sudo ./setup-qos.sh if TC_COVER_CEIL is above 5mbit

EGRESS_DEV
  before editing env: sudo systemctl stop relay-cover-qos.service
  after editing env:  cd relay && sudo ./install-qos-service.sh
```

Receiver changes:

```text
COVER_SOURCE_WHITELIST_V4, COVER_SOURCE_WHITELIST_V6, FIREWALL_BACKEND
  cd receiver && sudo ./setup-firewall.sh

COVER_BIND_ADDRESS_V4, COVER_BIND_ADDRESS_V6
  cd receiver && sudo ./setup-iperf3-receiver.sh

COVER_RECEIVER_PORT
  cd receiver && sudo ./setup-iperf3-receiver.sh && sudo ./setup-firewall.sh
  also update relay COVER_TARGETS, then run cd relay && sudo ./setup-qos.sh on each relay

SING_BOX_SERVICE_PORT
  project reference only; no relay-cover service restart is needed

/etc/sing-box/config.json
  sudo systemctl restart sing-box
```

After pulling code changes to installed helper scripts, rerun the relevant installer:

```bash
(cd relay && sudo ./install.sh)
(cd receiver && sudo ./install.sh)
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

Relay uninstall disables project cover/qos units and `sing-box.service`. It preserves `/etc/sing-box/config.json` and the `sing-box` package.

Receiver uninstall disables `sing-box.service` and removes the project firewall rules from the active ruleset. For iptables legacy it saves the removal through `netfilter-persistent` when available. For nftables it removes the project include file and the marked include block that this project added to `/etc/nftables.conf`.

`--purge` removes the role env file under `/etc/relay-cover-traffic`. The `sing-box` package, firewall persistence packages, and `/etc/sing-box/config.json` are preserved.
