#!/usr/bin/env bash
# test-launcher-env.sh [--mutate] -- EXECUTES the four daemon launchers and checks the ENVIRONMENT each hands
# its agent process (NWP-20261016-32).
#
# WHY THIS IS COMMITTED. A launcher SOURCES the merged ring + device conf as shell variables and then exports a
# hand-picked subset; the agent reads os.Getenv, so a key that is set but not exported is silently inert. That
# exact defect shipped three times: ACTIVATION_JITTER_EPOCHS and NOWHERE_SYNC_INTERVAL ("DOCUMENTED as
# conf-settable and silently inert", NWP-20260822-24), NOWHERE_GATEWAY_DEFAULT (beta devices enrolled against
# PRODUCTION) and NOWHERE_SEQ_GUARD ("A flag is not shipped until something exports it"). conf_merge_test.go
# executes the merge's PRECEDENCE; nothing checked the EXPORT set. This does.
#
# HOW. Each launcher is copied into a temp root with its absolute paths rewritten (/system/etc/nowhere -> $T/sys,
# /data/ -> $T/data/, /sys/ -> $T/sysfs/, /system/bin/nowhere_agent -> a stub that writes `env` to a file), given
# a ring conf and a device conf that set every conf key to a distinct sentinel, and RUN under every shell found
# (sh, dash, mksh) from an EMPTY environment, so nothing is inherited that the launcher did not export itself:
#   login   : runs straight through to its `exec nowhere_agent login-daemon`.
#   roamd   : the rw lane with a `sealdelta` request -- a LOCAL op whose first act is `$AGENT sealdeltawalk`.
#   mediad  : a request for uid 10 -> its `exec nowhere_agent mediad`.
#   otad    : a request -> its `timeout 120 nowhere_agent ota-check`.
# The suite prints key NAMES only, never a dumped environment (the S3_* sentinels are fake, but the rule is the
# conf_merge rule: a conf can carry credentials and this output is quoted in tickets).
#
# THE TABLE below is the contract: per conf key, the launchers that MUST export it (because the agent process
# that launcher starts reads it), the ones that need not and why, and the reading symbol. It is derived from
# `git grep` of every os.Getenv of the key in core/agent and, for each, which PROCESS reaches the reader:
# login-daemon, the roamd worker (`push`, `restore`, ... invocations), mediad, otad. A conf key (nowhere.conf.example,
# rings/*.conf) that is not in the table FAILS the suite until someone decides where it is exported.
#
#   bash test-launcher-env.sh            # the cases
#   bash test-launcher-env.sh --mutate   # ... plus mutants that must each CONVICT the suite
set -uo pipefail

MUTATE=no
for a in "$@"; do case "$a" in --mutate) MUTATE=yes ;; *) echo "usage: $0 [--mutate]" >&2; exit 2 ;; esac; done

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
BIN="$HERE"
ETC="$HERE/../etc"
AGENT_SRC="$REPO/core/agent"

LAUNCHERS="login roamd mediad otad"

# KEY | MUST export (launchers) | the others need not because | the process that reads it, file:symbol
# Launchers: login = nowhere_login.sh (login-daemon), roamd = nowhere_roamd.sh (worker), mediad, otad.
# UNREAD in column 2 = no agent code reads the key at all (pinned, see check_unread).
TABLE='
S3_ENDPOINT|login roamd mediad otad||main.go:s3Init (every store read/write: all four start an agent that opens the store)
S3_REGION|login roamd mediad otad||main.go:s3Init
S3_BUCKET|login roamd mediad otad||main.go:s3Init
S3_ACCESS_KEY|login roamd mediad otad||main.go:s3Init, capMode
S3_SECRET_KEY|login roamd mediad otad||main.go:s3Init
GATEWAY_URL|login roamd mediad otad||main.go:capMode (cap mode is GATEWAY_URL set and S3_ACCESS_KEY empty; all four reach the store)
CATALOG_URL|login||login-daemon-only: catalog.go:catalogRefreshURL, reached from the REFRESH-CATALOG handler (main.go:9185)
INDEX_URL|login||login-daemon-only: index.go:indexRefreshURL, reached from the REFRESH-INDEX handler (main.go:9210)
STOREFRONT_URL|login||login-daemon-only: storefront.go:storefrontURL, served by the daemon (main.go:10617)
NOWHERE_GATEWAY_DEFAULT|login||login-daemon-only: main.go:handleSetStoreManaged, report_issue.go:issueGatewayURL (handleReportIssue)
NOWHERE_OS_AGREEMENT|login||login-daemon-only: os_agreement.go:osAgreementMode, served by GET-OS-AGREEMENT (main.go)
ACTIVATION_JITTER_EPOCHS|login||login-daemon-only: billing.go:jitterEpochs via recordPlan <- drainClaim <- handleClaim/handleCreateCode; no launcher runs wallet-claim
NOWHERE_SYNC_INTERVAL|login||login-daemon-only: main.go:syncIntervalGet (the daemon syncLoop and its handlers)
NOWHERE_MULTIDEVICE|login roamd mediad|otad restores the published os ref, not a profile head|multidevice.go:multiDeviceEnabled (headRef/headKey/putHead on the profile restore and seal paths)
NOWHERE_SEQ_GUARD|roamd|worker-only: login-daemon never runs pushProfile; nowhere_login.sh still exports it (harmless)|restore_receipt.go:seqGuardEnabled, called only from main.go:pushProfile (the `push` subcommand roamd runs)
NOWHERE_CARRY_ESSENTIAL|roamd|worker-only: pushProfile is reached only by the `push` subcommand (main.go:17172); the daemon never self-execs and calls no seal that reaches carryEssential/essIndexOn|main.go:carryEssential (pushProfile)
NOWHERE_CARRY_ESSENTIAL_MEDIA|roamd|worker-only: same trace as NOWHERE_CARRY_ESSENTIAL|media_carry.go:carryEssentialMedia, essIndexOn (pushProfile)
NOWHERE_MEDIA_AFTER_GATE|roamd mediad|login and otad never restore #media or run the lander|media_after_gate.go:mediaAfterGateOn (mediaRestorePlan in the restore roamd runs; startBgLander in mediad)
'

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
note() { echo "  $*"; }

table_keys() { printf '%s\n' "$TABLE" | awk -F'|' 'NF>=4 {print $1}'; }
table_must() { printf '%s\n' "$TABLE" | awk -F'|' -v k="$1" '$1==k {print $2}'; }

# Which keys the device conf (as opposed to the ring) carries in the fixture -- both layers are exercised.
DEVICE_KEYS=" S3_ENDPOINT S3_REGION S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY GATEWAY_URL NOWHERE_MULTIDEVICE NOWHERE_CARRY_ESSENTIAL NOWHERE_SYNC_INTERVAL "

sentinel() {  # sentinel <KEY>  -> the value the fixture gives it (distinct per key and per layer)
  local k="$1" low
  low=$(printf '%s' "$k" | tr 'A-Z' 'a-z')
  case "$DEVICE_KEYS" in *" $k "*) echo "sentinel-dev-$low" ;; *) echo "sentinel-ring-$low" ;; esac
}

# The conf-key census: every KEY the shipped confs set or document, read from a copy so a mutant can add one.
census() {  # census <confdir>
  { grep -hoE '^#?[A-Z][A-Z0-9_]*=' "$1/nowhere.conf.example" 2>/dev/null
    for f in "$1"/rings/*.conf; do grep -hoE '^[A-Z][A-Z0-9_]*=' "$f"; done
  } | tr -d '#=' | sort -u
}

# stage_launcher <srcdir> <name> <root> -> path of the rewritten copy
stage_launcher() {
  local src="$1" name="$2" root="$3" out
  out="$root/run/$name.sh"
  mkdir -p "$root/run"
  sed -e "s@/sys/@__SYSFS__/@g" \
      -e "s@/system/etc/nowhere@$root/sys@g" \
      -e "s@/system/bin/nowhere_agent@$root/stub/nowhere_agent@g" \
      -e "s@/data/@$root/data/@g" \
      -e "s@__SYSFS__@$root/sysfs@g" \
      "$src/nowhere_$name.sh" > "$out"
  echo "$out"
}

make_root() {  # make_root <root>
  local root="$1" k
  mkdir -p "$root/sys" "$root/sysfs/power" "$root/data/nowhere/state" "$root/stub" "$root/stubbin" "$root/dump"
  : > "$root/sys/nowhere.conf"; : > "$root/data/nowhere/nowhere.conf"
  for k in $(table_keys); do
    case "$DEVICE_KEYS" in
      *" $k "*) echo "$k=$(sentinel "$k")" >> "$root/data/nowhere/nowhere.conf" ;;
    esac
    echo "$k=$(sentinel "$k")" >> "$root/sys/nowhere.conf"   # the ring carries every key; the device conf overrides its own
  done
  # the agent stub: dump the environment where the suite can read it, exit clean
  printf '#!/bin/sh\nenv > "%s/dump/${NWL:-x}.env"\nexit 0\n' "$root" > "$root/stub/nowhere_agent"
  chmod +x "$root/stub/nowhere_agent"
  # Commands the launchers wait on or ask the platform for; stubbed so a run takes milliseconds.
  printf '#!/bin/sh\necho "default via 10.0.0.1 dev wlan0"\n' > "$root/stubbin/ip"
  printf '#!/bin/sh\nexit 0\n' > "$root/stubbin/sleep"
  printf '#!/bin/sh\nexit 0\n' > "$root/stubbin/update_engine_client"
  chmod +x "$root/stubbin/"*
}

# run_launcher <srcdir> <root> <launcher> <shell> -> 0 when the stub agent was reached; its env is in dump/
run_launcher() {
  local src="$1" root="$2" l="$3" sh="$4" script
  rm -f "$root/dump/$l.env"
  script=$(stage_launcher "$src" "$l" "$root")
  local st="$root/data/nowhere/state"
  case "$l" in
    roamd)  printf 'sealdelta\nx\nx\n10\n\n\n0\n' > "$st/roam.req" ;;
    mediad) printf 'x\nx\n10\n\n' > "$st/mediad.req" ;;
    otad)   printf 'check\n' > "$st/ota.req" ;;
  esac
  ( cd "$root" && env -i PATH="$root/stubbin:/usr/bin:/bin" NWL="$l" timeout 60 "$sh" "$script" >"$root/dump/$l.out" 2>&1 )
  [ -s "$root/dump/$l.env" ]
}

shells() {
  local s p
  for s in sh dash mksh; do p=$(command -v "$s" 2>/dev/null) && echo "$s=$p"; done
}

# check_all <srcdir> <confdir> : run every launcher under every shell and apply the table
check_all() {
  local src="$1" confdir="$2" root sp s p l k val want must seen
  local shellname shellpath
  for sp in $(shells); do
    shellname=${sp%%=*}; shellpath=${sp#*=}
    root=$(mktemp -d); make_root "$root"
    for l in $LAUNCHERS; do
      if ! run_launcher "$src" "$root" "$l" "$shellpath"; then
        fail "$l under $shellname never reached its agent exec (no environment was dumped) -- launcher run FAILED"
        continue
      fi
      for k in $(table_keys); do
        must=$(table_must "$k")
        case " $must " in *" $l "*) ;; *) continue ;; esac
        want="$k=$(sentinel "$k")"
        if ! grep -qxF -- "$want" "$root/dump/$l.env"; then
          fail "$l ($shellname) does not export $k with the conf's value, but the agent it starts reads it (see the table)"
        fi
      done
      # UNREAD keys (pinned): no launcher exports one, so the day one does, someone decides why.
      for k in $(table_keys); do
        [ "$(table_must "$k")" = UNREAD ] || continue
        if grep -q "^$k=" "$root/dump/$l.env"; then
          fail "$l ($shellname) now exports $k, which the table records as UNREAD -- update the table's reader and owners"
        fi
      done
    done
    rm -rf "$root"
  done
  # Completeness: every key the confs set or document has a recorded owner.
  seen=$(table_keys)
  for k in $(census "$confdir"); do
    case "
$seen
" in *"
$k
"*) ;; *) fail "conf key $k is set or documented by nowhere.conf.example / rings/*.conf but has NO line in the ownership table: decide which launcher exports it" ;; esac
  done
  # Every table key must still be a real conf key (a retired key's row must go with it).
  for k in $seen; do
    case "
$(census "$confdir")
" in *"
$k
"*) ;; *) fail "table key $k is in no conf file any more -- remove its row" ;; esac
  done
  # UNREAD keys: still read by no agent code.
  for k in $seen; do
    [ "$(table_must "$k")" = UNREAD ] || continue
    local hit
    hit=$(grep -l "\"$k\"" "$AGENT_SRC"/*.go 2>/dev/null | grep -v '_test.go$' || true)
    [ -z "$hit" ] || fail "$k is recorded UNREAD but the agent now names it in $(basename "$hit" | head -1) -- give it owners in the table"
  done
}

# ---- the cases (the real tree) ---------------------------------------------------------------------------------
if [ -z "$(shells)" ]; then echo "no POSIX shell found" >&2; exit 2; fi
echo "shells: $(shells | cut -d= -f1 | tr '\n' ' ')"
real=$(mktemp -d)
mkdir -p "$real/confs/rings"
cp "$ETC/nowhere.conf.example" "$real/confs/"; cp "$ETC"/rings/*.conf "$real/confs/rings/"
check_all "$BIN" "$real/confs"
rm -rf "$real"
if [ "$FAILS" -ne 0 ]; then echo "FAILED: $FAILS check(s)"; exit 1; fi
echo "PASS: every launcher exports every key the agent it starts reads, and every conf key has an owner"

[ "$MUTATE" = yes ] || exit 0

# ---- mutants: each must be CONVICTED ---------------------------------------------------------------------------
echo "--- mutants ---"
MFAIL=0
# mutate <label> <launcher|conf> <sed program> <expected fragment of the failure output>
mutate() {
  local label="$1" target="$2" prog="$3" expect="$4" d out before after
  d=$(mktemp -d)
  mkdir -p "$d/bin" "$d/confs/rings"
  cp "$BIN"/nowhere_{login,roamd,mediad,otad}.sh "$d/bin/"
  cp "$ETC/nowhere.conf.example" "$d/confs/"; cp "$ETC"/rings/*.conf "$d/confs/rings/"
  case "$target" in
    ringconf) before=$(cat "$d/confs/rings/beta.conf"); printf '%s\n' "$prog" >> "$d/confs/rings/beta.conf"; after=$(cat "$d/confs/rings/beta.conf") ;;
    *)        before=$(cat "$d/bin/nowhere_$target.sh"); sed -i -E "$prog" "$d/bin/nowhere_$target.sh"; after=$(cat "$d/bin/nowhere_$target.sh") ;;
  esac
  if [ "$before" = "$after" ]; then echo "  MUTANT DID NOT APPLY: $label"; MFAIL=$((MFAIL + 1)); rm -rf "$d"; return; fi
  out=$(FAILS=0; check_all "$d/bin" "$d/confs" 2>&1)
  case "$out" in
    *"$expect"*) echo "  convicted: $label" ;;
    *)           echo "  SURVIVED: $label (expected: $expect)"; MFAIL=$((MFAIL + 1)) ;;
  esac
  rm -rf "$d"
}

mutate 'login no longer exports NOWHERE_GATEWAY_DEFAULT' login \
  '/^  export NOWHERE_GATEWAY_DEFAULT$/d' 'login (sh) does not export NOWHERE_GATEWAY_DEFAULT'
mutate 'login no longer exports NOWHERE_OS_AGREEMENT' login \
  '/^  export NOWHERE_OS_AGREEMENT$/d' 'login (sh) does not export NOWHERE_OS_AGREEMENT'
mutate 'login drops the ACTIVATION_JITTER_EPOCHS export line' login \
  '/^\[ -n "\$\{ACTIVATION_JITTER_EPOCHS:-\}" \] && export ACTIVATION_JITTER_EPOCHS$/d' 'login (sh) does not export ACTIVATION_JITTER_EPOCHS'
mutate 'roamd no longer exports NOWHERE_SEQ_GUARD' roamd \
  '/^export NOWHERE_SEQ_GUARD=/d' 'roamd (sh) does not export NOWHERE_SEQ_GUARD'
mutate 'otad drops GATEWAY_URL from its export line' otad \
  's/ S3_SECRET_KEY GATEWAY_URL$/ S3_SECRET_KEY/' 'otad (sh) does not export GATEWAY_URL'
mutate 'a new conf key with no table line' ringconf \
  'NOWHERE_TEST_FLAG=1' 'conf key NOWHERE_TEST_FLAG'
mutate 'the retired OTA_RING key comes back to a ring conf' ringconf \
  'OTA_RING=beta' 'conf key OTA_RING'

if [ "$MFAIL" -ne 0 ]; then echo "FAILED: $MFAIL mutant(s) not convicted"; exit 1; fi
echo "PASS: all mutants convicted"
