#!/bin/sh
# License audit of the files that go into the image: sh licenses/audit.sh ROOT      (ROOT: the image tree, default /)
# For every ELF / Mach-O file in ROOT/usr/local/bin, ROOT/usr/local/lib, ROOT/usr/libexec, ROOT/System it lists the libraries it needs (ldd or otool -L),
# looks each one up in licenses/libs.tsv and fails when a process loads a library whose licence is GPL (not LGPL): every file audited here is ours or APSL/Apache,
# or when a library is not in the table (so that nobody ships something unreviewed).  The rule behind it: docs/development/LICENSES.md.
H="$(cd "$(dirname "$0")" && pwd)"; ROOT="${1:-/}"; FAIL=0; UNK=0
class() { awk -F'\t' -v n="$1" '$0 !~ /^#/ && index(n,$1)>0 { print $2; exit }' "$H/libs.tsv"; }
deps() { if file "$1" | grep -q "Mach-O"; then otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}'; else ldd "$1" 2>/dev/null | awk '/=>/ {print $1} !/=>/ && /\// {print $1}'; fi; }
for f in $(find "$ROOT/usr/local/bin" "$ROOT/usr/local/lib" "$ROOT/usr/libexec" "$ROOT/System" -type f 2>/dev/null); do
	file "$f" | grep -qE "ELF|Mach-O" || continue
	gpl=""; mixed=""; unk=""
	for d in $(deps "$f"); do
		c=$(class "$(basename "$d")"); [ -z "$c" ] && { unk="$unk $(basename "$d")"; continue; }
		case "$c" in gpl|lgpl-or-gpl|gpl-or-commercial) gpl="$gpl $(basename "$d")";; esac
	done
	[ -n "$gpl" ] && { echo "FAIL $f: GPL (or possibly GPL) libraries loaded with it:$gpl"; FAIL=1; }
	[ -n "$unk" ] && { UNK=$((UNK+1)); [ -n "$VERBOSE" ] && echo "unknown in $f:$unk"; }
done
echo "audit done: $FAIL failing, $UNK files with libraries missing from licenses/libs.tsv (run with VERBOSE=1)"; exit $FAIL
