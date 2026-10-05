# Setup and dotfiles review

This is a maintainability and workflow review, with a focused source review of
the SSH handoff. It is not a full security audit or a claim about the live Pi,
UniFi rules, Cloudflare account, or running services.

## Git state

The existing changes were committed and pushed before this work:

| Repository | Published main |
| --- | --- |
| dotfiles | `e6da639`, including `f1b6fd8` for shell definitions and native grep |
| vps | `471fb48`, updating the dotfiles pin to that main |

The review changes are committed on `develop` in both repositories. VPS pins
the reviewed dotfiles commit, and the nested checkout matches the standalone
checkout. `main` remains at the versions above. No live host was changed.

## What changed and why

| Area | Change | Reason |
| --- | --- | --- |
| Entry point | Added `install.sh`; `make setup` and `setup-vps.sh` run one Basic/Advanced guide | One first-time flow instead of a chain of manual Make commands |
| Basic | Keeps identity/password/SSH, selects no Caddy/VPN, creates both examples, installs dotfiles | A usable host without an account migration or forced SSH hardening |
| Advanced | Foreground password prompt, key-copy wait, timed confirmation, then service choices and dotfiles | A password prompt must have a terminal; later services must not bypass the SSH decision |
| Login shell | New accounts use Bash for the handoff; select Zsh after dotfiles install succeeds | Avoid an unconfigured Zsh session while trying to confirm SSH |
| SSH state | Attempt-specific receipt, fresh public-key login check, monotonic countdown, shared confirmation/rollback lock | Missing pending state is not proof of success; a password session is not proof of key access |
| SSH backups | Prepare a complete backup before marking a handoff pending | Interrupted preparation should not leave an incomplete rollback record |
| Checkout | Preserve Git/submodule metadata in `/opt/vps`; keep the original checkout; use installed dotfiles paths | Allows `git pull` and prevents links into a temporary download that will disappear |
| VPN source | Moved `scripts/compose/*` and the WireGuard installer under `scripts/vpn/` | Their purpose is VPN configuration, not general app management |
| Caddy build | Moved the builder from `stacks/caddy` to `build/caddy` | It produces a native binary; it is not a running Caddy container stack |
| Hono build | Moved the Hono template to `build/hono` | Keep the build projects together without an examples directory; the deployed path stays `/var/app/hono.ohmstack.net` |
| Caddy environment | Removed startup environment printing; validation loads the same token file as the service | Avoid printing the token and avoid validation with a different environment |
| Caddy service | Setup restarts after binary/unit/token changes; README separates restart from reload | A config reload does not replace the running binary or refresh its service environment |
| Caddy templates | Reuse `conceal` in the error handler and remove the duplicate `file_server` | Keep file-server behavior in one snippet |
| Status | Report unmanaged SSH authentication without failing Basic | Basic deliberately leaves authentication alone |
| Tailscale | Accept `STACK=tailscale` in the lock verifier; complete browser login when no key is supplied | The deploy command exported a value that its own verifier rejected |
| Dotfiles ownership | Moved the editor check into dotfiles; VPS keeps a thin wrapper | The standalone repository should own tests for the editor it installs |
| Editor checks | Check YAML schemas as a map and return failure when a Lua assertion fails | The old check used an array length for YAML and could report errors while exiting successfully |
| Dotfiles refresh | Stop backing up local overrides, generic project directories, and unrelated tools | Refresh should not move personal customization or unrelated work |
| Shell helpers | Use native `whence` for `define`; share the selected Compose command; remove the duplicate unconditional `cat` alias | Less custom logic and consistent macOS/Linux behavior |
| Docker teardown | Stop on lookup errors, resolve the container ID, keep shared resources, explicitly prune unused named volumes after confirmation | Errors must not look like empty resource lists; global teardown must match its warning |
| Documentation | One guided setup flow, separate VM guide, update methods, runtime path table, Caddy restart command | Keep first setup separate from maintenance and recovery |

The `dtd` change is intentionally destructive after confirmation. Docker's
[`system prune --volumes`](https://docs.docker.com/reference/cli/docker/system/prune/)
only includes anonymous volumes. The helper now also uses
[`volume prune --all`](https://docs.docker.com/reference/cli/docker/volume/prune/)
for unused named volumes. No teardown command was run against real Docker data.

## User flow

Basic starts from an existing regular user. It updates Ubuntu, installs the
host packages and protection, creates `/var/www/ohmstack.net` and
`/var/app/hono.ohmstack.net`, and installs that user's dotfiles. It does not
ask for a new hostname or password, and does not change SSH authentication.

Advanced asks for hostname and admin username, updates Ubuntu, then sets the
account password. If the account has no public key, it prints the copy command
and waits. Next it hardens SSH and shows the five-minute countdown. The new
key session must run `make confirm-ssh`. The original session watches the
receipt, then asks whether to continue with Caddy, VPN, and dotfiles.

Timeout restores the saved SSH settings. Retry starts another handoff; Stop
ends setup; Continue prints a red warning and proceeds without confirmed
hardening. Stopping at this gate leaves account, hostname, and package changes
in place, without starting the later phases. Stopping after those phases have
begun does not undo their completed changes.

## What stayed

Stow's package layout, pinned dependencies, Neovim configuration, and separate
macOS/Linux installers remain. The two repositories stay independently usable.
No shared framework, new runtime dependency, or generic installer engine was
added. Ponytail guided the reuse of existing installers and native shell
commands; unslop guided the shorter task-based documentation.

Existing Make commands remain for maintenance and recovery. Runtime SSH state
keeps its existing paths so this refactor does not strand older pending
rollbacks. The source-directory moves do not relocate deployed applications.

## Validation and remaining work

Final static checks passed: Bash/POSIX-sh/Zsh syntax, ShellCheck, shfmt, JSON,
Docker Compose configuration, and `git diff --check`. Both published main refs
were checked against GitHub after branching.

The local regression suites passed on macOS. They cover SSH receipts and
public-key input, Basic/Advanced previews, VPN previews, preservation of
local dotfiles, and stubbed Docker cancellation/error/shared-resource
behavior. They ran with network access denied, writes confined to a temporary
directory, and CPU and wall-time limits. VM process enumeration was blocked
by the sandbox; no VM or Docker daemon was used. These checks do not replace
an Ubuntu setup rehearsal.

The downloaded, pinned Neovim check also passed after fixing its YAML-map
assertion. A separate failure fixture verified that an assertion error now
returns a nonzero exit status. Editor downloads used network access but kept
their files in the temporary directory.

Before merging, use a disposable Ubuntu VM with console access:

1. Run the local check suites with network disabled and bounded resources.
   Do not run the real teardown helpers against a personal Docker daemon.
2. Rehearse Basic and verify that identity/password/SSH remain unchanged,
   both examples exist, and dotfiles point into `/opt/vps/dotfiles`.
3. Rehearse Advanced with both an existing and a newly created admin. Confirm
   that an old/password session is rejected and a fresh key session succeeds.
4. Let the full timer expire. Check restoration, retry, Stop, and explicit
   Continue. Also interrupt setup while the timer is armed and verify that
   systemd still restores SSH.
5. Exercise Caddy's three modes and repeat setup. Check the service token
   environment, managed firewall rules, Hono behavior, and a Git pull from
   the installed checkout. Rehearse VPN login separately if selecting it.

The owner made both repositories public. The guided curl entry point is
published on `develop`, not `main`. Use the development URL and `VPS_REF`
shown in the README to fetch the matching code and pinned dotfiles. No
release or live-host setting was changed.

An anonymous recursive clone fetched the pinned dotfiles commit, and both
local check suites passed from that clone. The public installer download
matched the committed file and passed POSIX shell syntax validation.

One live-host follow-up is worth checking privately. The old Caddy unit used
[`--environ`](https://caddyserver.com/docs/command-line#caddy-run), which prints
environment values at startup. If that unit ran with a real Cloudflare token,
the token may be in the journal. Rotate it if exposed; this review did not
inspect the journal or rotate credentials.

Private Caddy still relies on the surrounding LAN/VPN firewall. Its interface
rule alone does not reject internet traffic arriving on that interface.
Keep this distinction when deciding which box receives WAN traffic.
