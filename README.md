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

## 5. Add services when you need them

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

Caddy is optional and is configured manually after you know the routes:

```sh
make configure-caddy
# edit /opt/vps/.local/caddy-sites.caddy
make configure-services
```

Point each hostname at the VPS and keep Cloudflare credentials in the local
`.local` files; they are never committed.

## 6. Make changes safely

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
