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

## 2. Bootstrap the box

Copy the repository to the new host, then run setup as root. The repository is
moved to `/opt/vps` when setup finishes.

```sh
rsync -av --filter="merge .rsyncignore" ./ root@HOST:/root/vps/
ssh -t root@HOST 'cd /root/vps && ./setup-vps.sh'
```

Keep the first SSH session open. In a second terminal, connect as the new
`admin` user with its key and finish the SSH handoff:

```sh
cd /opt/vps
make configure-ssh
```

Open a fresh connection before the five-minute rollback expires, then run:

```sh
cd /opt/vps
make confirm-ssh
make setup-host
```

Use `DRY_RUN=1 make setup-host` to preview host changes. Check the result with
`make show-status` and reboot when ready.

For a local Ubuntu VM, the same flow is available through `make create-vm`,
`make start-vm`, and the SSH port shown by the VM command.

## 3. Add the optional dotfiles

On the host, run it from the submodule checkout:

```sh
cd /opt/vps/dotfiles
make install
exec env -u ZDOTDIR zsh -l
```

On a Mac, clone the standalone repository and run the same `make install`
there. From the VPS root, `make install-dotfiles` calls the same entry point.
It does not change host users, SSH, firewalls, Docker, or services. See
[dotfiles/README.md](dotfiles/README.md) for refresh, restore, and Homebrew
cleanup.

## 4. Add services when you need them

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

## 5. Make changes safely

Run checks before copying changes to a host:

```sh
make check-repo
make preview-deploy HOST=HOST
make sync-repo HOST=HOST
```

For a local VM, pass its SSH key and port to `rsync`. Always sync to
`/opt/vps`, never the temporary home checkout. Host packages live in
`config/apt/packages.txt`; the standalone dotfiles repository owns user tools
and its Homebrew manifest.
