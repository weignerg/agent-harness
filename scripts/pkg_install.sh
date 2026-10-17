#!/usr/bin/env bash
# ==============================================================================
# scripts/pkg_install.sh - human-reviewed gatekeeper for pacman / AUR installs.
# Shows package info + dependencies, then requires an interactive human "yes"
# typed on a real terminal. Refuses to run without a TTY (agents/child
# processes) and never forwards --noconfirm. Rejection has no side effects.
# Usage: pkg_install.sh [--aur] <package>...
# ==============================================================================
set -uo pipefail
AUR=0; PKGS=()
for a in "$@"; do
    case "$a" in
        --aur) AUR=1 ;;
        -*) echo "❌ Flags are not accepted (got '$a'); only package names." >&2; exit 2 ;;
        *) [[ "$a" =~ ^[A-Za-z0-9@._+-]+$ ]] || { echo "❌ Invalid package name: $a" >&2; exit 2; }; PKGS+=("$a") ;;
    esac
done
[ "${#PKGS[@]}" -gt 0 ] || { echo "Usage: $0 [--aur] <package>..." >&2; exit 2; }

if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "❌ Refusing: human approval requires an interactive terminal (no TTY). Blind installs are blocked." >&2
    exit 3
fi

if [ "$AUR" = 1 ]; then
    HELPER=""; for h in paru yay; do command -v "$h" >/dev/null 2>&1 && { HELPER="$h"; break; }; done
    [ -n "$HELPER" ] || { echo "❌ No AUR helper (paru/yay) found." >&2; exit 4; }
fi

echo "=============================================================================="
echo "📦 PACKAGE INSTALL REVIEW: ${PKGS[*]}"
echo "=============================================================================="
for p in "${PKGS[@]}"; do
    echo "--- $p ---"
    if [ "$AUR" = 1 ]; then
        "$HELPER" -Si "$p" || { echo "❌ Not found in AUR: $p" >&2; exit 5; }
        echo "⚠️  AUR packages run arbitrary build scripts. Review the PKGBUILD: https://aur.archlinux.org/packages/$p"
    else
        pacman -Si "$p" || { echo "❌ Not found in repos: $p" >&2; exit 5; }
    fi
done
echo "⚠️  SECURITY: installing runs package install scripts as root and places prebuilt binaries on this system."
printf "Type 'yes' to approve installation of [%s]: " "${PKGS[*]}"
read -r ANSWER || ANSWER=""
if [ "$ANSWER" != "yes" ]; then
    echo "🛑 Rejected. Nothing was installed."
    exit 1
fi
if [ "$AUR" = 1 ]; then exec "$HELPER" -S -- "${PKGS[@]}"; else exec sudo pacman -S -- "${PKGS[@]}"; fi
