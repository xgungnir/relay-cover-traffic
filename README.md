# Relay Cover Traffic

Debian 12+ shell scripts for receiver nodes and relay nodes that send scheduled `iperf3` cover traffic. The relay side now manages only the cover sender. It does not manage your real proxy stack, and it does not create or remove interface `tc`/HTB QoS.

## Responsibilities

Relay side:

- installs relay dependencies for the cover sender
- validates and snapshots the 5-field relay config
- installs `relay-cover-sender.service` and `relay-cover-sender.timer`
- runs one serial `iperf3` sender stream at a time
- binds every sender socket to `EGRESS_DEV` with `--bind-dev`
- marks every sender socket with `--dscp 1`
- uses the same per-segment rate for `-b` and `--fq-rate`

Receiver side:

- installs receiver dependencies
- installs the `sing-box` package when needed
- installs IPv4/IPv6 `iperf3` receiver services
- applies project firewall rules for `COVER_RECEIVER_PORT`
- refreshes receiver firewall DNS whitelist entries every 30 minutes

## Relay Config Contract

`config/relay.env` must contain exactly these 5 fields:

```bash
EGRESS_DEV="eth0"
COVER_TARGETS="receiver1.example.com:11222, [2001:db8::20]:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="auto"
```

Rules:

- lines must be `KEY="value"` with no leading/trailing spaces
- only whole-line `#` comments and empty lines are allowed
- duplicate keys fail
- unknown keys fail
- legacy relay keys fail
- `COVER_RATE` uses `<positive_integer>[KMG]?`
- `COVER_DURATION_RANGE` uses `<min_seconds>-<max_seconds>`
- `COVER_TYPE` must be `auto`, `udp`, or `tcp`

`COVER_RATE` is the only public rate field. Default example value is `2M`, not a hard cap. Legal values above 5 Mbps are accepted unchanged.

## Relay Sender Behavior

This version provides application-layer pacing, not kernel-level low-priority QoS:

- each segment samples other egress bytes for 2 seconds before starting
- if other egress traffic is below `COVER_RATE`, the next segment uses 100% `COVER_RATE`
- if other egress traffic is at or above `COVER_RATE`, the next segment uses `ceil(COVER_RATE/4)`
- busy mode never pauses to zero
- each segment lasts at most 30 seconds
- multiple targets always run strictly serially
- target results are `completed`, `throttled`, or `failed`

DSCP LE is only a hint to downstream schedulers. If the host or network path ignores LE, traffic may still be treated as normal best effort.

## Runtime Env Boundary

Relay config file roles:

- `config/relay.env`: operator-edited candidate config
- `/etc/relay-cover-traffic/relay.env`: validated runtime snapshot

Only these top-level relay entrypoints write the runtime env:

- `relay/install.sh`
- `relay/apply-env.sh`

The sender, status script, and unit installer read only the runtime snapshot.

## Install

Receiver:

```bash
git clone <repo-url> relay-cover-traffic
cd relay-cover-traffic
cp config/receiver.env.example config/receiver.env
nano config/receiver.env
cd receiver
sudo ./install.sh
```

Receiver whitelist entries may be IP literals, CIDRs, or DNS names:

```bash
COVER_SOURCE_WHITELIST_V4="47.113.225.177, business-update2.rainydata.com"
COVER_SOURCE_WHITELIST_V6="2402:4e00:c032:7000:98f2:1c6:42c8:0"
```

DNS names in `COVER_SOURCE_WHITELIST_V4` resolve only A records. DNS names in
`COVER_SOURCE_WHITELIST_V6` resolve only AAAA records. Receiver install creates
`relay-cover-receiver-firewall-refresh.timer`, which refreshes those resolved
firewall allow rules every 30 minutes. If a DNS name cannot be resolved, the
refresh fails before replacing firewall rules, so the previous working rules stay
in place.

Relay:

```bash
git clone <repo-url> relay-cover-traffic
cd relay-cover-traffic
cp config/relay.env.example config/relay.env
nano config/relay.env
cd relay
sudo ./install.sh
```

Relay install order:

1. parse and validate `config/relay.env`
2. reject legacy relay QoS resources
3. validate `EGRESS_DEV`
4. install dependencies
5. require `iperf3` support for `--bind-dev`, `--dscp`, and `--fq-rate`
6. snapshot the validated runtime env
7. install sender helper, service, and timer
8. enable the timer

Relay install does not install or restart `sing-box`, `xray`, `realm`, or `tc`.

## Apply

After editing `config/relay.env`:

```bash
cd relay
sudo ./apply-env.sh
```

Behavior:

- validates the candidate config before stopping anything
- backs up the current runtime env and sender assets
- stops the timer, and stops the sender only if it is running
- swaps in the validated runtime env
- refreshes the sender helper and systemd units
- restores the previous timer state
- restarts the sender only if it was already running
- restores the previous runtime env and sender assets if apply fails mid-flight

## Status

```bash
cd relay
sudo ./status.sh
```

Relay status shows:

- the 5 relay config fields from the runtime snapshot
- sender service and timer status
- next timer activation
- current sender journal
- `EGRESS_DEV` link state
- `iperf3` version plus `--bind-dev`, `--dscp`, and `--fq-rate` capability checks
- active connections related to cover target ports

It does not call `tc` and it does not treat `sing-box` as relay project health.

## Uninstall

Relay:

```bash
cd relay
sudo ./uninstall.sh
sudo ./uninstall.sh --purge
```

Behavior:

- removes only sender units and sender helper assets
- keeps `/etc/relay-cover-traffic/relay.env` unless `--purge` is used
- does not disable or stop `sing-box`, `xray`, or `realm`
- does not create, replace, or remove root qdiscs
- refuses to proceed if legacy `relay-cover-qos.service` resources are still present

Receiver uninstall behavior is unchanged by this relay refactor.

## Migration Note

New relay config is intentionally incompatible with the old relay env. Legacy relay QoS, split-duration, hidden-rate-cap, and `TC_*` style fields are rejected. On a legacy relay node, clear the old version first, then install the refactored relay version with a fresh 5-field config.

For the approved `bjcu` acceptance flow, use the old `/root/relay-cover-traffic/relay/uninstall.sh` first, without `--purge`, and run the new code only from `/root/relay-cover-traffic-refactor-test`.
