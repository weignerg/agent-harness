# Windows (WSL) — One-Command Install

Install `agent-harness` on Windows 11 using the Windows Subsystem for Linux (WSL2). This
guide covers the pinned **v0.7.1** bootstrap script `windows/install-windows.ps1`.

> **Private repo note:** `agent-harness` is a **private** repository, so there is no
> anonymous install URL. The release **source bundle** — the single artifact
> `agent-harness-v0.7.1-source.tar.gz` published on the GitHub release — is the install
> medium: the script copies that bundle to a canonical install target and runs the
> installer from it. There is no `git clone` / raw-download path anywhere.

## TL;DR

On Windows 11: download the v0.7.1 source bundle, extract it, then run **ONE** command from
inside the extracted tree. It self-elevates, sets up WSL + Ubuntu, asks for the one
mandatory reboot, then (same command after reboot, from the same extracted bundle) copies
the bundle to `$env:USERPROFILE\agent-harness` and runs the Linux installer inside WSL.

1. **Download the bundle.** From the GitHub release page
   `https://github.com/weignerg/agent-harness/releases/tag/v0.7.1`, download the single
   source bundle `agent-harness-v0.7.1-source.tar.gz`, then extract it (e.g.):
   ```powershell
   tar -xzf agent-harness-v0.7.1-source.tar.gz
   ```
   `tar.exe` is built into Windows 11; "Extract All" in Explorer works too. This produces a
   top-level folder `agent-harness-v0.7.1\`.
2. **Run the one command,** from inside that extracted folder:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\agent-harness-v0.7.1\windows\install-windows.ps1
   ```

That single command self-elevates, sets up WSL + Ubuntu, asks for the one mandatory reboot,
then (the same command after reboot, from the same extracted bundle) copies the bundle to
the canonical install target and runs the Linux `install.sh` inside WSL.

## What it does (step by step)

1. **Precheck / self-elevate** — requires admin; relaunches itself elevated if launched
   without it.
2. **Bundle-root check** — verifies the script is running from inside an extracted v0.7.1
   source bundle (the folder containing `install.sh`); it cannot be run from a loose
   standalone script.
3. **Probe WSL state** — checks the `Microsoft-Windows-Subsystem-Linux` + `VirtualMachinePlatform`
    optional features and whether the distro is already installed, then branches.
4. **Install WSL + the distro** — on a fresh machine, `wsl.exe --install -d <distro>`
    (which needs the mandatory reboot below).
5. **Reboot** — the single mandatory reboot finishes feature activation (see note).
6. **First-run user setup** — installs git/curl/python inside the distro and creates a
    default WSL user (empty password + passwordless sudo) so WSL can auto-login.
7. **Copy the bundle** — copies this source bundle to the canonical `$InstallTarget`
    (`$env:USERPROFILE\agent-harness`) on the Windows side (skipped if already present;
    `-Refresh` re-copies).
8. **Run `install.sh`** — the harness installer runs inside WSL from the copied target with
    the flags documented below.
9. **Summary** — how to enter WSL, update, and uninstall.

## Reboot note (be honest)

A fresh Windows 11 machine needs **one** reboot mid-install, because enabling WSL2 requires
it. After that, the **same command** (run from the **same extracted bundle**) resumes
automatically — nothing is lost. The script remembers it needs a reboot via a small state
marker in your AppData folder (`wsl-install.state`), so the re-run picks up where it left
off. The WSL feature probe returns **four** states, which map to **three** user-facing
outcomes:

- `Disabled` — fresh install: `wsl.exe --install` is run, a marker is written, and the
  script exits asking you to reboot.
- `Enabled (Pending Reboot)` / `Disabled (Pending Reboot)` — the machine still needs a
  REBOOT for WSL to activate: the script tells you to reboot and re-run the one-liner (it
  does **not** re-run `wsl --install`, which is a no-op/help text once the feature exists).
- `Enabled` — WSL is usable; the script proceeds to install the distro (if needed) and the
  rest of the bootstrap (copy + `install.sh`) without a reboot.

> If the script asks for **another** reboot because an unrelated **Windows Update**
> pending-reboot coincides with the WSL install, simply reboot once more and re-run the
> same command — nothing is lost (the state marker persists).

## Requirements

- Windows 11.
- Administrator rights (the script self-elevates).
- Access to the private `weignerg/agent-harness` GitHub repo, to download the release
  source bundle `agent-harness-v0.7.1-source.tar.gz`.
- Internet access (to download the distro and, later, models).
- ~30 minutes for the first run (the model warmup pass is skipped by the bootstrap).
- An NVIDIA driver installed on the **Windows side**: GPU passthrough is automatic in WSL2
  (no `modprobe` / `udev` needed inside WSL) — the RTX 5090 is exposed via the Windows driver.

## What gets installed where

- **Windows side:** the source bundle copied to `$env:USERPROFILE\agent-harness`.
- **WSL (Linux) side:** harness state in the Linux home — `~/.config`, `~/.local`, `~/.orchestration`.
- The default WSL user is created with an **empty password** + passwordless sudo (personal-box
  convenience). Run `passwd <user>` inside WSL to set a real password if you want one.

## Troubleshooting

- **ExecutionPolicy / "cannot load because running scripts is disabled":** the TLDR uses
  `-ExecutionPolicy Bypass`, so this should not trigger; if you run the `.ps1` directly, use
  `powershell -ExecutionPolicy Bypass -File .\agent-harness-v0.7.1\windows\install-windows.ps1`.
- **"WSL needs a reboot" / `0x8007019e` / `0x80370102`:** reboot, then re-run the same one-liner.
- **"Windows Subsystem for Linux has no installed distributions":** the script handles this
  (it installs the distro); if you hit it manually, run `wsl --install -d <distro>`.
- **Requested a second reboot:** if an unrelated Windows Update pending-reboot coincides
  with the WSL install, reboot once more and re-run the same command — nothing is lost.
- **I only downloaded the standalone `install-windows.ps1` asset (not the source bundle):**
  the script requires running from inside the extracted bundle. Download `agent-harness-v0.7.1-source.tar.gz`,
  extract it, and run **its** copy of `windows\install-windows.ps1`.
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

Re-download the **new** release's source bundle, extract it, then from the new extracted
folder run:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\agent-harness-v0.7.1\windows\install-windows.ps1 -Refresh
```
`-Refresh` re-copies the new bundle over the existing `$InstallTarget` checkout, then the
installer re-runs. (Because the repo is private, there is no `git fetch` update path; the
release source bundle is the update medium.)

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
