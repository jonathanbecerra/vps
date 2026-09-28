# VPS

Ubuntu only. Run `setup-vps.sh` on the box. After bootstrap, use `/opt/vps`.

## Mac keys

Use a separate `<name>_ed25519` key per target: `gh`, `bb`, `bl`, `ht`, `lab`.

```sh
ssh-keygen -t ed25519 -C "your_email@example.com" -f ~/.ssh/lab_ed25519
eval "$(ssh-agent -s)"
/usr/bin/ssh-add --apple-use-keychain ~/.ssh/lab_ed25519
pbcopy < ~/.ssh/lab_ed25519.pub
```

Create `~/.ssh/config` if needed, then add the GitHub key:

```sshconfig
Host github.com
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/gh_ed25519
  IdentitiesOnly yes
```

Pass the target key with `-i` in SSH and rsync commands.

## Local Ubuntu VM

```sh
make create-vm name=lab
make start-vm name=lab
```

Use `display=gui` for a QEMU window. `make attach-vm name=lab` opens only the serial console. Log in as `admin`; the create command shows the password.

From the Mac, copy the key and repo. Change port `2222` if the create command shows another one.

```sh
command cat ~/.ssh/lab_ed25519.pub | ssh -i ~/.ssh/lab_ed25519 -p 2222 admin@127.0.0.1 'install -d -m 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
rsync -av --filter="merge .rsyncignore" -e 'ssh -i ~/.ssh/lab_ed25519 -p 2222' ./ admin@127.0.0.1:~/vps/
```

At the VM console:

```sh
cd ~/vps
sudo ./setup-vps.sh --key /home/admin/.ssh/authorized_keys
```

Setup moves the repo to `/opt/vps` and removes `~/vps`. Keep this console open. In another Mac terminal, connect as `admin` and run:

```sh
ssh -i ~/.ssh/lab_ed25519 -p 2222 admin@127.0.0.1
cd /opt/vps
make configure-ssh
```

Open a fresh connection, then confirm SSH and finish host setup:

```sh
ssh -o ControlPath=none -i ~/.ssh/lab_ed25519 -p 2222 admin@127.0.0.1
cd /opt/vps
make confirm-ssh
make setup-host
```

Setup asks whether to use Caddy and which VPN to use. To configure Caddy later, run this on the host:

```sh
make configure-caddy
```

Choose one app or multiple apps. For one app, enter its hostname and, if known, the upstream `host:port`. Leaving the upstream blank creates an editable route and skips startup. Add a `reverse_proxy` or `file_server` with `vim`, then run `make configure-services`.

For multiple apps, the command copies `stacks/caddy/caddy-sites-example.caddy` to `/opt/vps/.local/caddy-sites.caddy` and stops. The example has a web app, a REST API, and a static blog. Edit the file with `vim`, replace the example hostnames and upstreams, then run `make configure-services`. Put blog files in `/data/www/blog`; Caddy reads them at `/srv/blog`.

Edit `/opt/vps/.local/caddy-sites.caddy` to change routes, then run `make configure-services` to apply them. Run `make configure-caddy` to start over; answer `yes` to replace the saved routes or `no` to keep and apply them. Point each hostname's DNS record at the VPS.

`make configure-services` handles the saved Caddy choice, then the saved VPN choice. Use `make configure-tailscale` or `make configure-wireguard` to configure only that VPN.

Create a Cloudflare API token with `Zone:Read` and `DNS:Edit`, limited to the zone or zones used by those hostnames. The token is entered without echo and saved in `/opt/vps/.local/caddy.env` with mode `0600`. UFW opens TCP 80/443 and UDP 443; add the same inbound rules to the Hetzner firewall. WireGuard creates `/opt/vps/.local/wireguard-client.conf`; open UDP 51820 in the provider firewall too.

## Hetzner

```sh
ssh-keygen -t ed25519 -C "your_email@example.com" -f ~/.ssh/ht_ed25519
/usr/bin/ssh-add --apple-use-keychain ~/.ssh/ht_ed25519
pbcopy < ~/.ssh/ht_ed25519.pub
```

Add the public key when creating the server. Add an alias to `~/.ssh/config`:

```sshconfig
Host hetzner
  HostName 203.0.113.10
  User admin
  AddKeysToAgent yes
  UseKeychain yes
  IdentityFile ~/.ssh/ht_ed25519
  IdentitiesOnly yes
```

For a root login, copy the repo and run setup with a TTY. If the provider created an admin user, log in as that user and run setup with `sudo`.

```sh
ssh -i ~/.ssh/ht_ed25519 root@hetzner 'mkdir -p /root/vps'
rsync -av --filter="merge .rsyncignore" -e 'ssh -i ~/.ssh/ht_ed25519' ./ root@hetzner:/root/vps/
ssh -t -i ~/.ssh/ht_ed25519 root@hetzner 'cd /root/vps && ./setup-vps.sh'
```

The repo moves to `/opt/vps`. Log in as `admin`, run `make configure-ssh`, confirm from a fresh connection within five minutes, then run `make setup-host`.

## Later changes

Always sync to `/opt/vps`, never `~/vps`:

```sh
make preview-deploy HOST=hetzner
make sync-repo HOST=hetzner
```

For the local VM, include its key and port:

```sh
rsync -avz --delete-after --filter="merge .rsyncignore" -e 'ssh -i ~/.ssh/lab_ed25519 -p 2222' ./ admin@127.0.0.1:/opt/vps/
```

Packages are in `config/apt/packages.txt`; run `make install-packages` or `make install-tools` after changes. Use `DRY_RUN=1 make setup-host` to preview. Run `make check-repo` before syncing.
