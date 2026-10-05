# VPS

Ubuntu host setup, Docker, Caddy, security, and [dotfiles](dotfiles/README.md).

## Start

On the Ubuntu console or an existing SSH session:

```sh
curl -fsSL https://raw.githubusercontent.com/jonathanbecerra/vps/main/install.sh | sh
```

From a clone:

```sh
git clone --recurse-submodules https://github.com/jonathanbecerra/vps.git
cd vps
./install.sh
```

The installer keeps the checkout and Git metadata in `/opt/vps`. To test
another branch or tag, use `VPS_REF=branch` with the curl command.

On an installed host:

```sh
cd /opt/vps
./install.sh
```

`make setup` runs the same installer.

## Setup modes

| | Basic | Advanced |
| --- | --- | --- |
| Account and hostname | Keep them | Choose them and set a password |
| SSH | Keep current settings | Verify a key, then disable root and password SSH |
| Caddy and VPN | Off | Choose after SSH confirmation |
| Examples | Create both | Create both and start the selected example |

Both modes install Ubuntu updates, Docker, UFW, fail2ban, and dotfiles.

After Basic, log in again to load Zsh and the Docker group. After confirmed
Advanced setup, run `sudo reboot`, then reconnect with the verified key.

## SSH

Copy a key while password SSH is enabled:

```sh
ssh-copy-id -i ~/.ssh/id_ed25519.pub admin@HOST
```

Advanced setup starts a five-minute rollback and prints the connection
command. Open a new key session and run:

```sh
cd /opt/vps
make confirm-ssh
```

Use a fresh connection. Add `-S none` if your SSH config shares connections.
Do not reboot before confirmation. If the timer expires, retry, stop, or
continue without confirmed hardening.

After hardening:

```sh
ssh -t -i ~/.ssh/gh_ed25519 -p 22 admin@HOST
```

Use the account, key, host, and port printed by setup.

## Existing hosts

```sh
cd /opt/vps
make setup
make setup-host
make install-dotfiles
make show-status
```

`setup-host` reapplies host security, time sync, the saved Caddy mode, and
the managed UFW rules. `install-dotfiles` updates user tools and configs.

For a Git checkout:

```sh
git pull --ff-only
git submodule sync --recursive
git submodule update --init --recursive
```

For an rsync checkout:

```sh
make preview-deploy HOST=admin@HOST
make sync-repo HOST=admin@HOST
```

Do not mix the Git and rsync workflows.

## Caddy

Caddy runs as a native systemd service with the Cloudflare DNS module.

| Mode | Example | UFW |
| --- | --- | --- |
| `none` | Neither starts | Remove managed Caddy rules |
| `private` | Hono at `hono.ohmstack.net` | 80/443 on the default interface |
| `public` | Static files at `/var/www/ohmstack.net` | 80/443 and UDP 443 on all interfaces |

Both examples are created every time:

```text
/var/www/ohmstack.net
/var/app/hono.ohmstack.net
```

Private mode starts Hono on `127.0.0.1:3000`. Site files live in
`/etc/caddy/sites-available` and are enabled with symlinks in
`/etc/caddy/sites-enabled`.

Change the mode in `/etc/caddy/caddy.conf`:

```sh
sudoedit /etc/caddy/caddy.conf
make setup-host
```

Private HTTPS uses a Cloudflare DNS-01 token with `Zone:Read` and
`DNS:Edit` for the zone. Store it in `/etc/caddy/caddy.env`:

```sh
sudoedit /etc/caddy/caddy.env
# CLOUDFLARE_API_TOKEN=your-token
sudo systemctl restart caddy
```

The token is for DNS validation, not DDNS. Public mode does not need one for
the HTTP starter site.

```sh
sudo systemctl reload caddy
sudo systemctl restart caddy
sudo systemctl status caddy
sudo journalctl -u caddy -n 50 --no-pager
```

## VPN and apps

```sh
make configure-vpn vpn=tailscale
make configure-vpn vpn=wireguard
```

Use Compose in each app directory or `lazydocker`:

```sh
cd /var/app/hono.ohmstack.net
dcup
dcps
dcdown
```

The Hono template is in [build/hono](build/hono). It uses TypeScript, Node,
and pnpm, and serves `/`, `/api/hello`, and `/healthz`.

Create a repository-scoped GitHub deploy key:

```sh
make deploy-key REPO=example
```

The key is stored at `~/.ssh/deploy-keys/example/id_ed25519`.

## Paths

| Path | Contents |
| --- | --- |
| `/opt/vps` | This checkout and pinned dotfiles |
| `/etc/vps/host.conf` | Host settings |
| `/etc/caddy` | Caddy settings, token, and sites |
| `/var/www/<domain>` | Static sites |
| `/var/app/<project>` | Docker apps and Compose files |
| `/data` | Service data and backups |

## Testing

```sh
make check-repo
make -C dotfiles check
DRY_RUN=1 make setup mode=basic
DRY_RUN=1 make setup mode=advanced
DRY_RUN=1 make setup-host
```

For a full test, use a disposable VM.

### Local VM

Install QEMU and `openssl@3` with Homebrew. Put the Ubuntu ARM64 image at:

```text
~/Developer/distros/ubuntu-26.04/ubuntu-26.04-server-cloudimg-arm64.img
```

```sh
make create-vm name=lab
make list-vm
make start-vm name=lab display=gui
ssh -t -p PORT admin@127.0.0.1
```

Use the forwarded `PORT` from `make list-vm`. Test Basic and Advanced on
separate VMs.

```sh
make stop-vm name=lab
make teardown-vm name=lab
```
