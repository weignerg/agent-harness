# Windows (WSL) — One-Command Install

Install `agent-harness` on Windows 11 using the Windows Subsystem for Linux (WSL2). This
guide covers the pinned **v0.7.1** bootstrap script `windows/install-windows.ps1`.

> **Private repo note:** `agent-harness` is a **private** repository, so there is no
> anonymous install URL. The release bundle (the assets published on the GitHub release
> page) is the install medium: the script extracts the pinned `v0.7.1` source from the
> bundle you download — there is no `git clone` / raw-download path anywhere.

## TL;DR

On Windows 11: download the v0.7.1 release assets into one folder, then run **ONE** command
there. It self-elevates, sets up WSL + Ubuntu, asks for the one mandatory reboot, then (same
command after reboot) extracts the pinned `v0.7.1` source from your downloaded bundle and
runs the Linux installer inside WSL.

1. **Download the bundle.** From the GitHub release page
   `https://github.com/weignerg/agent-harness/releases/tag/v0.7.1`, download ALL assets into
   ONE folder (e.g. `agent-harness-v0.7.1\`). With an authenticated `gh`:
   ```powershell
   gh release download v0.7.1 -D .\agent-harness-v0.7.1
   ```
2. **Run the one command.** From inside that folder:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1
   ```

That single command self-elevates, sets up WSL + Ubuntu, asks for the one mandatory reboot,
then (the same command after reboot) extracts the pinned `v0.7.1` source tarball from the
bundle and runs the Linux `install.sh` inside WSL.

## What it does (step by step)

1. **Precheck / self-elevate** — requires admin; relaunches itself elevated if launched
   without it.
2. **Probe WSL state** — checks the `Microsoft-Windows-Subsystem-Linux` + `VirtualMachinePlatform`
   optional features and whether Ubuntu is already installed, then branches.
3. **Install WSL + Ubuntu** — on a fresh machine, `wsl.exe --install -d Ubuntu` (which needs
   the mandatory reboot below).
4. **Reboot** — the single mandatory reboot finishes feature activation (see note).
5. **First-run user setup** — installs git/curl/python inside Ubuntu and creates a default WSL
   user (empty password + passwordless sudo) so WSL can auto-login.
6. **Extract pinned `v0.7.1` source** — from the LOCAL bundle's `agent-harness-v0.7.1-source.tar.gz`
   (no git clone — the repo is private), into the Windows-side checkout.
7. **Run `install.sh`** — the harness installer runs inside WSL with the flags documented below.
8. **Summary** — how to enter WSL, update, and uninstall.

## Reboot note (be honest)

A fresh Windows 11 machine needs **one** reboot mid-install, because enabling WSL2 requires
it. After that, the **same command** (run from the **same bundle folder**) resumes
automatically — nothing is lost. The script remembers it needs a reboot via a small state
marker in your AppData folder (`wsl-install.state`), so the re-run picks up where it left
off. Three states are handled:

- Feature `Disabled` — fresh install: `wsl.exe --install` is run, a marker is written, and the
  script exits asking you to reboot.
- Feature `Enabled (Pending Reboot)` — you are back but have not rebooted yet: the script tells
  you to reboot and re-run the one-liner (it does **not** re-run `wsl --install`, which is a
  no-op/help text once the feature exists).
- Feature `Enabled` — WSL is usable; the script proceeds to install the distro (if needed) and
  the rest of the bootstrap without a reboot.

## Requirements

- Windows 11 (22H2+).
- Administrator rights (the script self-elevates).
- Access to the private `weignerg/agent-harness` GitHub repo, to download the release assets.
- Internet access.
- ~30 minutes for the first run (the model warmup pass is skipped by the bootstrap).
- An NVIDIA driver installed on the **Windows side**: GPU passthrough is automatic in WSL2
  (no `modprobe` / `udev` needed inside WSL) — the RTX 5090 is exposed via the Windows driver.

## What gets installed where

- **Windows side:** the repo checkout at `$env:USERPROFILE\agent-harness`.
- **WSL (Linux) side:** harness state in the Linux home — `~/.config`, `~/.local`, `~/.orchestration`.
- The default WSL user is created with an **empty password** + passwordless sudo (personal-box
  convenience). Run `passwd <user>` inside WSL to set a real password if you want one.

## Troubleshooting

- **ExecutionPolicy / "cannot load because running scripts is disabled":** the TLDR uses
  `-ExecutionPolicy Bypass`, so this should not trigger; if you run the `.ps1` directly, use
  `powershell -ExecutionPolicy Bypass -File .\install-windows.ps1`.
- **"WSL needs a reboot" / `0x8007019e` / `0x80370102`:** reboot, then re-run the same one-liner.
- **"Windows Subsystem for Linux has no installed distributions":** the script handles this
  (it installs the distro); if you hit it manually, run `wsl --install -d Ubuntu`.
- **GPU not detected in WSL:** make sure the NVIDIA driver is installed on the Windows side
  (WSL2 auto-passthrough); no action is needed inside WSL.
- **systemd note:** supervised auto-start services require WSL systemd (opt-in, e.g.
  `init.systemd=true` in `~/.wslconfig` + `wsl --shutdown`). The bootstrap runs
  `install.sh --no-healthcheck` so it succeeds even with systemd off; to get supervised
  services, enable WSL systemd and re-run `./install.sh` in WSL.

## Update

Download the new release's assets into a **new** folder, then from that folder run:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1 -Refresh
```
`-Refresh` re-extracts the new pinned source over the existing `$InstallTarget` checkout, then
the installer re-runs. (Because the repo is private, there is no `git fetch` update path; the
release bundle is the update medium.)

## Uninstall

- Remove the Windows checkout dir (`$env:USERPROFILE\agent-harness`).
- In WSL remove `~/.config/opencode*`, `~/.local/share/opencode-sglang-stack`, `~/.orchestration`.
- Optionally `wsl.exe --unregister Ubuntu` (deletes the distro and its data).

## Why `install.sh` runs with these flags

The bootstrap runs (inside WSL):
```bash
./install.sh --global --target all --with-backends --no-firewall --no-obsidian --no-healthcheck --skip-warmup -y
```
- `--no-firewall` — WSL has no ufw/iptables; avoids sudo noise.
- `--no-obsidian` — pacman/flatpak-only → no-op on Ubuntu.
- `--no-healthcheck` — `install.sh` hard-exits when systemd user-services are not managed,
  which is the default on fresh WSL.
- `--skip-warmup` — avoids a long blocking model download in a one-command bootstrap (warm up later).
- `--global --target all --with-backends -y` — keeps the full harness + GPU backends.
