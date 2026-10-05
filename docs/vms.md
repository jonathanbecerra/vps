# Local VMs

Use the same guided setup as a physical Ubuntu box. QEMU forwards SSH to a
host port between 2222 and 2299. Check the assigned port before connecting.

On the Mac, from the VPS checkout:

```sh
make create-vm name=lab vcpu=8 memory=16 storage=64
make list-vm
make start-vm name=lab display=gui
```

Log in as `admin` with the password chosen during creation. The VM creation
default is `password`; use it only in an isolated test VM.

Copy the checkout from the Mac using password SSH, then log in. Substitute
the assigned forwarded port if it is not 2222:

```sh
rsync -av --filter="merge .rsyncignore" -e 'ssh -p 2222' ./ admin@127.0.0.1:/home/admin/vps/
ssh -t -p 2222 admin@127.0.0.1
```

Inside the VM:

```sh
cd ~/vps
sudo --preserve-env=SSH_CONNECTION ./setup-vps.sh
```

Choose Advanced to rehearse the key handoff. Use `127.0.0.1` and the Mac's
forwarded port in the printed copy/login commands, not the guest IP and 22.
In the new key session, run `cd /opt/vps` and `make confirm-ssh`.

After setup, sync to `/opt/vps`, not the original home checkout:

```sh
rsync -av --filter="merge .rsyncignore" -e 'ssh -i ~/.ssh/gh_ed25519 -p 2222' ./ admin@127.0.0.1:/opt/vps/
```

`make stop-vm name=lab` shuts down the VM. `make teardown-vm name=lab`
deletes that VM and its disk after confirmation.
