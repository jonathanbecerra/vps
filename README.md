# VPS

This repository turns a fresh Ubuntu machine into a usable Docker host. It
sets up the admin account, SSH handoff, updates, Docker and Compose, UFW,
fail2ban, and automatic security updates. App stacks are added later.

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

### Temporary password bootstrap

If a fresh Ubuntu image has no authorized key and password SSH is disabled, log
in on the local console and set `PasswordAuthentication yes` in
`/etc/ssh/sshd_config` and the existing cloud-init drop-in, usually
`/etc/ssh/sshd_config.d/50-cloud-init.conf`. A console-safe update is:

```sh
sudo sh -c '
for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*cloud-init*.conf; do
  [ -f "$file" ] || continue
  if grep -Eq "^[[:space:]]*PasswordAuthentication[[:space:]]+" "$file"; then
    sed -Ei "s/^[[:space:]]*PasswordAuthentication[[:space:]].*$/PasswordAuthentication yes/" "$file"
  else
    printf "\\nPasswordAuthentication yes\\n" >>"$file"
  fi
done
sshd -t && systemctl restart ssh
'
```

The setup script uses those same files on first boot. It does not create a
second password override. `make configure-ssh` changes them back to `no`,
disables root login, and requires public keys for the admin user.

Copy the Mac key over port 22. Port 2222 is only for the local VM flow below:

```sh
cat ~/.ssh/gh_ed25519.pub | ssh -p 22 \
  -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password \
  ubuntu@HOST \
  'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys'
```

`make configure-ssh` changes the settings back to `no` after key-only SSH
passes. If the handoff rolls back, it restores the saved SSH files.

Copy the repository to the new host, then run setup as root. The repository is
moved to `/opt/vps` when setup finishes. Replace `HOST` with the host or SSH
alias you configured.

```sh
rsync -av --filter="merge .rsyncignore" -e 'ssh -i ~/.ssh/gh_ed25519' ./ root@HOST:/root/vps/
ssh -t -i ~/.ssh/gh_ed25519 root@HOST 'cd /root/vps && ./setup-vps.sh'
```

Keep that session open. In a second terminal, finish the SSH handoff:

```sh
ssh -t -i ~/.ssh/gh_ed25519 admin@HOST 'cd /opt/vps && make configure-ssh'
ssh -t -i ~/.ssh/gh_ed25519 admin@HOST 'cd /opt/vps && make confirm-ssh && make sync-time && make setup-host'
```

After hardening, log in with the admin account and key on port 22:

```sh
ssh -t -i ~/.ssh/gh_ed25519 -p 22 admin@HOST
```

For the Pi used during setup:

```sh
ssh -t -i ~/.ssh/gh_ed25519 -p 22 admin@10.10.90.159
```

Use `DRY_RUN=1 make setup-host` to preview host changes. Check the result with
`make show-status` and reboot when ready.

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

Then copy the project and run setup:

```sh
rsync -av --filter="merge .rsyncignore" -e 'ssh -i ~/.ssh/gh_ed25519 -p 2222' ./ admin@127.0.0.1:/home/admin/vps/
ssh -t -i ~/.ssh/gh_ed25519 -p 2222 admin@127.0.0.1 'cd /home/admin/vps && sudo ./setup-vps.sh'
ssh -t -i ~/.ssh/gh_ed25519 -p 2222 admin@127.0.0.1 'cd /opt/vps && make configure-ssh'
ssh -t -i ~/.ssh/gh_ed25519 -p 2222 admin@127.0.0.1 'cd /opt/vps && make confirm-ssh && make sync-time && make setup-host'
```

Setup creates `/opt/vps` and moves the project there. Later changes use:

```sh
rsync -av --filter="merge .rsyncignore" -e 'ssh -i ~/.ssh/gh_ed25519 -p 2222' ./ admin@127.0.0.1:/opt/vps/
```

Replace `2222` if your VM uses another forwarded port, or replace the key path
if your key has a different filename.

## 4. Add the optional dotfiles

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

## 5. Set up Caddy

Caddy runs as a native systemd service. Docker does not run Caddy. The setup
command builds Caddy with the Cloudflare DNS module, installs it under
`/usr/local/bin/caddy`, enables it at boot, and creates the first site. It runs
as part of `make setup-host`:

```sh
make setup-host
```

The first run creates an HTTP hello-world site at `example.com` and serves it
from the server's port 80. It creates:

```text
/etc/caddy/Caddyfile
/etc/caddy/sites-available/<domain>.caddy
/etc/caddy/sites-enabled/<domain>.caddy -> ../sites-available/<domain>.caddy
/var/www/<domain>/
```

The tracked starter files follow the same site-per-directory layout:

```text
config/caddy/www/<domain>/
├── index.html
└── errors/
    ├── 404.html
    └── 500.html
```

Static sites should import the reusable `conceal` snippet from the parent
Caddyfile. It hides repository metadata, environment files, keys, logs,
editor files, backups, and source maps. For Astro, Angular, React, or similar
builds, point `root` at `/var/www/<domain>/dist`; Caddy then serves only that
directory, not its parent. Each site also gets custom error pages under
`/var/www/<domain>/errors/`. Docker applications should bind to loopback and
use a `reverse_proxy` block in the Caddy site. Replace the example site in
`/etc/caddy/sites-available/example.com.caddy` when you are ready to add a
real domain.

The custom binary includes the Cloudflare DNS module. Add the Cloudflare token
to `/etc/caddy/caddy.env` only when a site needs DNS-01 certificates. Caddy
listens on ports 80 and 443 and starts on boot.

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
