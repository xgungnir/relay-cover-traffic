# Relay Cover Traffic

Scheduled iperf3 cover traffic for Debian 12+. Does not manage proxy services or tc.

## Install

Run from the repository root. Keep the deployment directory after installation.

```bash
role=receiver # Use relay for the sender
cp config/$role.env.example config/$role.env
nano config/$role.env
sudo bash $role/install.sh
```

Configure receiver source whitelists and port (default: 11222). Firewall backend detection is automatic; mixed backends block installation or refresh.

Configure the sender interface and targets. Defaults: 512 Kbit/s and 400–800 seconds per hour, shared across targets sent serially.

## Manage

```bash
sudo bash $role/status.sh
sudo bash relay/apply-env.sh # Apply sender config changes
sudo bash $role/uninstall.sh
```

Rerun receiver installation after changing its config. Add `--purge` when uninstalling to remove runtime config.
