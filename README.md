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

Setup asks once about Docker Caddy and VPN. Later, `make configure-services` applies those choices and asks only for missing domains or credentials. Example: `make configure-services caddy=docker vpn=tailscale`. WireGuard creates `/opt/vps/.local/wireguard-client.conf`; open UDP 51820 in the provider firewall too.

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
