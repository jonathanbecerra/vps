# VPS

Set up an Ubuntu Docker host, then install the [dotfiles](dotfiles/README.md).
Choose Basic to keep the current account and SSH settings, or Advanced for
the account and key-only SSH handoff.

## Start

Run on the Ubuntu box, from its console or an existing SSH session.

```sh
curl -fsSL https://raw.githubusercontent.com/jonathanbecerra/vps/main/install.sh | sh
```

The installer downloads the project and its pinned dotfiles submodule. It
keeps them in `/opt/vps`, including Git metadata, so you can pull updates.
It reads prompts from the terminal even when downloaded through a pipe.

Setup clears the terminal once at startup. Numbered choices accept a number,
name, or Enter for the default; confirmations use `y/N`. Each stage shows its
position, and each spinner becomes a check with elapsed time. Routine output
is hidden unless a step fails; Caddy's build stays live. Password prompts and
the SSH rollback countdown stay visible. Use `make show-status` in `/opt/vps`
for the full health report after setup.

Review the script before running it with sudo. It defaults to `main`.
To test another branch or tag, use that ref in the URL and pass the same
value as `VPS_REF` to `sh`.

Or clone the project yourself:

```sh
git clone --recurse-submodules https://github.com/jonathanbecerra/vps.git
cd vps
sudo --preserve-env=SSH_CONNECTION ./setup-vps.sh
```

If the code is already on the box, run that last command there.
`make setup` opens the same guide when Make is installed.
If SSH is unavailable, start from the console. A downloaded script cannot
fix access until you can run it on the box.

After Basic, log out and log back in to activate Zsh and Docker group access.
The final screen shows login commands for the selected account. Over SSH,
test a fresh connection before closing the old one. For a VM, use its
Mac-side forwarded port, not the guest's SSH port. Copying a key alone does
not disable password or root SSH login.

After Advanced finishes with confirmed SSH hardening, run `sudo reboot`,
then reconnect with the key you verified. A fresh login activates Zsh and
the Docker group; the reboot also applies pending kernel updates.
Setup never reboots automatically.

### Choose a setup

| Step | Basic | Advanced |
| --- | --- | --- |
| Ubuntu | Synchronize time, update and upgrade | Same |
| Account | Keep the current non-root user, password, and hostname | Ask for admin username and hostname, then set the password |
| SSH | Leave authentication unchanged | Copy/check a public key, harden SSH, verify a fresh key login |
| Caddy and VPN | Both `none` | Ask after the SSH step |
| Examples | Create both, leave them stopped | Create both, start the example selected by the Caddy mode |
| Dotfiles | Install for the current user | Install for the selected admin |

Both paths install Docker, UFW, and fail2ban. Automatic security updates
default to on; an existing host keeps its saved update policy.
Basic is not a key-only SSH setup. Use Advanced before exposing a fresh box
publicly. Basic refuses to switch off an existing Caddy or VPN installation.
After Basic, run `make setup mode=advanced` inside `/opt/vps` to configure
key-only SSH and service choices using the existing checkout and settings.

Advanced reuses the account you select or creates it if needed. Choosing a
different username does not rename or delete the account with your active
session. Its new password remains usable for sudo and console recovery after
password SSH is disabled.
New accounts use Bash during the handoff. Setup selects Zsh after dotfiles
install successfully.

### Copy your SSH key

From your Mac, while password SSH is enabled:

```sh
ssh-copy-id -i ~/.ssh/id_ed25519.pub admin@HOST
```

Use your public key filename, such as `gh_ed25519.pub`, and the host's admin
username. For a VM, add `-p PORT` with the forwarded port from `make list-vm`.

### Advanced SSH handoff

Keep the setup terminal open.

1. If the selected account has no public key, setup waits and prints a
   `ssh-copy-id` command for your Mac. It checks `authorized_keys` before
   proceeding. Do not copy a private key.
2. Setup disables root and password SSH login and starts a five-minute
   systemd rollback timer. A live countdown stays in the setup terminal.
3. Open the fresh key-only connection it prints. In that new session, run:

```sh
cd /opt/vps
make confirm-ssh
```

Setup checks a receipt for this attempt. Confirmation also checks the SSH
journal for this connection's public-key login and checks the effective SSH
policy. Pressing Enter in the original terminal cannot confirm access.
If your SSH config shares connections, add `-S none` to the printed SSH
command so confirmation uses a new connection.

After confirmation, choose to continue or stop. Continuing asks for Caddy
and VPN, applies them, and installs dotfiles automatically.

If the timer expires, SSH rolls back. Choose `retry` for another five
minutes, `stop`, or explicitly `continue` without confirmed hardening.
The last choice prints a red warning. Ctrl-C or Stop at the SSH handoff leaves
completed package, account, and hostname changes in place. It does not run
Caddy, VPN, or dotfiles. An armed rollback remains independent of the terminal.
Do not reboot during the handoff.

After hardening, your normal login is:

```sh
ssh -t -i ~/.ssh/gh_ed25519 -p 22 admin@HOST
```

Replace the user, host, key, and port with your values. For the home Pi, for
example, `admin@10.10.90.159` works only while that remains its address.
For QEMU, use its forwarded port rather than the guest's port 22.
See [local VM testing](#local-vm-testing).

## Change an existing host

Inside `/opt/vps`:

```sh
make setup              # run the guide again
make setup-host         # reapply host packages/security and saved Caddy mode
make install-dotfiles   # update tools/configs and reload Zsh
make show-status
```

`make setup` asks again and Advanced resets the selected user's password.
For routine updates, use the individual commands above.
Time synchronization is automatic. Reboot separately when Ubuntu requests it.

For a Git-installed checkout:

```sh
git pull --ff-only
git submodule sync --recursive
git submodule update --init --recursive
```

Then run the step affected by the update. The submodule stays pinned to the
version reviewed with VPS; do not use `git submodule update --remote` on
a host just to update VPS.

For an rsync-installed checkout, continue syncing from your Mac:

```sh
make preview-deploy HOST=admin@HOST
make sync-repo HOST=admin@HOST
```

Rsync excludes Git metadata and local secrets. A code-only copy cannot
`git pull`; do not mix the two update methods.

### Caddy

Caddy runs as a native systemd service with the Cloudflare DNS module. Active
modes build it, enable it at boot, and reconcile the Caddy-managed UFW rules.

| Mode | Running example | Caddy rules in UFW |
| --- | --- | --- |
| `none` | Neither | Remove managed Caddy rules; disable the Caddy service |
| `private` | Hono Docker API through `hono.ohmstack.net` | TCP 80/443 on the detected default-route interface |
| `public` | Static HTTP example from `/var/www/ohmstack.net` | TCP 80/443 and UDP 443 on all interfaces |

Both examples always exist at `/var/www/ohmstack.net` and
`/var/app/hono.ohmstack.net`. Private starts Hono at `127.0.0.1:3000`.
These example names assume you control `ohmstack.net`; use your own zone otherwise.
Changing modes does not delete either project or stop a previously started
Hono container. Manage it from its own Compose directory.

Private still uses Cloudflare for trusted certificates. It does not mean
the interface blocks internet sources. Keep WAN forwarding off and use
UniFi/VPN rules for private access, including IPv6. Internal DNS should
resolve private names to Caddy's LAN address.

The role lives in `/etc/caddy/caddy.conf`. To change it without rerunning
the account/SSH guide:

```sh
sudoedit /etc/caddy/caddy.conf   # CADDY_MODE=none, private, or public
make setup-host
```

The parent Caddyfile imports `sites-enabled/*.caddy`. Put sites in
`/etc/caddy/sites-available`, then symlink them into `sites-enabled`.
The parent and service unit are managed by setup; put custom sites in the
site directory. Existing site and app examples are preserved, not overwritten.
The local admin socket is `/run/caddy/admin.sock`, not an
exposed TCP port.

For Cloudflare, create an API token under **My Profile > API Tokens**.
Use **Edit zone DNS**, restricted to your zone, with **Zone:Read** and
**DNS:Edit**. Private setup asks for it with hidden input, retries empty or
invalid pastes, and reports where it saved the token. The token belongs in
`/etc/caddy/caddy.env`, not `caddy.conf`; systemd already loads that file.
To add or replace it manually:

```sh
sudoedit /etc/caddy/caddy.env   # CLOUDFLARE_API_TOKEN=your-token, one assignment
sudo systemctl restart caddy
```

This token is for DNS-01 certificate validation, not DDNS. Caddy still gets
the certificate from an ACME issuer. Public setup does not prompt for a
token, so `caddy.env` may be empty. Its starter is HTTP until you give the
site a domain and configure HTTPS. Add the token if that site uses
`dns cloudflare {env.CLOUDFLARE_API_TOKEN}` for DNS validation.
See [Cloudflare tokens](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
and [Caddy DNS challenges](https://caddyserver.com/docs/caddyfile/directives/tls#dns).

```sh
sudo systemctl reload caddy    # site/Caddyfile changes
sudo systemctl restart caddy   # token, binary, or service changes
sudo systemctl status caddy
sudo journalctl -u caddy -n 50 --no-pager
```

Static sites import `security` and `conceal`; `conceal` already includes
`file_server`. Point build outputs at `/var/www/<domain>/dist`, not the
project checkout. Do not place secrets there or symlink outside that root.
Docker apps belong under `/var/app/<project>` and bind published ports to
loopback for Caddy to proxy.

### VPN and applications

`make configure-vpn vpn=tailscale` or `vpn=wireguard` saves and applies
that VPN. Tailscale accepts an auth key or browser login. WireGuard prints
the client profile location. Switching VPNs requires stopping the old one
first from a connection that does not depend on it.

Use Compose in each app directory, or use `lazydocker`:

```sh
cd /var/app/hono.ohmstack.net
dcup
dcps
dcdown
```

The Hono template lives in [build/hono](build/hono). It uses TypeScript,
Node, and pnpm. It serves `/`, `/api/hello`, and
`/healthz`. It does not need Vite for this API-only example.

`make deploy-key REPO=example` creates a repository-scoped key at
`~/.ssh/deploy-keys/example/id_ed25519` and prints the GitHub setup steps.
Use a read-only deploy key instead of copying a personal GitHub private key.

## Where things live

| Path | Owner |
| --- | --- |
| `/opt/vps` | Setup scripts, templates, pinned dotfiles checkout |
| `/etc/vps/host.conf` | Saved hostname, admin, VPN, update choices |
| `/etc/caddy` | Caddy mode, token, and site configuration |
| `/var/www/<domain>` | Static files |
| `/var/app/<project>` | Docker application and Compose file |
| `/data` | Persistent service data and backups |

Host dependencies live in `config/apt`; user tools belong to dotfiles.

## Testing

From the VPS checkout:

```sh
make check-repo
make -C dotfiles check
DRY_RUN=1 make setup mode=basic
DRY_RUN=1 make setup mode=advanced
DRY_RUN=1 make setup-host
```

Dry runs print planned steps without changing the host. They skip prompts
and live host checks, so use a disposable VM for a full setup test.

### Local VM testing

The VM commands use QEMU on an Apple silicon Mac. Install `qemu` and
`openssl@3` with Homebrew. The Ubuntu ARM64 image must be at
`~/Developer/distros/ubuntu-26.04/ubuntu-26.04-server-cloudimg-arm64.img`.

```sh
make create-vm name=lab
make list-vm
make start-vm name=lab display=gui
```

Log in as `admin` with the password chosen during creation. Pressing Enter
there uses `password`, for isolated test VMs only. For SSH from the Mac,
replace `PORT` with the forwarded port shown by `make list-vm`, not port 22:

```sh
ssh -t -p PORT admin@127.0.0.1
```

Inside the VM, run the curl command under [Start](#start). If `/opt/vps`
already exists, [update that checkout](#change-an-existing-host) first.
Test Basic and Advanced on separate fresh VMs. Keep the console open during
the Advanced SSH handoff; its key-copy and login commands need the Mac's
forwarded port too. Test both confirmation and the five-minute rollback.

Stop or remove the test VM from the Mac. Teardown asks for confirmation
before deleting the VM and its disk:

```sh
make stop-vm name=lab
make teardown-vm name=lab
```
