#!/usr/bin/env bash
# test-ctap-hid.sh [--mutate] -- runs ctap_hid_test.go (NWP-20261023-01), the CTAPHID framing over a fake hidraw (a
# SOCK_SEQPACKET pair modelling usbhid's output path); --mutate re-runs it against ctap_hid.go with each load-bearing
# rule broken in turn, restoring the file on exit. Since NWP-20261113-09 that includes recv's budget against a KEEPALIVE
# or other-channel flood, every transport failure being a *hidLinkError, and no framing refusal being one. Each mutant must be CONVICTED by a real `--- FAIL`; one that fails to
# apply or to compile is a failure. The suite creates no files: the mutants are applied in place, with ctap_hid.go.orig
# restored by the EXIT trap.
set -uo pipefail
cd "$(dirname "$0")"
. ./suite-report.sh
F=ctap_hid.go
RUN=(go test -count=1 -run 'TestCtapHID_' -v .)

out=$("${RUN[@]}" 2>&1); rc=$?
report_plain_run "$rc" "$out" || exit 1
[ "${1:-}" = --mutate ] || exit 0

cp "$F" "$F.orig"
trap 'mv -f "$F.orig" "$F"' EXIT
fails=0
mut() { # mut <label> <regex pattern> <repl> [<pattern> <repl> ...]; every pattern must match exactly once
  local label=$1 res
  shift
  python3 - "$F" "$@" <<'PY' || { echo "  INERT     $label -- the mutation did not apply"; fails=$((fails+1)); return; }
import re,sys
p=sys.argv[1]; args=sys.argv[2:]
s=open(p).read()
for pat,rep in zip(args[0::2],args[1::2]):
    s,c=re.subn(pat,lambda m: rep,s,count=2,flags=re.S)
    if c!=1: sys.exit(1)
open(p,'w').write(s)
PY
  res=$("${RUN[@]}" 2>&1)
  if [[ "$res" == *$'\n--- FAIL'* || "$res" == '--- FAIL'* ]]; then echo "  convicted $label"
  elif [[ "$res" == *'build failed'* ]]; then echo "  BROKEN    $label -- the mutant did not compile"; grep -m3 -E '^#|\.go:[0-9]+' <<<"$res" | sed 's/^/            /'; fails=$((fails+1))
  else echo "  SURVIVED  $label"; fails=$((fails+1)); fi
  cp "$F.orig" "$F"
}
mut "M1 writeReport writes pkt alone" 'n, err := unix\.Write\(h\.fd, buf\)' 'n, err := unix.Write(h.fd, pkt)' 'if n != len\(buf\) \{\n\t\treturn &hidLinkError\{fmt\.Errorf\("short hidraw write: %d of %d bytes", n, len\(buf\)\)\}' $'if n != len(pkt) {\n\t\treturn &hidLinkError{fmt.Errorf("short hidraw write: %d of %d bytes", n, len(pkt))}'
mut "M2 send never advances SEQ" '\t\tseq\+\+\n\t\}\n\treturn nil' $'\t}\n\treturn nil'
mut "M3 KEEPALIVE taken as the answer" '\t\tif cmd == ctaphidKeepAlv \{\n\t\t\tcontinue // still working -> wait for the real answer\n\t\t\}\n' ''
mut "M4 init packet's channel unchecked" '\t\tif binary\.BigEndian\.Uint32\(pkt\[0:4\]\) != h\.cid \{\n\t\t\tcontinue // a stray report on another channel\n\t\t\}\n' ''
mut "M5 continuation SEQ unchecked" 'if int\(cont\[4\]\) != seq \{' 'if false && int(cont[4]) != seq {'
mut "M6 body not cut to BCNT" 'return cmd, buf\[:total\], nil' 'return cmd, buf, nil'
mut "M7 INIT nonce unchecked" 'if len\(resp\) < 17 \|\| !bytes\.Equal\(resp\[:8\], nonce\) \{' 'if len(resp) < 17 {'
mut "M8 BCNT unbounded" '\t\tif total > ctaphidMaxMsg \{\n.*?\n\t\t\}\n' ''
mut "M9 send size unbounded" '\tif len\(data\) > ctaphidMaxMsg \{\n.*?\n\t\}\n' ''
mut "M10 mid-message init skipped" 'if cont\[4\]&0x80 != 0 \{\n\t\t\t\treturn 0, nil, errors\.New\("CTAPHID: a new message began before the last one ended"\)' $'if cont[4]&0x80 != 0 {\n\t\t\t\tcontinue'
mut "M11 recv's budget removed" 'if deadline\.After\(end\) \{' 'if false && deadline.After(end) {'
mut "M12 continuation reads not given recv's deadline" 'cont, err := h\.readReport\(end\)' 'cont, err := h.readReport(time.Now().Add(ctaphidReportWait))'
mut "M13 the read timeout returned unwrapped" 'return nil, &hidLinkError\{errors\.New\(why\)\}' 'return nil, errors.New(why)'
mut "M14 a framing refusal wrapped as a link error" 'return 0, nil, (fmt\.Errorf\("CTAPHID continuation out of order: [^\n]*\))\n' 'return 0, nil, &hidLinkError{fmt.Errorf("CTAPHID continuation out of order: expected SEQ %d, received %d", seq, cont[4])}
'
[ "$fails" -eq 0 ] && echo "== all mutations convicted" || { echo "== $fails mutation(s) not convicted"; exit 1; }
