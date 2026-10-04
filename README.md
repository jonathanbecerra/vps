# VPS

This repository turns a fresh Ubuntu machine into a usable Docker host. It
sets up the admin account, SSH handoff, updates, Docker and Compose, UFW,
fail2ban, automatic security updates, and the selected Caddy role. App stacks
are added later.

## 1. Get the code

Clone with the optional user environment included:

```sh
git clone --recurse-submodules git@github.com:jonathanbecerra/vps.git
cd vps
```

If the repository is already cloned:

```sh
git submodule update --init --recursive
```

The root repository configures the box. The `dotfiles/` submodule configures a
user's shell and editor and can also be used by itself on a Mac or another
Linux machine.

## 2. Bootstrap a remote VPS

Use the initial Ubuntu account and password for the first touch. If password
SSH is unavailable, use the machine's local console. Do not edit SSH
configuration by hand; the setup script enables temporary access when needed,
and `make configure-ssh` hardens it afterward.

From the Mac, copy the key and project. Replace `ubuntu` and `HOST` if your
image uses different values:

```sh
cat ~/.ssh/gh_ed25519.pub | ssh -p 22 \
  -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password \
  ubuntu@HOST \
  'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys'
rsync -av --filter="merge .rsyncignore" -e 'ssh -i ~/.ssh/gh_ed25519' ./ ubuntu@HOST:/home/ubuntu/vps/
```

Log in to the box:

```sh
ssh -t -i ~/.ssh/gh_ed25519 ubuntu@HOST
```

Inside the box, run:

```sh
cd ~/vps
sudo ./setup-vps.sh
```

The setup script moves the project to `/opt/vps`, creates the selected admin
account, asks whether this host is a public Caddy ingress, private Caddy
ingress, or has no Caddy, installs the base security controls, and prints the
handoff steps.
Replace `admin` below with the admin username selected during setup. Keep that
session open. Open a fresh key session as the selected admin and harden SSH:

```sh
ssh -t -i ~/.ssh/gh_ed25519 admin@HOST
```

Inside that session, run:

```sh
cd /opt/vps
make configure-ssh
```

Open one more fresh key session to confirm the handoff, then finish setup and
install the optional user environment:

```sh
ssh -t -i ~/.ssh/gh_ed25519 admin@HOST
```

Inside that fresh session, run:

```sh
cd /opt/vps
make confirm-ssh
make setup-host
make install-dotfiles
```

After hardening, the normal login is:

```sh
ssh -t -i ~/.ssh/gh_ed25519 -p 22 admin@HOST
```

Use `DRY_RUN=1 make setup-host` to preview host changes and reboot when ready.

## 3. Bootstrap a local VM

The local VM forwards SSH to a port between `2222` and `2299`.

```sh
make list-vm
make start-vm name=lab display=gui
```

Replace `lab` with your VM name.

In the VM window, log in as `admin` with the password chosen during creation
(`password` by default). From your Mac, copy your public key into the VM once:

```sh
cat ~/.ssh/gh_ed25519.pub | ssh -p 2222 admin@127.0.0.1 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys'
```

Copy the project from the Mac:

```sh
rsync -av --filter="merge .rsyncignore" -e 'ssh -i ~/.ssh/gh_ed25519 -p 2222' ./ admin@127.0.0.1:/home/admin/vps/
```

Then log in and run the same setup flow inside the VM:

```sh
ssh -t -i ~/.ssh/gh_ed25519 -p 2222 admin@127.0.0.1
```

Inside the VM, run:

```sh
cd ~/vps
sudo ./setup-vps.sh
```

After setup moves the project to `/opt/vps`, open a fresh key session:

```sh
ssh -t -i ~/.ssh/gh_ed25519 -p 2222 admin@127.0.0.1
```

Inside that session, run:

```sh
cd /opt/vps
make configure-ssh
```

Open one more fresh key session:

```sh
ssh -t -i ~/.ssh/gh_ed25519 -p 2222 admin@127.0.0.1
```

Inside that session, run:

```sh
cd /opt/vps
make confirm-ssh
make setup-host
make install-dotfiles
```

Later changes use:

```sh
rsync -av --filter="merge .rsyncignore" -e 'ssh -i ~/.ssh/gh_ed25519 -p 2222' ./ admin@127.0.0.1:/opt/vps/
```

Replace `2222` if your VM uses another forwarded port, or replace the key path
if your key has a different filename.

## 4. Finish host setup

After SSH is confirmed, run this inside `/opt/vps`:

```sh
make setup-host
make install-dotfiles
```

`make setup-host` synchronizes the clock, installs the host packages and
security controls, applies the selected Caddy role, and shows the final status.
You do not need to run `make sync-time` separately.

### Caddy

Caddy is a native systemd service. `make setup-host` builds it with the
Cloudflare DNS module, installs it under `/usr/local/bin/caddy`, enables it at
boot, and applies the role selected during first setup:

| Role | Result | Use it for |
| --- | --- | --- |
| `public` | Installs Caddy, creates the initial static site, and allows 80/tcp, 443/tcp, and 443/udp in UFW. | A DMZ or public-ingress host serving sites or direct public services. |
| `private` | Installs Caddy and the Cloudflare DNS module, creates the Hono Docker example, and allows Caddy only on the host's private interface. | Internal names such as `scrypted.ohmstack.net` and `hono.ohmstack.net`. |
| `none` | Does not install or start Caddy. | Application-only hosts such as a Pi running Scrypted. |

New hosts default to `none`; public ingress is always an explicit choice. The
role is stored in `/etc/caddy/caddy.conf`; `/etc/vps/host.conf` stores
host and VPN settings only. If an older host has no Caddy role file,
`make setup-host` asks once and defaults safely to private ingress. The
Cloudflare token belongs in `/etc/caddy/caddy.env`.

`public` means the host is prepared to receive public traffic; individual
hostnames still depend on their DNS records, Cloudflare settings, router
forwarding, and Caddy site files. `private` still uses Cloudflare for DNS-01
certificate validation, but it must not have a WAN port-forward. UniFi remains
responsible for the VLAN boundary, while UFW limits the host-side listener.

Site configs live in `/etc/caddy/sites-available/`, are enabled through
`sites-enabled/`, and use these runtime paths:

```text
/var/www/<domain>/       Static file-server sites
/var/app/<project>/     Docker applications and their Compose files
```

The provisioning repository remains in `/opt/vps`. It owns the templates and
examples; runtime application data belongs under `/var/app` or `/var/www`.

The parent Caddyfile keeps Caddy's admin API on the local
`/run/caddy/admin.sock` with mode `0600`; systemd uses it for safe reloads
without exposing an admin port.

The Cloudflare token is used by both Caddy roles when a site uses DNS-01
certificate validation. This lets Caddy prove domain ownership through a TXT
record for private names, wildcard domains, or when HTTP validation is
unsuitable. In Cloudflare, go to **My Profile → API Tokens → Create Token** and
use **Edit zone DNS**, limited to the specific zone, with:

```text
Zone:Read
DNS:Edit
```

Do not use a Global API Key. See the [Cloudflare token guide](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
and [Caddy's DNS challenge options](https://caddyserver.com/docs/caddyfile/options#acme_dns).

On the host, store the token in `/etc/caddy/caddy.env`:

```sh
sudo install -o root -g caddy -m 0640 /dev/null /etc/caddy/caddy.env
sudoedit /etc/caddy/caddy.env
```

Add:

```text
CLOUDFLARE_API_TOKEN=your-token
```

The systemd service already loads that file. Caddy uses the token only when the
site references it. The private Hono example already does this:

```caddyfile
hono.ohmstack.net {
  tls {
    dns cloudflare {env.CLOUDFLARE_API_TOKEN}
  }

  reverse_proxy 127.0.0.1:3000
}
```

For private names, create an internal DNS record such as
`hono.ohmstack.net → <private-Caddy-IP>`. Do not publish a public `A` or `AAAA`
record for a service that should remain internal. Caddy can still obtain the
publicly trusted certificate through Cloudflare DNS-01.

Reload Caddy after changing the token or site:

```sh
sudo systemctl reload caddy
```

The private role creates a small Hono TypeScript API at
`/var/app/hono`, builds it with Docker, and binds it only to
`127.0.0.1:3000`. It serves:

```text
GET /          {"message":"Hello from Hono","service":"hono"}
GET /api/hello {"message":"Hello from Hono"}
GET /healthz   {"ok":true}
```

The example uses `pnpm@12.8.1`, matching the dotfiles setup. It is a Node.js
API using Hono's Node adapter, so it does not need Vite. Hono's Vite plugins
are for front-end/framework templates; add Vite when this project grows a
browser-facing frontend. See the [Hono Node.js guide](https://hono.dev/docs/getting-started/nodejs).
For local work:

```sh
cd /var/app/hono
pnpm install
pnpm run build
```

Static sites should import the reusable `conceal` snippet. It hides repository
metadata, environment files, keys, logs, editor files, backups, and source
maps. For Astro, Angular, React, or similar builds, point `root` at
`/var/www/<domain>/dist`; Caddy then serves only that directory, not its
parent. Docker applications should live under `/var/app/<project>`, bind to
loopback, and use a `reverse_proxy` block in the site config.

## 5. Add the optional dotfiles

On the host, run it from the submodule checkout:

```sh
cd /opt/vps/dotfiles
make install
```

On a Mac, clone the standalone repository and run the same `make install`
there. Both install commands reload Zsh after Stow completes. From the VPS
root, `make install-dotfiles` calls the same entry point.
It does not change host users, SSH, firewalls, Docker, or services. See
[dotfiles/README.md](dotfiles/README.md) for refresh, restore, and Homebrew
cleanup.

## 6. Add services when you need them

The box is secure and useful before any application is deployed. Add a service
under `stacks/<name>/`, include its Compose file in `stacks/compose.yaml`,
then lock and start the images:

```sh
make lock-images
make up
make show-containers
```

Keep app ports behind Caddy and bind any required host port to `127.0.0.1`.
`make show-status` flags published ports exposed on other addresses. Docker
forwarding is denied by UFW, and UniFi remains responsible for traffic between
the network zones.

Point each hostname at the VPS. Keep application ports bound to loopback so
only Caddy exposes them publicly.

For a repository that the host should clone, create a repository-scoped GitHub
deploy key instead of giving the host a personal GitHub key:

```sh
make deploy-key REPO=example
```

Add the printed public key to that GitHub repository as a read-only deploy key.
The command stores the private key as
`~/.ssh/deploy-keys/<repo>/id_ed25519` and adds a repository-specific SSH alias.
Clone with the printed `git@github-...` URL.

## 7. Make changes safely

Run checks before copying changes to a host:

```sh
make check-repo
make preview-deploy HOST=HOST
make sync-repo HOST=HOST
```

For a local VM, use the forwarded port and key shown in the local VM section.
Always sync to `/opt/vps` after setup, never the temporary home checkout. Host
packages live in `config/apt/packages.txt`; the standalone dotfiles repository
owns user tools and its Homebrew manifest.
