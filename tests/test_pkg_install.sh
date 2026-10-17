#!/usr/bin/env bash
# Tests scripts/pkg_install.sh with mock pacman/sudo; interactive cases use a pty.
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; P=0; F=0
pass(){ echo "  ✅ PASS: $1"; P=$((P+1)); }; fail(){ echo "  ❌ FAIL: $1"; F=$((F+1)); }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; mkdir "$T/bin"
cat > "$T/bin/pacman" <<EOF
#!/usr/bin/env bash
echo "pacman \$*" >> "$T/calls"; [ "\$1" = "-Si" ] && echo "Name : \$2" ; exit 0
EOF
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$T/bin/sudo"; chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"; S="$R/scripts/pkg_install.sh"
pty(){ python3 - "$1" "$2" <<'PY'
import pty,os,sys
inp=sys.argv[2].encode(); pid,fd=pty.fork()
if pid==0: os.execv("/bin/bash",["bash","-c",sys.argv[1]])
os.write(fd,inp)
try:
    while os.read(fd,1024): pass
except OSError: pass
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid,0)[1]))
PY
}
"$S" htop </dev/null >/dev/null 2>&1; [ $? -eq 3 ] && [ ! -e "$T/calls" ] && pass "non-interactive blocked, no pacman call" || fail "non-tty not blocked"
echo yes | "$S" htop >/dev/null 2>&1; [ $? -eq 3 ] && pass "piped 'yes' cannot bypass" || fail "pipe bypass"
"$S" --noconfirm htop >/dev/null 2>&1; [ $? -eq 2 ] && pass "flags rejected" || fail "flag accepted"
"$S" 'x;rm' >/dev/null 2>&1; [ $? -eq 2 ] && pass "invalid name rejected" || fail "bad name"
rm -f "$T/calls"; pty "$S htop" $'no\n'; [ $? -eq 1 ] && ! grep -q -- ' -S ' "$T/calls" && pass "rejection halts, no install" || fail "rejection"
rm -f "$T/calls"; pty "$S htop" $'yes\n'; [ $? -eq 0 ] && grep -q 'pacman -S -- htop' "$T/calls" && pass "approval installs" || fail "approval"
echo "RESULTS: $P passed, $F failed"; [ $F -eq 0 ]
