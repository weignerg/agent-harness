# Windows (WSL) — One-Command Install

Install `agent-harness` on Windows 10/11 using the Windows Subsystem for Linux (WSL2). This
guide covers the self-extracting **v0.7.6** Windows artifact
`install-agent-harness-v0.7.6-windows10-11.ps1` (built from `windows/install-windows.ps1`
by `release-build/make_windows_installer.ps1`).

> **Private repo note:** `agent-harness` is a **private** repository, so there is no
> anonymous install URL. Releases ship **exactly two** self-extracting artifacts —
> `install-agent-harness-v0.7.6-linux.sh` (Linux) and
> `install-agent-harness-v0.7.6-windows10-11.ps1` (Windows 10/11 WSL2) — each embedding the
> full runtime tree as `base64(tar.gz)` after `#__HARNESS_PKG_EOF__`. There is no separate
> tarball to download and no `git clone` / remote fetch anywhere.

## TL;DR

On Windows 10/11: download the single self-extracting Windows artifact, then run **ONE**
command. It self-elevates, provisions WSL2 + Ubuntu (with systemd persistence and
Task Scheduler auto-resume across the one mandatory reboot), verifies and self-extracts its
embedded runtime tree to `$env:USERPROFILE\agent-harness`, and runs the embedded Linux
installer inside WSL.

1. **Download the artifact.** From the GitHub release page
   `https://github.com/weignerg/agent-harness/releases`, download
   `install-agent-harness-v0.7.6-windows10-11.ps1` (or build it from a checkout with
   `pwsh -NoProfile -File release-build/make_windows_installer.ps1`).
2. **Run the one command:**
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-agent-harness-v0.7.6-windows10-11.ps1
   ```

That single command self-elevates, sets up WSL + Ubuntu, registers automatic post-reboot
resume before asking for the one mandatory reboot, then self-extracts the embedded runtime
tree into `$env:USERPROFILE\agent-harness` and runs the Linux `install.sh` inside WSL.

## What it does (step by step)

1. **Embedded payload pre-check** — verifies the script carries the `#__HARNESS_PKG_EOF__`
   sentinel and embedded payload (fails fast if invoked as the unbuilt template).
2. **Precheck / self-elevate** — requires admin; relaunches itself elevated if launched
   without it.
3. **Probe WSL state** — checks the `Microsoft-Windows-Subsystem-Linux` + `VirtualMachinePlatform`
   optional features and whether the distro is already installed, then branches.
4. **Install WSL + the distro** — on a fresh machine, `wsl.exe --install -d <distro>` and
   registers an at-logon auto-resume scheduled task before the mandatory reboot.
5. **Reboot** — the single mandatory reboot finishes feature activation (see note).
6. **First-run user + systemd setup** — installs git/curl/python inside the distro, prompts
   for the Linux username/password/sudo choice (decoupled from Windows login), writes
   `[boot] systemd=true` + `[user] default=<user>` to `/etc/wsl.conf`, and restarts WSL.
7. **Self-extract the embedded payload** — decodes the embedded `base64(tar.gz)` with .NET,
   verifies its embedded SHA-256 checksum **before** extraction, and extracts the runtime
   tree into `$InstallTarget` (`$env:USERPROFILE\agent-harness`) via WSL `tar -xzf`
   (skipped if already extracted; `-Refresh` re-extracts).
8. **Run `install.sh`** — the embedded harness installer runs inside WSL from the extracted
   target with the flags documented below.
9. **Summary** — how to enter WSL, update, and uninstall.

## Reboot note (be honest)

A fresh Windows 10/11 machine needs **one** reboot mid-install, because enabling WSL2 requires
it. Before rebooting, the installer registers a logon auto-resume task (`agent-harness-wsl-install-resume`)
and writes a small state marker in your AppData folder (`wsl-install.state`), so after reboot
the **same self-extracting installer** resumes automatically (or you can re-run the same
command) — nothing is lost. The WSL feature probe returns **four** states, which map to
**three** user-facing outcomes:

- `Disabled` — fresh install: `wsl.exe --install` is run, a marker is written, auto-resume
  is registered, and the script exits asking you to reboot.
- `Enabled (Pending Reboot)` / `Disabled (Pending Reboot)` — the machine still needs a
  REBOOT for WSL to activate: the script tells you to reboot and re-run the one-liner (it
  does **not** re-run `wsl --install`, which is a no-op/help text once the feature exists).
- `Enabled` — WSL is usable; the script proceeds to install the distro (if needed) and the
  rest of the bootstrap (self-extract + `install.sh`) without a reboot.

> If the script asks for **another** reboot because an unrelated **Windows Update**
> pending-reboot coincides with the WSL install, simply reboot once more and re-run the
> same command — nothing is lost (the state marker persists).

## Requirements

- Windows 10/11 with WSL2 support.
- Administrator rights (the script self-elevates).
- Access to the private `weignerg/agent-harness` GitHub repo to download the self-extracting
  artifact `install-agent-harness-v0.7.6-windows10-11.ps1`.
- Internet access (to download the distro and, later, models).
- ~30 minutes for the first run (the model warmup pass is skipped by the bootstrap).
- An NVIDIA driver installed on the **Windows side**: GPU passthrough is automatic in WSL2
  (no `modprobe` / `udev` needed inside WSL) — the RTX 5090 is exposed via the Windows driver.

## What gets installed where

- **Windows side:** the self-extracted runtime tree in `$env:USERPROFILE\agent-harness`.
- **WSL (Linux) side:** harness state in the Linux home — `~/.config`, `~/.local`, `~/.orchestration`.
- The default WSL user is created with your chosen Linux username (decoupled from your
  Windows username), optional password, and optional passwordless sudo. Run `passwd <user>`
  inside WSL anytime to change the password.

## Troubleshooting

- **ExecutionPolicy / "cannot load because running scripts is disabled":** the TLDR uses
  `-ExecutionPolicy Bypass`, so this should not trigger; if you run the `.ps1` directly, use
  `powershell -ExecutionPolicy Bypass -File .\install-agent-harness-v0.7.6-windows10-11.ps1`.
- **"WSL needs a reboot" / `0x8007019e` / `0x80370102`:** reboot, then let auto-resume continue
  or re-run the same one-liner.
- **"Windows Subsystem for Linux has no installed distributions":** the script handles this
  (it installs the distro); if you hit it manually, run `wsl --install -d <distro>`.
- **Requested a second reboot:** if an unrelated Windows Update pending-reboot coincides
  with the WSL install, reboot once more and re-run the same command — nothing is lost.
- **"No embedded runtime payload found in this script":** you ran the raw template
  `windows/install-windows.ps1` from a git checkout instead of the built self-extracting
  artifact. Download `install-agent-harness-v0.7.6-windows10-11.ps1` from the release page
  or build it with `pwsh -NoProfile -File release-build/make_windows_installer.ps1`.
- **GPU not detected in WSL:** make sure the NVIDIA driver is installed on the Windows side
  (WSL2 auto-passthrough); no action is needed inside WSL.
- **systemd note:** the bootstrap writes `[boot] systemd=true` into `/etc/wsl.conf`
  (alongside `[user] default=<user>`) and issues `wsl --shutdown`, so WSL systemd is on
  by default. Supervised auto-start services therefore start on WSL's next launch — no
  manual `~/.wslconfig` edit is required. Because systemd is on, the bootstrap runs
  `install.sh` *without* `--no-healthcheck`, so the systemd user-service healthcheck
  runs and verifies supervised completion.

## Guided configuration wizard + T3 completion gate (Issue-#67)

When `install.sh` is run **interactively** (no `-y` / `--non-interactive`, with a
real terminal), after the backend services are up it opens a **guided configuration
wizard** and then a **human-confirmed T3 completion gate**. This is where the
`OPENCODE_SERVER_USERNAME` nuance the user hit is resolved.

The wizard walks through every runtime:

1. **OpenCode** — shows the probed primary model (`ornith-1.5-35b`, `qwen3.8-27b` or
   `ornith-9b`), how to pick a different profile (`--sglang-model …`), and model-weight
   status.
2. **Claude Code** — prompts you to confirm the MCP servers/agents installed.
3. **Antigravity (AGY) / T3 Code** — instructs you to mint a pairing token
   (`t3 pair` / `t3 pair --ttl 1h`) and point the provider at the local backend
   `http://<LAN_IP>:3773`. **The installer never auto-pairs or sends a prompt.**
4. **OpenCode server username vs. WSL auto-login** — the reconciliation below.

Then the **T3 completion gate** re-checks ports 4096 (OpenCode) and 3773 (T3) and asks
you to send one real T3 prompt and confirm it reported back as the Supreme Orchestrator.
On `y` it prints the success banner and appends a ready-to-launch snippet to
`~/.bashrc`. If you are not ready, answer `n` — the backend install still completes and
you can finish the gate later by re-running `./install.sh`.

> **The bootstrap (`install.sh … -y`) skips the wizard and gate** so the one-command
> install is non-blocking. The wizard/gate run only for interactive installs.

### The `OPENCODE_SERVER_USERNAME` ↔ WSL default-user cross-check

The OpenCode headless server authenticates as the account systemd starts it under. In
WSL that is the **auto-login** account declared by `wsl.conf` `[user] default=<user>`
(the account you land in when WSL starts). If `OPENCODE_SERVER_USERNAME` differs from
that account, remote clients (the T3 / Antigravity provider GUI, mobile app) can connect
to port 4096 but be rejected — the username they send does not match the server's
login.

- **Interactive install:** if a mismatch is detected, `install.sh` flags it and asks
  whether to reconcile `OPENCODE_SERVER_USERNAME` to the WSL auto-login account
  (recommended). Your choice is honored.
- **Non-interactive / dry-run:** the change is **not applied silently**. `install.sh`
  prints a strong warning telling you to set `OPENCODE_SERVER_USERNAME=<WSL-default-user>`
  in `~/.config/opencode-backends/env` (or re-run interactively) and to use that exact
  value as the `Username` in the T3 provider GUI.

If your Windows user (e.g. `JaneDoe`) differs from the Linux WSL user, this is the nuance
that matters: set the provider `Username` to the **WSL** account, not the Windows one.

## Update

Download the **new** release's self-extracting Windows artifact and run it with `-Refresh`:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-agent-harness-v0.7.6-windows10-11.ps1 -Refresh
```
`-Refresh` re-extracts the embedded runtime tree over the existing `$InstallTarget`
directory, then re-runs `install.sh`. (Because the repo is private, there is no `git fetch`
update path; the self-extracting artifact is the update medium.)

## Uninstall

- Remove the Windows checkout dir (`$env:USERPROFILE\agent-harness`).
- In WSL remove `~/.config/opencode*`, `~/.local/share/opencode-sglang-stack`, `~/.orchestration`.
- Optionally `wsl.exe --unregister <distro>` (deletes the distro and its data).

## Why `install.sh` runs with these flags

The bootstrap runs (inside WSL):
```bash
./install.sh --global --target all --with-backends --no-firewall --no-obsidian --skip-warmup -y
```
- `--no-firewall` — WSL has no ufw/iptables; avoids sudo noise.
- `--no-obsidian` — pacman/flatpak-only → no-op on Ubuntu.
- (healthcheck now enabled) — because `/etc/wsl.conf` sets `[boot] systemd=true`,
  `install.sh`'s systemd user-service healthcheck runs and verifies the supervised
  services, instead of being suppressed.
- `--skip-warmup` — avoids a long blocking model download in a one-command bootstrap (warm up later).
- `--global --target all --with-backends -y` — keeps the full harness + GPU backends.
