package main

// Billing client -- the device half of the managed-store gateway (Nowhere Phase 2). The gateway sells
// capacity as capability tokens and keeps data alive with per-ref leases; here the device holds the token
// wallet (which roams as ordinary encrypted state), computes owed rent from a profile's footprint, and
// redeems. Tokens are OPAQUE to the device: it stores and presents them; the gateway signs/verifies. The
// gateway URL comes from GATEWAY_URL (set from the store config, like the S3_* vars). Step 1 mints via a
// dev faucet -- real payment rails are a later slice. See the private nowhere-phone build plan.

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"nowhereagent/blindrsa"
)

const giB = 1 << 30

// billingEpochSeconds is the lease epoch length. It MIRRORS the gateway's own EpochSeconds so the Profile
// Storage view can render "Paid through <date>" with no gateway round-trip -- which means the two must
// change TOGETHER. If they ever disagree, every date this device prints is wrong by the ratio between
// them, silently, on the one screen whose job is explaining what the user paid for.
//
// DIA-20260808-12: ONE DAY. It was a week, which made the 4-epoch lease 28 days -- so "a month" was 28
// days and "a year" 336, the label and the unit disagreeing. And epochs are globally aligned (unix /
// epochSeconds) with coverage running to the END of the target epoch, so the term actually received varied
// by a whole epoch depending on when in it the purchase landed. A daily epoch makes that +-1 day.
const billingEpochSeconds = 86400

// Token mirrors the gateway's issued token on the wire; the device treats it as opaque.
type Token struct {
	Denom string `json:"denom"`
	Nonce string `json:"nonce"`
	Exp   int64  `json:"exp"`
	Sig   string `json:"sig"`
}

// BlindToken is a zero-knowledge storage token (the device half of the blind-issuance arc, P3b): the
// signed message "denom|nonce|exp" plus the unblinded RSA-PSS blind signature, both base64 (std). It is
// what the gateway issues unlinkably (POST /issue) and verifies at redeem (the blind_tokens field of
// /lease). Unlike a faucet Token, the gateway never saw this token at issuance, so it can't tie the
// redemption to the payment. The device treats it as opaque the same way -- it only stores + presents it.
type BlindToken struct {
	Msg string `json:"msg"`
	Sig string `json:"sig"`
}

// Wallet is the set of unspent tokens plus the epoch its lease is paid through. It roams as ordinary
// encrypted state -- sealed/restored under the profile's data key (see sealWallet/pullWalletStrict) -- so it
// survives the power-off wipe with no special on-device storage. PaidThrough lets payRent be idempotent
// within a lease window: called on every sync, it only redeems once the current epoch is no longer covered.
// BlindTokens are zero-knowledge credit (P3b); plain Tokens are dev-faucet credit. Both spend at /lease.
// PlanSpec is one purchase's size and term: what planPurchase prices and the lease declares as buy_gb and periods.
type PlanSpec struct {
	// ID is the purchase's random id (h60 #14, Wallet.PlanID): sealed with the wallet, NEVER sent to the gateway and
	// NEVER logged. It lets a merge tell two phones' purchases apart. A spec written before this build has none.
	ID      string `json:"id,omitempty"`
	GB      int    `json:"gb"`
	Periods int64  `json:"periods"`
	// Keep is the customer's answer at the upgrade, asked at redemption (NWP-20261031-10): true = keep each plan at
	// its own size, sent as plan_change "keep"; false = no keep answer. It rides with the purchase it was given for.
	Keep bool `json:"keep,omitempty"`
	// Convert is the other answer (h51 #5, NWP-20261125-12): true = put all the time on the bigger plan, sent as
	// plan_change "convert". Keep and Convert are never both true; neither (the question was not asked, or the entry
	// was written before this build) sends nothing.
	Convert bool `json:"convert,omitempty"`
}

type Wallet struct {
	Tokens      []Token      `json:"tokens"`
	BlindTokens []BlindToken `json:"blind_tokens,omitempty"`
	PaidThrough int64        `json:"paid_through"` // last epoch the profile's lease is paid through (0 = never leased)
	// Subscriptions were withdrawn (round 5), so sub_key, sub_epoch and vouchers are gone. A wallet written
	// by an older build still carries those keys on disk and still loads -- nothing here decodes strictly --
	// and they are dropped on the next write. That IS the forfeit: a voucher the wallet was still holding is
	// discarded rather than redeemed. Safe only because the refill loop that would have spun on it went too.
	//
	// FreeFullEpoch remembers the epoch a free-tier lease last came back 402 (quota exceeded), so the
	// seal path skips the doomed free attempt for the rest of that epoch and goes straight to the
	// entitled paid lease (#133). Self-heals at the next epoch.
	FreeFullEpoch int64 `json:"free_full_epoch,omitempty"`

	// What was BOUGHT, learned from the /issue reply at redeem time. Without this the device cannot ask
	// for the term it paid for: it sent no periods at all, the gateway defaulted to one 30-day window, and
	// an annual buyer received a twelfth of the coverage and the SHORT grace band. The token count cannot
	// substitute -- 120 tokens is 10 GB for twelve months or 40 GB for three.
	PlanPeriods int64 `json:"plan_periods,omitempty"` // 30-day periods bought; 0 = unknown -> ask for one
	PlanGB      int   `json:"plan_gb,omitempty"`      // plan size; DECLARED on /lease as buy_gb at activation
	PlanKeep    bool  `json:"plan_keep,omitempty"`    // the waiting purchase's plan-change choice; sent as plan_change "keep" on its lease
	PlanConvert bool  `json:"plan_convert,omitempty"` // the waiting purchase's convert answer (h51 #5); sent as plan_change "convert" on its lease
	// PlanID is the random id of the purchase in PlanGB/PlanPeriods (h60 #14): sealed with the wallet, NEVER sent to the
	// gateway and NEVER logged. A plan recorded before this build has none.
	PlanID string `json:"plan_id,omitempty"`
	// PlanQueue is the purchases redeemed while an earlier one had not activated, oldest first (NWP-20261031-07,
	// decided 2026-10-20: "a bigger plan starts at once ..." in docs/product-decisions.md). PlanGB/PlanPeriods stay
	// the purchase that activates NEXT (or the last one that did); each queued purchase is priced at its OWN size
	// and term, and planActivated promotes the next one when the first lands.
	PlanQueue []PlanSpec `json:"plan_queue,omitempty"`
	// AccountPlanGB is the ACCOUNT's live plan size as the gateway last reported it, and it is READ BY THE
	// STORAGE SCREEN ONLY. It is deliberately a second field rather than a correction applied to PlanGB
	// above, because PlanGB has a job that must not be disturbed: it is the PRICE of a purchase waiting to
	// activate (planPurchase demands PlanGB*PlanPeriods signatures). Writing an account figure into it
	// would strand money -- a 10 GB top-up bought while a 50 GB grant is live could then never be funded,
	// and the customer would hold signatures they can never spend. Splitting the two means the learned
	// number can only ever change pixels.
	AccountPlanGB int `json:"account_plan_gb,omitempty"`
	// AccountPlans is the account's plans in run order as the gateway last sent them (NWP-20261120-10, h48 #9),
	// READ BY THE STORAGE SCREEN ONLY, like AccountPlanGB above: it is never priced and never sent on a lease, so
	// it can only change pixels. GET-BILLING ships it as plans= (billingLine).
	AccountPlans []leasePlanStep `json:"account_plans,omitempty"`

	// ActivateAfter holds the plan back until this epoch -- a random offset of up to activationJitterEpochs,
	// rounded UP to the next shared batch day (planBatchEpochs, see activationHold), chosen when the plan was
	// recorded or a queued one promoted.
	//
	// Purely a privacy defence, and it defends the only axis that can be defended. Blinding severs the
	// CRYPTOGRAPHIC link between a purchase and a redemption; it does not sever the STATISTICAL one, and 11
	// of the 12 SKUs are unique by token count. Buying the only 1 TB annual plan on a Tuesday and redeeming
	// 12,000 tokens a minute later joins the storefront's identified record to the gateway's pseudonymous
	// one with no cryptography involved. Size cannot be faked without breaking the economics; WHEN we
	// redeem is free, because nothing about a term depends on the instant it starts.
	//
	// Overridden when data is actually at risk -- see planPurchase. Coverage beats anonymity.
	ActivateAfter int64 `json:"activate_after,omitempty"`

	// RenewedEpoch is when the whole footprint was last re-leased. It exists because PaidThrough cannot
	// serve as that marker: payRent suppresses itself while PaidThrough still covers the epoch, and
	// PaidThrough is now a whole TERM ahead (up to 360 days) rather than one 30-day period. So the only
	// lease that touches COLD refs would otherwise go quiet for a year while capFlush re-stamped nothing but
	// the delta -- and cold refs stamped by a FREE lease live only FreeTTL(90d) + grace(30d) from last
	// access. They would be swept while a live head still names them, and a partially reaped profile does
	// not restore with gaps: it cannot log in at all.
	RenewedEpoch int64 `json:"renewed_epoch,omitempty"`

	// DeadlineEpoch is when these refs become collectable (term end plus the plan's grace), cached from the
	// lease reply. There is deliberately no separate term-end field: PaidThrough already IS the epoch
	// coverage runs to, and now that the device asks for the whole term it means the term end rather than
	// the end of a 30-day slice. A second copy would only drift.
	//
	// It is STORED, never derived. The device cannot compute either honestly: `through` stacks off the
	// entitlement rather than starting at now, a re-lease re-stamps it so it drifts during ordinary use,
	// and a free lease can move it. Caching what the gateway actually wrote makes the date the phone shows
	// and the date the collector honours the same value by construction -- and keeps every grace constant
	// on the gateway, instead of adding a second copy here that has to be kept in step (the trap
	// billingEpochSeconds documents above).
	//
	// Zero means UNKNOWN, never "now" or "expired": a gateway that predates the field sends nothing, and
	// callers must show nothing rather than a date they made up.
	DeadlineEpoch int64 `json:"deadline_epoch,omitempty"`

	// PendingClaims is the claim codes nobody has redeemed yet, oldest first, deduplicated (NWP-20261125-05; decided
	// 2026-11-02, h53 #6 in docs/product-decisions.md: the claim code of a deferred drain waits in the profile's wallet,
	// sealed with it, and a later session on any phone drains it). Each is a PAID BEARER CODE: it is sealed with the
	// wallet and never logged -- every log line about one prints counts only. drainPendingClaims clears an entry only
	// once the gateway proves the code empty; walletForPublish and mergeLateRestore carry it, and the seen-set keys it
	// by its hash (pendingClaimSeenKey), so a code this session cleared is never brought back from a stored copy.
	//
	// keepPendingClaim (NWP-20261201-21) is the first writer: an Add-credits drain cut short keeps its code here. Slice 2's
	// drain caller, which runs drainPendingClaims at a later session, is not built yet. ⚠ A build older than this field
	// decodes the wallet non-strictly and drops pending_claims on its next write, so a writer must not ship before this
	// reader is in the field (the reader is in release 0.5.54; h56 #1 in docs/product-decisions.md).
	PendingClaims []string `json:"pending_claims,omitempty"`
}

func loadWallet(path string) (*Wallet, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &Wallet{}, nil
		}
		return nil, err
	}
	var w Wallet
	if err := json.Unmarshal(b, &w); err != nil {
		return nil, err
	}
	return &w, nil
}

// saveOurWallet is saveWallet for capFlush's three write-backs, with the question capFlush has to ask
// first: is this file this profile's to write? A bracket that runs without a login for (name, pass) --
// a credential change, a gate-side add-device -- is looking at a boot-lifetime tmpfs file that belongs to
// whoever last signed in, or to nobody. Writing our lease bookkeeping into THAT would corrupt a departed
// profile's wallet, and on the free arm it would CREATE one where the state dir had none, which is how a
// later flush comes to believe the profile has an empty wallet (NWP-20260915-17).
//
// NWP-20261010-04: and the same question asked once more at the moment of writing. gen is the generation the
// flush loaded under; a sign-in or a create that replaced the wallet since has bumped it, and the file is the
// arriving profile's (THE GENERATION, wallet_lock.go). The caller holds the wallet lock, and nothing slow sits
// between this check and the save.
func saveOurWallet(path string, w *Wallet, ours bool, gen string) {
	if !ours {
		return
	}
	if walletGeneration(path) != gen {
		fmt.Fprintf(os.Stderr, "  cap-flush: the wallet changed hands during this flush -- not saved (NWP-20261010-04)\n")
		return
	}
	check(saveWallet(path, w))
}

func saveWallet(path string, w *Wallet) error {
	b, err := json.Marshal(w)
	if err != nil {
		return err
	}
	// NWP-20261031-01: noted BEFORE the file lands, so a crash between the two leaves a token seen that is not held
	// (it is then never resurrected -- the safe side), never one held that is not seen.
	if err := noteWalletSeen(path, w); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// balance is total spendable credit: zero-knowledge (blind) tokens plus dev-faucet tokens.
func (w *Wallet) balance() int { return len(w.Tokens) + len(w.BlindTokens) }

// billingLine renders the Profile "Storage" view from the LOCAL wallet only -- no
// passphrase, no gateway round-trip, so it can't fail or hang on a tap. `credit` is GB-months of
// unspent capacity; `through` is the epoch the lease is paid through (0 = never leased); `epochsec`
// lets the UI turn `through` into a renewal date. "NONE" when there's no wallet / nothing leased
// yet (a throwaway, or a store profile that hasn't paid rent). GB-USED (the footprint) is a later
// increment -- it needs the store round-trip + the session's keys.
func billingLine(walletPath string) string {
	w, err := loadWallet(walletPath)
	// The subscription arm of this guard is gone with SubKey. What remains is the original meaning: nothing
	// bought and nothing leased is genuinely nothing to show.
	if err != nil || (w.balance() == 0 && w.PaidThrough == 0) {
		return "NONE\n"
	}
	// sub=0 IS EMITTED DELIBERATELY, AND ALWAYS, even though subscriptions no longer exist. It is a
	// compatibility shim for the chooser, not live state.
	//
	// This binary is a /system/bin daemon and can be hot-patched; the chooser is a priv-app that only lands
	// on a full flash. So NEW AGENT + OLD CHOOSER is a real, reachable state, and the old chooser treats a
	// MISSING sub= as UNKNOWN (-1), not as 0 -- deliberately, so that an agent predating the field could
	// never be read as the positive claim "nothing renews". Dropping the field would therefore silently
	// degrade that chooser twice over: `if (sub >= 0)` goes false, so the "Prepaid" line disappears
	// entirely, and `if (credit == 0 && sub == 0)` goes false, so "No credit left -- top up" never appears
	// again. Emitting a literal 0 instead renders exactly the right prepaid UI on both choosers.
	//
	// Removable once every device is on a chooser that ignores the field -- i.e. after the fleet flash, not
	// before it.
	// The new fields are emitted ONLY when known, and carry NO fallback value. That is deliberate and is
	// the opposite of how epochsec above behaves: epochsec has a documented weekly default because an
	// absent field there means a daemon old enough to predate it, and those really were weekly. There is
	// no equivalent truth for a deadline. An absent deadline means UNKNOWN, and the only honest response
	// to an unknown deletion date is to print nothing -- a made-up date on this screen is worse than a
	// blank one, because it is the one number the user would act on.
	line := fmt.Sprintf("OK credit=%d through=%d epochsec=%d sub=0",
		displayCredit(w, nowEpoch()), w.PaidThrough, billingEpochSeconds)
	if w.DeadlineEpoch > 0 {
		line += fmt.Sprintf(" deadline=%d", w.DeadlineEpoch)
	}
	if w.PlanPeriods > 0 {
		line += fmt.Sprintf(" periods=%d", w.PlanPeriods)
	}
	// NWP-20260907-03: the ACCOUNT's size, not this handset's memory of a purchase. The wire field is
	// unchanged, so no chooser needs to know: the number behind it just stopped being per-device state.
	if gb := planSizeForDisplay(w); gb > 0 {
		line += fmt.Sprintf(" plangb=%d", gb)
	}
	// NWP-20260918-08: SAY THAT A PURCHASE IS WAITING, because the screen otherwise shows a customer who
	// has just paid the same words as one who never bought anything.
	//
	// `through=0` means "never leased", and that is ALSO true for the whole activation-jitter window -- up
	// to two days in which planGB and planPeriods are already recorded and the signatures are still in
	// hand. The chooser rendered that as "Not leased yet" and said nothing about the plan, which is how
	// Chester met it minutes after buying and asked what had been broken.
	//
	// ⚠ THE CHOOSER CANNOT DERIVE THIS. planPending is "funded and not yet activated" and it reads the
	// token BALANCE (Wallet.planPending, billing.go); the wire's `credit=` is displayCredit, a different number
	// entirely. Inferring it from `through<=0 && plangb>0` would be a second copy of a predicate that must
	// move with this one -- the trap recordCoverage and billingEpochSeconds already document. So the
	// agent, which owns the wallet, answers the question.
	//
	// Emitted only when TRUE, like deadline= and periods= above: an absent field means "not pending", and
	// an older chooser ignores it and renders exactly as it does today.
	// NWP-20261120-10 (h48 #9): the plans in the order they run, so Storage can say that a 50 GB plan drops to
	// 10 GB on a date. Only the steps not yet ended, only when two or more remain, and never while a purchase is
	// waiting (planPending: the phone then holds a fact the gateway does not have yet). Otherwise nothing; an
	// older chooser ignores the key.
	if !w.planPending() {
		if steps := livePlanSteps(w.AccountPlans, nowEpoch()); len(steps) >= 2 {
			line += " plans=" + planStepsWire(steps)
		}
	}
	if w.planPending() {
		line += " pending=1"
	}
	// NWP-20261103-05 (Q147): SAY THAT THE PLAN IS STILL MOVING, from the phone's own record of the change
	// alone. The gateway's 0 for a cooled-down rebind stays indistinguishable from "nothing to move" (no wire
	// change), so the only thing the phone can know is that IT left a carry unsettled, and when. Emitted only
	// while that is known and the cooldown can still be running, and only for a profile with a plan in its
	// wallet; an older chooser ignores the key.
	if w.PaidThrough > 0 {
		if at, ok := planMovingAt(walletPath, planMovingNow()); ok {
			line += fmt.Sprintf(" moving=%d", at)
		}
	}
	return line + "\n"
}

// rebindCooldownEpochs is the gateway's per-grant rebind cooldown in epochs: a second rebind of a grant inside
// this many epochs of its last move is refused as 200 {"moved":0} (nowhere-cloud NWC-20260917-01, which chose 7
// epochs over 30 days; cited here, not re-derived). Mirror trap as billingEpochSeconds.
const rebindCooldownEpochs = 7

// planMovingNow is the clock the record's time and the notice's window read, a var so a test can pin it.
var planMovingNow = func() int64 { return time.Now().Unix() }

// planMovingPath is the marker beside the wallet in the state tmpfs: a decimal unix time and nothing else (no
// key, no ref, no name), removed by a settle, by removeWallet and by a landed sign-out's drop
// (dropWalletIfUnchanged), so it never outlives the session.
func planMovingPath(walletPath string) string { return walletPath + ".moving" }

// billPrevAtOf is the time stamped on the outstanding !bill-prev record, 0 when there is none or it predates the field.
func billPrevAtOf(idx map[string]scopeRec) int64 { return idx[scopeBillPrevKey].At }

// billMovingSince is the time to note beside the wallet for the record in idx, read under cur, the profile's current
// key: billPrevAtOf, or 0 when the record names only cur. A change to the same passphrase records cur itself as
// !bill-prev, a record that moves nothing and never settles (rebindPlanReporting refuses old == new), so noting it
// would say moving= for the whole window while the plan never left the key. A !bill-mid key can still hold a grant.
func billMovingSince(idx map[string]scopeRec, cur string) int64 {
	if billPrevOf(idx) == cur && len(billMidOf(idx)) == 0 {
		return 0
	}
	return billPrevAtOf(idx)
}

// The marker is not the wallet, so these take no wallet lock: it is one small file whose reader tolerates any
// content (planMovingAt), and the parameter is named `wallet` so the wallet-writer guard (NWP-20261010-04) does not
// mistake it for a write of wallet.json.
// notePlanMoving records that a carry is unsettled since at. An untimed record (at <= 0) says nothing, so it
// removes the marker. Best effort: a failed write costs the notice, never a rotation or a sign-in.
func notePlanMoving(wallet string, at int64) {
	if at <= 0 {
		clearPlanMoving(wallet)
		return
	}
	if !filepath.IsAbs(wallet) {
		return // capWalletPath's bare "wallet.json" fallback (CLI, tests) names no session state dir: write nothing into the cwd
	}
	if err := os.WriteFile(planMovingPath(wallet), []byte(strconv.FormatInt(at, 10)), 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "[agent] plan moving: marker not written (%v)\n", err)
	}
}

func clearPlanMoving(wallet string) { os.Remove(planMovingPath(wallet)) }

// planMovingAt reads the marker: ok only for a positive time that now has not passed by the cooldown plus one
// epoch (epochs are unix/86400 and a move covers to the END of its epoch).
func planMovingAt(walletPath string, now int64) (int64, bool) {
	b, err := os.ReadFile(planMovingPath(walletPath))
	if err != nil {
		return 0, false
	}
	at, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil || at <= 0 {
		return 0, false
	}
	if now >= at+rebindCooldownEpochs*billingEpochSeconds+billingEpochSeconds {
		return 0, false
	}
	return at, true
}

// epochsPerPeriod mirrors the gateway's EpochsPerLease. Same mirror trap as billingEpochSeconds above:
// two copies of a number that must move together, and only one of them gets updated. It is here because
// billingLine renders offline, with no quote in hand.
const epochsPerPeriod = 30

// displayCredit is what `credit=` reports, and it is NOT the token balance any more.
//
// A COMPATIBILITY SHIM, and it must outlive the fleet flash. Once a plan is bought outright the wallet is
// empty by design, and chooser v44 renders `credit == 0` as "No credit left -- top up to keep more than the
// free allowance" -- shown to someone who just bought twelve months. So while a term is live this reports
// the plan's REMAINING GB-months, which is the same unit v44 already prints and degrades honestly on it.
// v45 reads plangb/through/deadline directly and ignores this.
//
// With no live term it falls back to the real balance: an unactivated plan genuinely is spendable credit,
// and a profile that never bought anything genuinely has none.
//
// NWP-20260907-06: SIZED BY planSizeForDisplay, THE SAME ACCESSOR THE HEADLINE USES. It read w.PlanGB --
// this handset’s memory of a purchase -- while `plangb=` on the very same line had just been moved to the
// ACCOUNT’s size. Device-proven split, lynx 2026-09-07: one GET-BILLING line read
// `credit=60 ... plangb=50`, where 60 is 10 GB x 6 remaining periods off the stale local figure and 50 is
// what the account actually holds. Nothing on screen was wrong, because the fielded chooser deliberately
// ignores `credit=` (see formatBilling) -- which is exactly why it would have sat there: two numbers on one
// line, from two different sources, with no reader to complain. The next reader of `credit=` would have
// inherited a figure priced at whatever plan this particular handset last bought.
//
// It also fixes a case the old expression could not express at all: a second handset that has only ever
// LEARNED the plan (AccountPlanGB set, PlanGB never written here, because recordPlan runs only where the
// claim was redeemed) failed `w.PlanGB <= 0` and reported its raw balance -- zero -- for a live paid term.
func displayCredit(w *Wallet, nowEp int64) int {
	gb := planSizeForDisplay(w)
	if gb <= 0 || w.PaidThrough <= nowEp {
		return w.balance()
	}
	left := w.PaidThrough - nowEp
	periods := left / epochsPerPeriod
	if left%epochsPerPeriod != 0 {
		periods++ // a part-period is still coverage the customer holds; rounding it away reads as a loss
	}
	return gb * int(periods)
}

// take removes and returns the first n tokens; ok=false (and no mutation) if fewer than n are held.
func (w *Wallet) take(n int) ([]Token, bool) {
	if len(w.Tokens) < n {
		return nil, false
	}
	out := append([]Token(nil), w.Tokens[:n]...)
	w.Tokens = append([]Token(nil), w.Tokens[n:]...)
	return out, true
}

// takeBlind removes and returns the first n zero-knowledge tokens; ok=false (no mutation) if fewer held.
func (w *Wallet) takeBlind(n int) ([]BlindToken, bool) {
	if len(w.BlindTokens) < n {
		return nil, false
	}
	out := append([]BlindToken(nil), w.BlindTokens[:n]...)
	w.BlindTokens = append([]BlindToken(nil), w.BlindTokens[n:]...)
	return out, true
}

// choosePayment removes up to `owed` tokens from the wallet to present at a lease, PREFERRING
// zero-knowledge (blind) tokens and topping up from plain faucet tokens only if blind credit runs short.
// ok=false (wallet partially drained but unsaved by the caller) if total credit < owed. The returned
// slices are presented as the lease's plain `tokens` and `blind_tokens`; settlePayment reconciles the
// wallet afterward against how many the gateway actually charged.
func (w *Wallet) choosePayment(owed int) (plain []Token, blind []BlindToken, ok bool) {
	nBlind := owed
	if nBlind > len(w.BlindTokens) {
		nBlind = len(w.BlindTokens)
	}
	blind, _ = w.takeBlind(nBlind)
	plain, ok = w.take(owed - nBlind)
	return plain, blind, ok
}

// isSpentNonce reports whether s is a value spentNamed accepts as a nonce: 1 to 64 characters of the base64url
// alphabet. Anything else is not a nonce this client ever minted or was issued.
func isSpentNonce(s string) bool {
	if len(s) < 1 || len(s) > 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// spentNamed decodes the `spent` list of a /lease 409 body (NWP-20261020-03). A body that is empty, not JSON, has
// no list or has a list of the wrong type yields nil; within a list a value that is not a string, or not an
// isSpentNonce, is dropped. It never logs a value.
func spentNamed(body []byte) []string {
	if len(body) == 0 {
		return nil
	}
	var o struct {
		Spent json.RawMessage `json:"spent"`
	}
	if json.Unmarshal(body, &o) != nil || len(o.Spent) == 0 {
		return nil
	}
	var elems []json.RawMessage
	if json.Unmarshal(o.Spent, &elems) != nil {
		return nil
	}
	var out []string
	for _, e := range elems {
		var s string
		if json.Unmarshal(e, &s) == nil && isSpentNonce(s) {
			out = append(out, s)
		}
	}
	return out
}

// dropNamedSpent removes from the PRESENTED tokens those whose nonce the gateway named as already spent
// (NWP-20261020-03): a plain token by Token.Nonce, a blind token by field 2 of its base64 Msg (`denom|nonce|exp`).
// Only presented tokens are judged, so a name that was not presented matches nothing; an undecodable or
// misshapen Msg is kept; a token is counted once however often its nonce is repeated. The result never aliases
// the inputs.
func dropNamedSpent(plain []Token, blind []BlindToken, spent []string) (keepPlain []Token, keepBlind []BlindToken, dropped int) {
	set := make(map[string]bool, len(spent))
	for _, n := range spent {
		set[n] = true
	}
	for _, t := range plain {
		if set[t.Nonce] {
			dropped++
			continue
		}
		keepPlain = append(keepPlain, t)
	}
	for _, b := range blind {
		if m, err := base64.StdEncoding.DecodeString(b.Msg); err == nil {
			if parts := strings.Split(string(m), "|"); len(parts) == 3 && set[parts[1]] {
				dropped++
				continue
			}
		}
		keepBlind = append(keepBlind, b)
	}
	return keepPlain, keepBlind, dropped
}

// settlePayment returns the tokens the gateway did NOT charge (a delta lease may spend fewer than were
// presented) to the wallet. The gateway collects nonces plain-first, then blind, so the first `spent` of
// (plain ++ blind) are gone; the rest go back, in order. `spent` is clamped to [0, len(plain)+len(blind)].
// Mutates the wallet in place.
//
// ⚠ THIS MIRRORS THE GATEWAY'S ORDER, AND THE TWO MUST MOVE TOGETHER: nowhere-cloud
// internal/gateway/gateway.go, handleLease's legacy loop (req.Tokens, then req.BlindTokens) and
// collectTokens, both plain then blind. choosePayment TAKES blind first from the wallet, but the gateway
// CHARGES plain first, so a mixed presentation gets its blind tail back. If either side changes the order
// alone, this returns spent nonces and burns unspent tokens: bearer credit nobody can re-issue.
//
// The one known limit: the gateway SKIPS a token that fails Verify (a wrong denom, a repeated nonce, an
// expired blind token). With such a token among the presented ones, the charged set is not a prefix, and
// this positional rule can hand back a spent nonce. On the profile arms the next lease's 409 names it and
// dropNamedSpent retires it (leaseRefsLocked's and capFlush's 409 arms, NWP-20261020-03). The profile-less
// legacy arm (throwaways) retires nothing on a 409.
//
// Pinned by identity in settle_payment_test.go and test-settle-payment.sh (NWP-20261128-27).
func (w *Wallet) settlePayment(plain []Token, blind []BlindToken, spent int) {
	if spent < 0 {
		spent = 0
	}
	plainSpent := spent
	if plainSpent > len(plain) {
		plainSpent = len(plain)
	}
	blindSpent := spent - plainSpent
	if blindSpent > len(blind) {
		blindSpent = len(blind)
	}
	w.Tokens = append(w.Tokens, plain[plainSpent:]...)
	w.BlindTokens = append(w.BlindTokens, blind[blindSpent:]...)
}

// ---- gateway HTTP client ----

type gatewayClient struct {
	base string
	hc   *http.Client
}

// Gateway call budgets. NWP-20260905-02: the deadline used to be a single 30s baked into the constructor,
// which meant one number covered a per-chunk /cap on the restore path and a whole-footprint /lease -- and
// the two call sites that already knew better mutated hc.Timeout AFTER construction, where it is easy to
// miss and easy to forget. The constructor now REQUIRES a budget, so the compiler asks every new call site
// the question, and the two overrides are ordinary arguments.
//
// ⚠ THESE VALUES ARE DELIBERATELY NOT DERIVED FROM MEASUREMENT, BECAUSE THERE IS NONE. Nothing on either
// side has ever recorded what a /lease costs (nowhere-cloud NWC-20260905-03 adds that), and two independent
// attempts to size one from assumed link speeds disagreed by 50%. So every value here is either the number
// that was already in the tree or the reviewed number from an existing sibling site. Do not invent a
// size-derived /lease deadline until the gateway's refs/dur data exists.
const (
	// gwDefault is what every seal, restore, claim and report path had before this change, kept verbatim.
	// It is NOT a considered value for /lease -- see the warning above.
	gwDefault = 30 * time.Second
	// gwUI bounds a round-trip a person is watching, where being wrong costs a banner rather than data.
	// Reviewed reasoning, moved here from its call site: "a UI round-trip, not a transfer -- fail fast if
	// unreachable".
	gwUI = 10 * time.Second
	// gwProbe bounds a check whose failure is FAIL-OPEN, so waiting is pure cost. Reviewed reasoning, moved
	// here from its call site: "bound the pre-fetch check; a slow/hung gateway fail-opens fast (not 30s)".
	gwProbe = 4 * time.Second
	// NWP-20260909-02: /lease is the ONE gateway call whose cost SCALES with the profile -- it carries one
	// entry per ref and the gateway writes a lease row for each. A flat gwDefault turned a freshly imported
	// profile into a PERMANENT WEDGE on lynx 2026-09-09: 15 large leases, EVERY ONE COMPLETED server-side,
	// every one between 30.126s and 34.840s, and every one abandoned by this client at 30.000s. The closest
	// miss was 126ms and it cost a 1.99 GB re-upload -- 6 of them, ~12 GB, all discarded -- with the seal
	// retrying every 120s forever and logoff impossible.
	//
	// THE WARNING ABOVE SAYS NOT TO INVENT A SIZE-DERIVED DEADLINE UNTIL THE GATEWAY'S refs/dur DATA EXISTS.
	// IT EXISTS NOW: NWC-20260905-03 shipped, and its `lease ... refs=N dur=Nms` lines are where the numbers
	// above were read from -- 2.60-2.83 ms per ref across 15 samples on a real profile. So this is the one
	// value here that IS derived from measurement, which is the whole difference the warning was drawing.
	//
	// gwLeasePerRef is ~3.5x the measured worst case because the two failure directions are not symmetric:
	// too long costs a slow failure against a gateway that is already down, too short costs an
	// UNRECOVERABLE profile. gwLeaseMax bounds the wait so an unreachable gateway still fails -- at the
	// measured rate it covers ~106k refs, and beyond that the answer is to stop sending every ref in one
	// request (batching), not a bigger number here.
	gwLeasePerRef = 10 * time.Millisecond
	gwLeaseMax    = 5 * time.Minute
)

// leaseBudget sizes a /lease deadline for a ref set of n. Never shorter than gwDefault, so a small lease
// behaves exactly as it did before this existed; capped at gwLeaseMax so an unreachable gateway still fails.
func leaseBudget(n int) time.Duration {
	if n < 0 {
		n = 0
	}
	d := gwDefault + time.Duration(n)*gwLeasePerRef
	if d > gwLeaseMax {
		return gwLeaseMax
	}
	return d
}

func newGatewayClient(base string, timeout time.Duration) *gatewayClient {
	return &gatewayClient{base: strings.TrimRight(base, "/"), hc: &http.Client{Timeout: timeout}}
}

// leaseClient is the client a /lease of this size should go out on: g's own when its budget already covers
// the lease, else one with a deadline sized to the ref count, SHARING g's transport so it reuses the same
// connections and pool rather than opening its own.
//
// It deliberately does NOT mutate g.hc.Timeout. NWP-20260905-02 moved this file off exactly that pattern --
// "the two call sites that already knew better mutated hc.Timeout AFTER construction, where it is easy to
// miss and easy to forget" -- and a mutated shared client would leak the long lease deadline onto every
// later call made through it, including the per-chunk /cap calls that are supposed to fail fast.
func (g *gatewayClient) leaseClient(refs int) *http.Client {
	d := leaseBudget(refs)
	if g.hc.Timeout == 0 || g.hc.Timeout >= d {
		return g.hc
	}
	return &http.Client{Timeout: d, Transport: g.hc.Transport}
}

type quoteInfo struct {
	Denom          string `json:"denom"`
	GBPerToken     int64  `json:"gb_per_token"`
	EpochSeconds   int64  `json:"epoch_seconds"`
	EpochsPerLease int64  `json:"epochs_per_lease"`
	PriceCents     int64  `json:"price_cents_per_gb_month"`
	CurrentEpoch   int64  `json:"current_epoch"`
	IssuerPubKey   string `json:"issuer_pubkey"`
	FreeGB         int64  `json:"free_gb"` // free-tier quota per profile (GB); 0 = free path off
}

func (g *gatewayClient) getJSON(path string, out any) error {
	resp, err := g.hc.Get(g.base + path)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("gateway %s: %s", path, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// postJSON is postJSONReason for the callers that branch on the status alone (entitlement, buyFaucet, issue,
// readCaps). The refusal text is read and dropped here; the lease calls, whose 402 is the one the user ends up
// reading, and the issue reporter's /support, whose 503 means two things, go through postJSONReason to keep it.
func (g *gatewayClient) postJSON(path string, in, out any) (int, error) {
	code, _, err := g.postJSONReason(path, in, out)
	return code, err
}

// gatewayReasonMax bounds the refusal text kept from a non-2xx gateway reply (bytes, after sanitising).
const gatewayReasonMax = 200

// gatewayReasonRead bounds how much of a non-2xx body is read at all before the connection is closed. The
// gateway's own bodies are one short JSON line; anything longer is not ours and is not worth the RAM.
const gatewayReasonRead = 4096

// leaseConflictRead is how much of a /lease 409's body is read when the request presented `presented` tokens
// (NWP-20261020-03). The gateway's `spent` list names only nonces THIS request presented and it verified, so it
// holds at most `presented` entries. A nonce is 22 characters (plain) or 16 (blind) and costs its length plus
// 3 bytes of JSON (two quotes and a comma), at most 25 bytes; 64 per token is more than twice that. The 4096
// that bounds every refusal covers the error text and the framing. A 1 TB annual plan presents about 12,000
// tokens, so the worst case is about 772 KB, read once and only on a 409.
func leaseConflictRead(presented int) int { return gatewayReasonRead + 64*presented }

// postJSONReason POSTs in, decodes out on 200, and on ANY non-2xx returns the gateway's refusal text --
// bounded and sanitised by gatewayReason -- instead of closing the body unread (NWP-20260904-09). The gateway
// sends a distinct message per refusal (`insufficient valid tokens`, `free quota exceeded`, `no live lease for
// ref`), and before this every one of them reached the device as the same bare 402: the issue reporter, the
// only diagnostic channel on a user build, could not say which refusal a profile hit. The reason is server
// text, never user data, and the sanitiser is what keeps a gateway from using it as a channel into the report.
func (g *gatewayClient) postJSONReason(path string, in, out any) (int, string, error) {
	return g.postJSONReasonOn(g.hc, path, in, out)
}

// postJSONReasonOn is postJSONReason on a caller-chosen client, so /lease can carry a deadline sized to its
// ref count (leaseClient) without changing the deadline of anything else that goes through g.
func (g *gatewayClient) postJSONReasonOn(hc *http.Client, path string, in, out any) (int, string, error) {
	code, reason, _, err := g.postJSONRefusalOn(hc, path, in, out, 0)
	return code, reason, err
}

// postJSONRefusalOn is postJSONReasonOn that, on a 409 only, reads up to conflictRead bytes and hands the body
// back (NWP-20261020-03). The reason is still gatewayReason over the first gatewayReasonRead bytes, so the longer
// read cannot change it. conflict is nil for every other status, when conflictRead is no larger than
// gatewayReasonRead, and when the body ran past conflictRead: a truncated list cannot be trusted.
func (g *gatewayClient) postJSONRefusalOn(hc *http.Client, path string, in, out any, conflictRead int) (int, string, []byte, error) {
	b, _ := json.Marshal(in)
	resp, err := hc.Post(g.base+path, "application/json", bytes.NewReader(b))
	if err != nil {
		return 0, "", nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		if resp.StatusCode != http.StatusConflict || conflictRead <= gatewayReasonRead {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, gatewayReasonRead))
			return resp.StatusCode, gatewayReason(body), nil, nil
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, int64(conflictRead)+1))
		head := body
		if len(head) > gatewayReasonRead {
			head = head[:gatewayReasonRead]
		}
		if len(body) > conflictRead {
			body = nil
		}
		return resp.StatusCode, gatewayReason(head), body, nil
	}
	if out != nil && resp.StatusCode == http.StatusOK {
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
			return resp.StatusCode, "", nil, err
		}
	}
	return resp.StatusCode, "", nil, nil
}

// gatewayReason turns a non-2xx gateway body into the short line that may be logged and shown. The gateway
// writes `{"error":"<msg>"}` (httpErr in nowhere-cloud); that message is unwrapped, and a body that is not
// that shape is taken verbatim, so a proxy's plain-text 502 still says something. Then it is made SAFE for the
// two places it lands: at most gatewayReasonMax bytes; printable ASCII only, every other byte (control bytes,
// newlines, UTF-8) replaced by '?'; and no double quote, mapped to a single quote -- the issue reporter's log
// scrubber treats every quoted token in a log line as a profile name and redacts it (reIssueQuotedTok,
// DIA-20260807-14), so a quoted reason would arrive as "<name>", and a stray quote inside one could swallow
// the rest of the line the same way. Bounded, single-line and quote-free, the text cannot forge a log line, a
// name shape, or a JSON field on its way into the report; the scrubber still runs over it like any other line.
func gatewayReason(body []byte) string {
	var je struct {
		Error string `json:"error"`
	}
	msg := strings.TrimSpace(string(body))
	if err := json.Unmarshal(body, &je); err == nil && strings.TrimSpace(je.Error) != "" {
		msg = strings.TrimSpace(je.Error)
	}
	out := make([]byte, 0, len(msg))
	for i := 0; i < len(msg) && len(out) < gatewayReasonMax; i++ {
		c := msg[i]
		switch {
		case c == '"':
			out = append(out, '\'')
		case c < 0x20 || c > 0x7e:
			out = append(out, '?')
		default:
			out = append(out, c)
		}
	}
	return string(out)
}

func (g *gatewayClient) quote() (quoteInfo, error) {
	var q quoteInfo
	err := g.getJSON("/quote", &q)
	return q, err
}

// entitlementInfo mirrors the gateway's POST /entitlement reply: this profile's storage coverage, in bytes.
type entitlementInfo struct {
	FreeBytes     int64 `json:"free_bytes"`
	EntitledBytes int64 `json:"entitled_bytes"` // LIVE purchased capacity (0 if the window lapsed)
	// CoveredBytes is the gateway's own admission ceiling -- max(free, entitled), NOT their sum. Absent
	// (0) from a gateway that predates it; coverage() falls back to max, never to the additive form.
	CoveredBytes int64 `json:"covered_bytes,omitempty"`
	UsedBytes    int64 `json:"used_bytes"` // gateway's view: bytes currently leased for the profile
	CurrentEpoch int64 `json:"current_epoch"`
	EpochSeconds int64 `json:"epoch_seconds"`
	GBPerToken   int64 `json:"gb_per_token"`
	// through_epoch is intentionally omitted (the gateway no longer returns it -- least-knowledge).
}

// entitlement reads the profile's storage coverage from the gateway (Phase 5). The profileRef rides in the POST
// body (never a URL/log). code is the HTTP status: 404 means an OLD gateway without the endpoint, and 503 a gateway
// whose grants read failed (nowhere-cloud NWC-20261010-03) -> callers fail open. ⚠ NOT because a later /lease 402
// backstops it: the gateway never refuses a seal for being over plan (it sets over_plan, which this agent does not
// read), so during such a window nothing bounds adds -- storage can run past the plan; no money moves.
func (g *gatewayClient) entitlement(profile string) (entitlementInfo, int, error) {
	var e entitlementInfo
	code, err := g.postJSON("/entitlement", map[string]string{"profile": profile}, &e)
	if err == nil && code != http.StatusOK {
		return e, code, fmt.Errorf("entitlement: HTTP %d", code)
	}
	return e, code, err
}

// rebindResp is the /rebind reply: how many grants the NEW key holds as a result of the call.
type rebindResp struct {
	Moved int `json:"moved"`
}

// rebind asks the gateway to move this profile's plan to the key a credential change produced
// (NWP-20260917-04, gateway half NWC-20260917-01). Both refs ride in the POST body, never a URL.
//
// ⚠ THE code != 200 BRANCH IS NOT OPTIONAL. postJSONReasonOn returns err == nil on EVERY non-2xx,
// so checking only err would read a 404 from a gateway that predates the endpoint, or a 503 from one
// whose ledger is wedged, as a successful move.
func (g *gatewayClient) rebind(oldRef, newRef string) (int, int, error) {
	var out rebindResp
	code, reason, err := g.postJSONReason("/rebind", map[string]string{"old": oldRef, "new": newRef}, &out)
	if err != nil {
		return 0, code, err
	}
	if code != http.StatusOK {
		if reason != "" {
			return 0, code, fmt.Errorf("rebind: HTTP %d (%s)", code, reason)
		}
		return 0, code, fmt.Errorf("rebind: HTTP %d", code)
	}
	return out.Moved, code, nil
}

// rebindPlanReporting carries a paid plan across a credential change. It is BEST EFFORT BY CONSTRUCTION,
// and its bool says only whether a RETRY is worth making -- it is never an error a caller could propagate,
// because every caller is a credential change whose own success must not depend on a billing round-trip.
//
// NWP-20260917-16: there was a SECOND entry point, maybeRebindPlan, which called this and threw the verdict
// away. That discard is precisely what let a carry that SUCCEEDED leave its !bill-prev record behind, so
// that every later login re-sent the same /rebind forever. One body now, and the verdict is always read.
//
// ⚠⚠ IT MUST NEVER RETURN OR PANIC AN ERROR INTO ITS CALLER. handleRotate reads any error from
// rotateVault as a rotation outcome and, below capRetireBegun, ROLLS THE KEYGUARD BACK -- aiming the
// lockscreen at a passphrase that no longer opens the vault. recoverVault's daemon wrapper collapses any
// error to BLANK, so a recovery that actually worked would tell the user their twelve words were wrong.
// A plan that failed to follow is a support ticket; either of those is a lockout.
//
// ⚠ THE oldRef != newRef GUARD IS LOAD-BEARING. Nothing in the agent or the chooser rejects
// newpass == oldpass -- which is why rotateVault already carries the same comparison before retiring the
// old bare ref -- and the gateway allows one move per plan per cooldown. A no-op "change" that spent
// that move would strand the plan for the whole window.
//
// gwProbe (4s), not gwDefault: this is a fail-open call where waiting is pure cost. ROTATE is already
// budgeted at 75s against the chooser's 90s and has spent two Argon2id passes and a metered capFlush by
// the time it gets here.
// It reports whether the carry is SETTLED, i.e. whether there is any point retrying it. Settled means the
// gateway said a grant is now at the new key. Everything else -- a refusal, a wire failure, a 0 -- is
// unsettled and stays retryable.
//
// ⚠ 0 IS DELIBERATELY AMBIGUOUS AND MUST STAY THAT WAY. The gateway answers 200 {"moved":0} to a
// cooldown, an unknown profile and a profile with no live grant alike, so a holder of a leaked key
// cannot learn that a plan exists and moved recently. Nothing here can tell them apart, which is why a
// 0 leaves the record in place and lets the CALLER decide when to stop (see the wallet gate at the
// login retry): a cooldown really does want retrying tomorrow, and a profile with no plan is stopped by
// the wallet check rather than by reading the reply.
func rebindPlanReporting(oldRef, newRef string) (settled bool) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[agent] plan carry: skipped (%s)\n", logSafeErrText(r))
			settled = false
		}
	}()
	gw := os.Getenv("GATEWAY_URL")
	if gw == "" || oldRef == "" || newRef == "" || oldRef == newRef {
		return false
	}
	moved, code, err := newGatewayClient(gw, gwProbe).rebind(oldRef, newRef)
	switch {
	case err != nil:
		fmt.Fprintf(os.Stderr, "[agent] plan carry FAILED (HTTP %d): %v\n", code, err)
		return false
	case moved > 0:
		fmt.Fprintf(os.Stderr, "[agent] plan carry: %d grant(s) moved to the new credential\n", moved)
		return true
	default:
		fmt.Fprintf(os.Stderr, "[agent] plan carry: nothing to move\n")
		return false
	}
}

type tokensReq struct {
	Count   int    `json:"count"`
	Payment string `json:"payment"`
}

type tokensResp struct {
	Tokens []Token `json:"tokens"`
}

// buyFaucet mints tokens via the dev faucet (step 1; real payment rails are a later slice).
func (g *gatewayClient) buyFaucet(count int) ([]Token, error) {
	var out tokensResp
	code, err := g.postJSON("/tokens", tokensReq{Count: count, Payment: "dev-faucet"}, &out)
	if err != nil {
		return nil, err
	}
	if code != http.StatusOK {
		return nil, fmt.Errorf("tokens: HTTP %d", code)
	}
	return out.Tokens, nil
}

// ---- zero-knowledge (blind) token issuance (P3b): the device half of the unlinkable-billing arc ----

// blindTokenExpiry is the one expiry every zero-knowledge token the phone mints carries: 1 January 2100 UTC
// (docs/product-decisions.md, 2026-10-20, Q085 -- the stated legal floor is no expiry or at least five years).
// The device writes it into the "denom|nonce|exp" message the issuer signs, so the blind path needs no gateway
// change; the gateway only checks time.Now().Unix() > exp at /lease. A fixed value, not now+TTL, so every token
// minted from now on is identical in this field and credit cannot age out unnoticed. Tokens minted before
// NWP-20261031-08 keep their 365-day expiry (Q010: no warning is built, nothing is re-minted).
const blindTokenExpiry int64 = 4102444800 // 2100-01-01T00:00:00Z

type issuePubResp struct {
	PubKeyPEM string `json:"pubkey_pem"`
	Denom     string `json:"denom"`
}

// issuePubKey fetches the gateway's RSA blind-issuance public key (PKIX PEM) + the token denomination.
// The device blinds against this key and verifies the finalized signatures with it.
func (g *gatewayClient) issuePubKey() (*rsa.PublicKey, string, error) {
	var r issuePubResp
	if err := g.getJSON("/issue/pubkey", &r); err != nil {
		return nil, "", err
	}
	blk, _ := pem.Decode([]byte(r.PubKeyPEM))
	if blk == nil {
		return nil, "", errors.New("issue/pubkey: not a PEM block")
	}
	pub, err := x509.ParsePKIXPublicKey(blk.Bytes)
	if err != nil {
		return nil, "", err
	}
	rp, ok := pub.(*rsa.PublicKey)
	if !ok {
		return nil, "", errors.New("issue/pubkey: not an RSA public key")
	}
	return rp, r.Denom, nil
}

type issueReq struct {
	Claim   string   `json:"claim"`
	Blinded []string `json:"blinded"` // base64 (std) blinded messages
}
type issueResp struct {
	BlindSigs []string `json:"blind_sigs"` // base64 (std), 1:1 with blinded
	// What the redeemed claim paid for. Absent from an older gateway, and absent for a claim recorded
	// before the storefront sent it -- in both cases the device keeps asking for a single period.
	Periods int64 `json:"periods,omitempty"`
	GB      int   `json:"gb,omitempty"`
}

func (g *gatewayClient) issue(claim string, blinded []string) (issueResp, int, error) {
	var out issueResp
	code, err := g.postJSON("/issue", issueReq{Claim: claim, Blinded: blinded}, &out)
	return out, code, err
}

// issueBatch claims exactly n blind tokens for `claim` against the given issuer key + denom: it blinds n
// fresh denom|nonce|exp messages, POSTs /issue, then Finalizes (unblinds + verifies) each signature. It
// returns the tokens and the HTTP status, so a caller can tell a spent/insufficient claim (402) apart from
// a transport/crypto error. It does NOT touch the wallet -- the caller persists -- so a batch is atomic.
func (g *gatewayClient) issueBatch(pub *rsa.PublicKey, denom, claim string, n int) ([]BlindToken, issueResp, int, error) {
	exp := blindTokenExpiry
	msgs := make([][]byte, n)
	invs := make([][]byte, n)
	blinded := make([]string, n)
	for i := 0; i < n; i++ {
		var nb [12]byte
		if _, err := rand.Read(nb[:]); err != nil {
			return nil, issueResp{}, 0, err
		}
		// message = denom|nonce|exp -- the exact format the gateway parses at /lease (matches issuer.canonical)
		msg := []byte(denom + "|" + base64.RawURLEncoding.EncodeToString(nb[:]) + "|" + strconv.FormatInt(exp, 10))
		bl, inv, err := blindrsa.Blind(pub, msg)
		if err != nil {
			return nil, issueResp{}, 0, err
		}
		msgs[i], invs[i], blinded[i] = msg, inv, base64.StdEncoding.EncodeToString(bl)
	}
	res, code, err := g.issue(claim, blinded)
	if err != nil {
		return nil, issueResp{}, code, err
	}
	if code != http.StatusOK {
		return nil, res, code, nil // e.g. 402 (claim spent/insufficient) -- not an error here; the caller decides
	}
	sigs := res.BlindSigs
	if len(sigs) != n {
		return nil, res, code, fmt.Errorf("issue: got %d signatures, want %d", len(sigs), n)
	}
	toks := make([]BlindToken, n)
	for i, s := range sigs {
		bs, err := base64.StdEncoding.DecodeString(s)
		if err != nil {
			return nil, res, code, fmt.Errorf("issue: bad blind signature encoding: %w", err)
		}
		sig, err := blindrsa.Finalize(pub, msgs[i], bs, invs[i]) // unblinds AND verifies; fails closed
		if err != nil {
			return nil, res, code, fmt.Errorf("issue: finalize/verify failed: %w", err)
		}
		toks[i] = BlindToken{Msg: base64.StdEncoding.EncodeToString(msgs[i]), Sig: base64.StdEncoding.EncodeToString(sig)}
	}
	return toks, res, code, nil
}

// purchaseIDRand is where newPurchaseID reads its randomness; a var so a test can make the read fail.
var purchaseIDRand io.Reader = rand.Reader

// newPurchaseID mints the random id of one recorded purchase (h60 #14), or "" when the random source fails. The purchase
// is then recorded without an id and merges by the older rule. A variable so a test can replace it. io.ReadFull, not
// rand.Read: since Go 1.24 rand.Read aborts the process on a reader error instead of returning it.
var newPurchaseID = func() string {
	b := make([]byte, 16)
	if _, err := io.ReadFull(purchaseIDRand, b); err != nil {
		fmt.Fprintln(os.Stderr, "[agent] wallet: the purchase id could not be generated -- the purchase is recorded without one (h60 #14)")
		return ""
	}
	return hex.EncodeToString(b)
}

// applyPlanMode records in w what the wallet's owner bought; it saves nothing. ~~It never OVERWRITES a longer term
// with a shorter one~~ -- SUPERSEDED (NWP-20261031-07; decided 2026-10-20, docs/product-decisions.md "a bigger plan
// starts at once ..."): that max priced a 10 GB top-up redeemed under a live 50 GB plan at 50 GB x periods, which the
// wallet could never fund, so the top-up was paid for and permanently unspendable. Each purchase activates at its OWN
// size and term.
//
// A purchase redeemed while an earlier one is still waiting is QUEUED behind it (Wallet.PlanQueue); one redeemed with
// nothing waiting REPLACES the plan (the earlier one has activated, its tokens are spent).
//
// ⚠ planPending() IS READ BEFORE THIS CLAIM'S TOKENS ARE APPENDED, AND THAT ORDER IS LOAD-BEARING: recordClaimBatch
// calls this on the first successful batch of each drain, before it appends that batch's tokens in the same save, so
// "an unactivated purchase is funded" means an EARLIER purchase, never this one. Read after the append it would always
// be true and every purchase would queue behind itself.
//
// A plan equal to the last one recorded (the queue's last entry, or PlanGB/PlanPeriods when the queue is empty) records
// nothing -- the answer (keep, convert or none) is part of the plan, so the same size and term with another answer is
// another purchase and queues with its own: a partly drained code redeemed again runs a new drainClaim and lands here
// with the same plan, and an identical repeat purchase is already re-bought by planPurchase because the balance still
// covers the price.
//
// THE HOLD (Wallet.ActivateAfter, Q134). A purchase that REPLACES the plan starts a fresh hold once the stored one has
// ended (NWP-20261129-05): planPurchase holds only while ActivateAfter is later than now, so a value at or before now
// is a finished wait. Testing for zero is not enough: capFlush never clears ActivateAfter when a purchase lands and
// walletForPublish keeps the later copy, so after a profile's first purchase it is never 0 again, and every later
// purchase recorded no wait. A hold still running is kept, so a second top-up cannot keep pushing activation away --
// the delay is a fixed privacy budget, not a penalty that compounds. A purchase that QUEUES never moves the hold of the
// purchase it waits behind, even one that has passed; it starts a hold only when none was ever set.
//
// ⚠ RESIDUAL: a hold left in the FUTURE by an over-free activation (planPurchase ignores the hold when overFree and no live term covers the profile) still
// applies to a purchase redeemed before it ends, which then starts on that hold's batch day.
//
// mode is the customer's answer at redemption: "keep", "convert" (h51 #5, NWP-20261125-12) or "" when the question
// was not asked. Any other mode records no answer.
func applyPlanMode(w *Wallet, periods int64, gb int, mode string) {
	keep, convert := mode == planChangeKeep, mode == planChangeConvert
	if w.planPending() {
		last := PlanSpec{GB: w.PlanGB, Periods: w.PlanPeriods, Keep: w.PlanKeep, Convert: w.PlanConvert}
		if n := len(w.PlanQueue); n > 0 {
			last = w.PlanQueue[n-1]
		}
		if last.GB != gb || last.Periods != periods || last.Keep != keep || last.Convert != convert {
			w.PlanQueue = append(w.PlanQueue, PlanSpec{ID: newPurchaseID(), GB: gb, Periods: periods, Keep: keep, Convert: convert})
		}
		if w.ActivateAfter == 0 {
			w.ActivateAfter = activationHold()
		}
	} else {
		w.PlanGB, w.PlanPeriods, w.PlanKeep = gb, periods, keep
		w.PlanConvert = convert
		w.PlanID = newPurchaseID()
		if w.ActivateAfter <= nowEpoch() {
			w.ActivateAfter = activationHold()
		}
	}
}

// recordPlanMode is applyPlanMode as one load and one save.
// ⚠ THE CALLER HOLDS THE WALLET LOCK (NWP-20261010-04).
func recordPlanMode(walletPath string, periods int64, gb int, mode string) error {
	w, err := loadWallet(walletPath)
	if err != nil {
		return err
	}
	applyPlanMode(w, periods, gb, mode)
	return saveWallet(walletPath, w)
}

// recordPlan is recordPlanMode for the callers that carry only keep (true) or no answer (false).
func recordPlan(walletPath string, periods int64, gb int, keep bool) error {
	return recordPlanMode(walletPath, periods, gb, planModeFor(keep))
}

// planActivated is called where a paid lease that declared buyGB x periods came back having spent at least that many
// signatures (the purchase landed; a 409 retry that bought nothing does not count). It promotes the next queued
// purchase to PlanGB/PlanPeriods and restarts the privacy jitter, so the next one is held back again: more delay,
// never less, as jitterEpochs's own rule says. The gateway decides when each term starts; the wallet only presents
// them in order. With nothing queued it changes nothing.
func (w *Wallet) planActivated() {
	if len(w.PlanQueue) == 0 {
		return
	}
	next := w.PlanQueue[0]
	w.PlanGB, w.PlanPeriods, w.PlanKeep = next.GB, next.Periods, next.Keep
	w.PlanConvert = next.Convert
	w.PlanID = next.ID
	w.PlanQueue = append([]PlanSpec(nil), w.PlanQueue[1:]...)
	if len(w.PlanQueue) == 0 {
		w.PlanQueue = nil
	}
	w.ActivateAfter = activationHold()
}

// planChange is the plan_change a lease for the waiting purchase carries: the customer's answer, or "" when none was
// given (h51 #5).
func (w *Wallet) planChange() string {
	if w.PlanKeep {
		return planChangeKeep
	}
	if w.PlanConvert {
		return planChangeConvert
	}
	return ""
}

// planChangeKeep and planChangeConvert are the two plan_change values; each is sent only when the customer chose it at
// redemption (h51 #5, NWP-20261125-12). A purchase redeemed without the question (plain CLAIM) sends nothing, which the
// gateway reads as its default.
const (
	planChangeKeep    = "keep"
	planChangeConvert = "convert"
)

// planModeFor maps the older bool callers (keep or no answer) onto a mode: "keep" or "".
func planModeFor(keep bool) string {
	if keep {
		return planChangeKeep
	}
	return ""
}

// planChangeFor drops the choice from a lease that buys nothing: the field rides only with buy_gb (the gateway's rule).
func planChangeFor(buyGB int, planChange string) string {
	if buyGB <= 0 {
		return ""
	}
	return planChange
}

// afterActivation is a copy of w as planActivated leaves it: the wallet a landed purchase publishes. The cap
// fold is taken BEFORE the lease, so it serialises this copy rather than w (NWP-20261031-07, RF-001).
func (w *Wallet) afterActivation() *Wallet {
	c := *w
	c.planActivated()
	return &c
}

// activationJitterEpochs is the widest delay between claiming a plan and redeeming it. Two days at a
// one-day epoch: long enough that a redemption cannot be matched to a purchase by timestamp. The customer
// is unaffected in SUBSTANCE -- their term is measured from activation, so nothing is lost by waiting.
//
// ⚠ NWP-20260918-08: THIS COMMENT USED TO CLAIM THE DELAY WAS "short enough that nobody wonders why their
// plan has not started". That was falsified the first time anyone met it. Chester bought a 10 GB / 3-month
// plan on 2026-09-18, saw "Not leased yet", and asked what had been broken -- he owns the product and he
// still read a deliberate privacy defence as a regression. Nobody wonders only because nobody was told.
//
// The delay is NOT the defect and must not be shortened to make a screen read better: that would trade the
// unlinkability property for a copy problem. The fix is to SAY a purchase is waiting -- billingLine emits
// `pending=1` and the chooser names the plan -- so "unaffected in substance" is something the customer can
// actually see rather than something only this comment knows.
const activationJitterEpochs = 2

// jitterRand is where jitterEpochs reads its randomness; a var so a test can make the read fail.
var jitterRand io.Reader = rand.Reader

// jitterEpochs picks the delay. crypto/rand because the whole point is unpredictability to an observer who
// may also be holding the purchase record; a seeded PRNG in a fleet of identical devices is guessable.
// The draw is uniform over 0..n for ANY n (rand.Int, not a modulo of one random byte, which could never
// exceed 255 and was biased unless n+1 divided 256).
func jitterEpochs() int64 {
	// RING OVERRIDE (nowhere.conf -> env). A test ring needs a purchase to land while someone is watching:
	// up to two days of delay is correct for a customer and useless for verifying that a plan activates at
	// all. 0 disables the delay entirely.
	//
	// ⚠ Only a RING config can set this, and production ships with no ring, so the default stands where it
	// matters. Negative or unparseable values fall through to the default rather than being clamped to 0 --
	// a typo must not silently switch the privacy defence off.
	if v := os.Getenv("ACTIVATION_JITTER_EPOCHS"); v != "" {
		if n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64); err == nil && n >= 0 {
			if n == 0 {
				return 0
			}
			return drawJitter(n, n)
		}
	}
	return drawJitter(activationJitterEpochs, activationJitterEpochs) // fail toward MORE delay, never toward redeeming instantly
}

// drawJitter is uniform over 0..n. The bound is built in big arithmetic: int64 n+1 overflows negative at
// MaxInt64 and rand.Int panics on a bound <= 0. A read error returns onErr.
func drawJitter(n, onErr int64) int64 {
	v, err := rand.Int(jitterRand, new(big.Int).Add(big.NewInt(n), big.NewInt(1)))
	if err != nil {
		return onErr
	}
	return v.Int64()
}

// planBatchEpochs is Q134 defence 3 (docs/product-decisions.md, "eighteen recommendations accepted ..."): after the
// 0-2 epoch jitter a plan starts only on an epoch that is a multiple of this. Epoch numbers are absolute unix-days
// (nowEpoch), so every phone shares the same days and every purchase in one 3-day span redeems on the same day,
// which is what stops the gateway's redemption lining up with the storefront's sale by time. Cost: a wait of up to
// about 4 days instead of 2; the free tier covers the profile meanwhile, an over-free one with no live term starts at once
// (planPurchase), and the screen already says the plan is waiting.
const planBatchEpochs = 3

// activationEpoch is now + jitter, and with batch rounded UP to the next multiple of planBatchEpochs (an epoch
// already on one stays). Up, so the batch never shortens the jitter. Pure: no clock, no environment.
func activationEpoch(now, jitter int64, batch bool) int64 {
	e := now + jitter
	if batch {
		if r := e % planBatchEpochs; r != 0 {
			e += planBatchEpochs - r
		}
	}
	return e
}

// activationHold is the ActivateAfter a newly started wait gets. It batches unless the ring override
// ACTIVATION_JITTER_EPOCHS parses to exactly 0: that override exists so a test ring sees a purchase land, and
// rounding would add the days back. A default draw of 0, a positive override and a typo or negative that falls back
// to the default all batch -- the same fail-toward-delay posture as jitterEpochs, and the same parse.
func activationHold() int64 {
	batch := true
	if v := os.Getenv("ACTIVATION_JITTER_EPOCHS"); v != "" {
		if n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64); err == nil && n == 0 {
			batch = false
		}
	}
	return activationEpoch(nowEpoch(), jitterEpochs(), batch)
}

// nowEpoch is the local view of the billing clock, for the paths that have no quote in hand: stamping a local delay,
// and the credit= figure on the billing and entitlement lines. Deciding coverage uses the gateway's CurrentEpoch.
var nowEpoch = func() int64 { return time.Now().Unix() / billingEpochSeconds } // a var so a test can pin the clock

// planPurchase decides whether THIS lease activates the wallet's plan, and picks the signatures to present
// if so. It returns zeroes for an ordinary seal, which is almost every lease.
//
// A plan is bought ONCE per term. Presenting tokens on every lease is what turned routine seals into
// purchases, so the default here is emphatically "buy nothing".
func (w *Wallet) planPurchase(nowEp int64, overFree bool) (gb int, periods int64, plain []Token, blind []BlindToken) {
	gbWant, perWant := w.PlanGB, w.PlanPeriods

	// ⚠ A LIVE WINDOW DOES NOT MEAN A LIVE PLAN, and keying on PaidThrough alone locked customers out of
	// what they had paid for. PaidThrough is advanced by ANY lease, including a token-less FREE one -- so a
	// profile that took a free lease before its plan activated was pinned for the whole free window (90
	// days), holding a funded plan it could not start. Seen on lynx 2026-08-10: purchase redeemed, wallet
	// full, "10 GB plan · 90 days left" on screen, and ZERO grants on the gateway. The screen was reporting
	// a plan the server had never heard of.
	//
	// The distinguishing fact is the WALLET, not the clock: activation SPENDS the tokens, so a funded,
	// unspent plan means the term has not started yet, whatever PaidThrough says. Self-limiting for the
	// same reason -- once spent, this is false.
	//
	// It also lets an early renewal start once its activation hold passes instead of waiting for the old term to lapse,
	// which is the intended behaviour: the gateway stacks from the current expiry, so nothing is lost.
	funded := gbWant > 0 && perWant > 0 && w.balance() >= gbWant*int(perWant)
	if w.PaidThrough > nowEp && !funded {
		return 0, 0, nil, nil // covered, and nothing bought is waiting to start
	}
	if gbWant <= 0 || perWant <= 0 {
		// NO PLAN RECORDED -- a dev-faucet wallet, or a claim that carried no plan metadata (older claim
		// codes; the storefront sets it now). Degrade to a single period sized by whatever the wallet holds
		// rather than never activating at all: credit that can never buy coverage means a failed seal, and
		// on an amnesiac device a failed seal is lost data. Compatibility path, not the model -- a real
		// purchase always arrives with periods and gb from /issue.
		if w.balance() == 0 {
			return 0, 0, nil, nil
		}
		gbWant, perWant = w.balance(), 1
	}
	// Hold inside the jitter window -- UNLESS data is actually at risk: a profile over the free allowance AND with no
	// live bought term (PaidThrough <= now) is one sweep away from losing bytes. A live term covers the data, so an
	// early renewal or top-up waits out its hold like any other purchase (h60 #13). PaidThrough moves only on a bought
	// term (recordCoverage behind leaseBoughtCoverage), so a free window never counts.
	atRisk := overFree && w.PaidThrough <= nowEp
	if w.ActivateAfter > nowEp && !atRisk {
		return 0, 0, nil, nil
	}
	p, b, ok := w.choosePayment(gbWant * int(perWant))
	if !ok {
		// Fewer signatures than the plan costs. Do NOT fall back to a shorter term: a plan is a service
		// period, and slicing a paid term into instalments is exactly the accrual the model forbids. Put
		// the tokens back and lease without buying -- free tier or grace carries the profile, and the
		// customer keeps their credit until the wallet is whole.
		w.settlePayment(p, b, 0)
		return 0, 0, nil, nil
	}
	return gbWant, perWant, p, b
}

// learnPlanSize adopts the gateway's view of the account's plan size. It answers, from the account, a
// question the device had been answering from per-device state.
//
// Wallet.PlanGB is written by recordPlan, which runs only on the handset that redeemed the purchase. With
// two handsets on one account that is per-device state standing in for account truth: Chester bought 50 GB
// on frankel while lynx was signed in; frankel showed "50 GB plan", lynx showed "10 GB", and once lynx
// sealed last BOTH showed 10 GB -- the #wallet ref is shared and last-writer-wins under MULTIDEVICE=0, so
// the whole wallet file was replaced by an older copy of itself.
//
// ASSIGNED, not maxed, for the same reason recordCoverage assigns the deadline: LiveGB is ALREADY a max
// over the account's live grants, so a mid-term downgrade keeps the larger size until that term ends and
// the gateway's answer is the truth at every instant. A local max on top would pin a lapsed plan forever.
//
// ⚠ ZERO IS NEVER WRITTEN, same rule as recordCoverage. A lapsed plan, a free-tier profile and a gateway
// too old to send the field are indistinguishable here, and blanking the size would erase the "50 GB plan"
// half of "50 GB plan, expired" -- the sentence the Storage screen most needs at exactly that moment.
//
// ⚠ IT WRITES AccountPlanGB, NEVER PlanGB, AND THE DISTINCTION IS THE SAFETY OF THE WHOLE CHANGE. An
// earlier draft of this healed PlanGB directly and was wrong in a way no test would have caught for
// months: planPurchase prices a pending purchase at PlanGB*PlanPeriods, so raising it under a wallet that
// already held signatures for a SMALLER top-up would make choosePayment fail forever -- money paid and
// permanently unspendable, behind a screen that looks correct. Learning into a display-only field cannot
// do that. It also needs no cleverness about when to skip: there is no state in which writing this is
// unsafe, so there is no gate to get wrong.
//
// The run-order list (NWP-20261120-10, h48 #9) follows the same rule. An absent or invalid list is no news and
// leaves the stored one. A valid one-step list is stored: it replaces a two-step list whose first term ended.
func learnPlanSize(w *Wallet, info leaseInfo) {
	if info.PlanGB > 0 {
		w.AccountPlanGB = info.PlanGB
	}
	if planStepsValid(info.Plans) {
		w.AccountPlans = append([]leasePlanStep(nil), info.Plans...)
	}
}

// planStepsValid is true for a non-empty list whose every step has a size and a term end.
func planStepsValid(steps []leasePlanStep) bool {
	if len(steps) == 0 {
		return false
	}
	for _, s := range steps {
		if s.GB <= 0 || s.ThroughEpoch <= 0 {
			return false
		}
	}
	return true
}

// livePlanSteps keeps, in order, the steps whose term has not ended at now.
func livePlanSteps(steps []leasePlanStep, now int64) []leasePlanStep {
	var out []leasePlanStep
	for _, s := range steps {
		if s.ThroughEpoch >= now {
			out = append(out, s)
		}
	}
	return out
}

// planStepsWire is the plans= value: <gb>:<through> per step, joined by commas and no spaces (the chooser splits
// GET-BILLING's tokens on white space).
func planStepsWire(steps []leasePlanStep) string {
	parts := make([]string, 0, len(steps))
	for _, s := range steps {
		parts = append(parts, fmt.Sprintf("%d:%d", s.GB, s.ThroughEpoch))
	}
	return strings.Join(parts, ",")
}

// planSizeForDisplay is the number the Storage screen shows as "N GB plan".
//
// The ACCOUNT's size wins, because that is what the customer owns and it is identical on every handset.
// The one exception is a purchase that has not activated yet: the device is then holding a fact the
// gateway does not have, and showing the account's older size would tell someone who bought 50 GB minutes
// ago that they have 10 -- for up to two days, since activation waits out the privacy jitter. planPending
// is exactly "funded and not yet activated", and it is self-limiting: activation spends the signatures.
func planSizeForDisplay(w *Wallet) int {
	if w.AccountPlanGB > 0 && !w.planPending() {
		return w.AccountPlanGB
	}
	return w.PlanGB
}

// recordCoverage caches what the gateway just granted. A ZERO field is never written: an older gateway
// sends no deadline, and absent must stay absent so the UI shows nothing rather than a date it invented.
//
// `full` says whether the lease covered the PROFILE'S WHOLE FOOTPRINT, and only a full lease may record a
// deadline. The gateway answers with the EARLIEST deadline among the refs IN THAT CALL, so a delta lease
// reports the floor of a handful of freshly-stamped refs and says nothing about the cold ones -- recording
// it would print a date later than the one the collector will actually use, on the single number the whole
// expiry ladder rests on. A full lease's answer IS the profile's true floor, so it is ASSIGNED rather than
// maxed: it can legitimately move nearer when a new ref lands with a shorter deadline, and that is the
// truth rather than a regression.
// recordLease records what a lease ESTABLISHED, which is true whether or not it bought any term: the
// account’s plan size, and the fact that the whole footprint was re-stamped just now.
//
// Split out of recordCoverage by NWP-20260915-26 so the only thing a term-less lease withholds is the
// CLAIM ABOUT THE TERM. ⚠ THE SPLIT FIXES A SHIPPED BUG IN PASSING, which is why it is a split rather
// than a "skip recordCoverage" gate: the arms that must not record a term called learnPlanSize ALONE, so
// RenewedEpoch was never written on them. renewalDue is
//
//	w.PaidThrough <= nowEpoch || nowEpoch-w.RenewedEpoch >= renewEveryEpochs || w.planPending()
//
// and its FIRST clause already covers a lapsed profile, so the miss is invisible there. It bites exactly
// the profiles with a LIVE remembered term whose lease buys nothing -- a 409 withdrawal, and the
// credential-changed profile of NWP-20260915-17/-19 -- for whom the second clause is the only one that
// can fire. Those re-lease their WHOLE FOOTPRINT on every 120s keep-alive, forever: profileFootprint
// re-opens every scope and walks every chunk, and none of it is throttled (freeRenewedThrough guards the
// free path only, and these profiles are not on it).
func recordLease(w *Wallet, info leaseInfo, full bool, nowEpoch int64) {
	learnPlanSize(w, info)
	// ⚠ A LEASE MAY LENGTHEN THE TERM, NEVER SHORTEN IT (NWP-20260915-19). This was an unconditional
	// assignment, and the field it writes is the one the Storage screen turns into "274 days left".
	//
	// The gateway answers a profile it holds no grant for with a rolling ONE-EPOCH grace lease --
	// through = now + 1, HTTP 200, Lapsed false -- which is a correct answer to "may I write", and a
	// catastrophic one to record as "this is the term you bought". A credential change makes the
	// profile a stranger to the gateway (entitlement grants are keyed on profileRefV2(name, pass), so
	// they do not follow the passphrase), so within a day of rotating or recovering, a customer holding
	// nine months of an annual plan was told they had one day left -- and the wallet, which is the only
	// remaining record that they ever bought it, had overwritten the evidence.
	//
	// Monotonic is not a new rule invented here: walletForPublish already merges this very field by MAX,
	// and says why -- "a term never shortens, a deadline never nears ... Taking the max is therefore not
	// a guess about which write came last; it is the true value in both." Only the RECORD side ever
	// disagreed with the PUBLISH side. A term that has genuinely run out still reads as expired, because
	// a preserved PaidThrough in the PAST is exactly what expiry looks like.
	//
	// DeadlineEpoch below is deliberately left alone. It is the COLLECTOR's date, not the customer's
	// term, and an earlier one is the safe direction to believe: it makes the device warn sooner.
	if !full {
		return
	}
	if nowEpoch > 0 {
		w.RenewedEpoch = nowEpoch
	}
}

// leaseBoughtCoverage reports that the GATEWAY stood behind this lease with a term -- either it charged
// for one (Spent) or it named a live grant that already covers it (PlanGB). Both limbs are the
// gateway’s own answer; neither is the device’s declaration about what it hoped to buy.
//
// ⚠ ONLY VALID ON leaseEntitled’S REPLY. This is a property of the ARM, not of leaseInfo, and it
// cannot be hoisted into recordCoverage. handleFreeLease sends PlanGB alongside a through_epoch that is
// the ROLLING 90-DAY FREE WINDOW ("a customer who buys 50 GB and stores 200 MB ... takes this arm on
// every seal"), so reading this predicate on a free reply would rewrite a 12-month term to now+90d on
// every seal, refreshed forever -- NWP-20260829-06 again, with a 90-day latch instead of a 1-day one.
// Both call sites are on the entitled arm and must stay there.
func leaseBoughtCoverage(info leaseInfo) bool {
	return info.Spent > 0 || info.PlanGB > 0
}

// recordCoverage is recordLease plus the two claims only a bought term supports: how long the customer is
// paid up for, and when the collector takes the data if they stop. Call it only behind
// leaseBoughtCoverage.
func recordCoverage(w *Wallet, info leaseInfo, full bool, nowEpoch int64) {
	recordLease(w, info, full, nowEpoch)
	// ⚠ A LEASE MAY LENGTHEN THE TERM, NEVER SHORTEN IT (NWP-20260915-19). This was an unconditional
	// assignment, and the field it writes is the one the Storage screen turns into "274 days left".
	//
	// The gateway answers a profile it holds no grant for with a rolling ONE-EPOCH grace lease --
	// through = now + 1, HTTP 200, Lapsed false -- which is a correct answer to "may I write", and a
	// catastrophic one to record as "this is the term you bought". A credential change makes the
	// profile a stranger to the gateway (entitlement grants are keyed on profileRefV2(name, pass), so
	// they do not follow the passphrase), so within a day of rotating or recovering, a customer holding
	// nine months of an annual plan was told they had one day left -- and the wallet, which is the only
	// remaining record that they ever bought it, had overwritten the evidence.
	//
	// Monotonic is not a new rule invented here: walletForPublish already merges this very field by MAX,
	// and says why -- "a term never shortens, a deadline never nears ... Taking the max is therefore not
	// a guess about which write came last; it is the true value in both." Only the RECORD side ever
	// disagreed with the PUBLISH side. A term that has genuinely run out still reads as expired, because
	// a preserved PaidThrough in the PAST is exactly what expiry looks like.
	//
	// ⚠ MONOTONIC ALONE WAS NOT ENOUGH, AND THE GAP SHIPPED (NWP-20260915-26). An EXPIRED term is in
	// the past, so now+1 is greater than it and this guard waves the grace lease through -- one epoch
	// per sync, forever. Monotonic decides how a term may MOVE; only leaseBoughtCoverage decides
	// whether it may move at all, and that is the caller’s job because it is a fact about the ARM.
	if info.ThroughEpoch > w.PaidThrough {
		w.PaidThrough = info.ThroughEpoch
	}
	if !full {
		return
	}
	// The collector’s date, under the same gate as the term and NOT in recordLease, for two reasons.
	// NWP-20260906-03 put it here: a customer whose purchase just failed must not be told it succeeded
	// with a deletion date attached, because the date is what makes the false term look corroborated.
	// And walletForPublish merges this field by MAX too, so the EARLIER date a grace lease carries could
	// not survive a publish round-trip anyway -- recording it would make the screen flicker on whether
	// the wallet had been published since, which is the record-vs-publish disagreement the paragraph
	// above exists to remove, arrived at from the other side.
	if info.DeadlineEpoch > 0 {
		w.DeadlineEpoch = info.DeadlineEpoch
	}
}

// renewEveryEpochs is how often the WHOLE footprint is re-leased regardless of how much term is left.
//
// 30 days, which is not a new number: before the device started buying its real term, PaidThrough sat one
// 30-day period out and payRent therefore ran at exactly this cadence. It was safe then and is safe now,
// because the binding constraint is the shortest life any ref can carry -- a free-stamped ref at
// FreeTTL(90d) + grace(30d) = 120 days from last access. Renewing every 30 keeps a 4x margin.
//
// It must NOT be derived from the purchased term. A longer term buys more coverage, not permission to stop
// refreshing the refs that coverage applies to.
const renewEveryEpochs int64 = 30

// renewalDue reports whether payRent should lease the whole footprint this pass. Split out so the rule can
// be tested directly: reaching it through payRent needs a store, a data key and a real footprint, and the
// regression it guards (the staleness arm going missing) is invisible until refs start disappearing months
// later.
//
// DUE   -- the paid window no longer covers this epoch, so rent is owed.
// STALE -- the window is fine but the footprint has not been re-leased in renewEveryEpochs, so cold refs
//
//	are drifting toward their own deadlines with nothing refreshing them.
func renewalDue(w *Wallet, nowEpoch int64) bool {
	return w.PaidThrough <= nowEpoch || nowEpoch-w.RenewedEpoch >= renewEveryEpochs || w.planPending()
}

// planPending reports that the wallet holds a plan that has been PAID FOR but never activated -- the
// signatures are still in hand.
//
// ⚠ It is the condition that must override "the free tier already covered this, so there is nothing to
// do". Without it a customer UNDER the free allowance can never start the plan they bought: payRent
// suppresses itself while PaidThrough is in the future (a free lease puts it 90 days out), and capFlush
// only ever reached the paid path on a 402, i.e. when the profile was ALREADY over quota. That control
// flow is the metered model's -- buy only when you exceed something -- and it outlived the model it
// belonged to. Under a service period the purchase is the event; the footprint is irrelevant to it.
//
// Self-limiting: activation spends the signatures, so this is false immediately afterwards.
func (w *Wallet) planPending() bool {
	return w.PlanGB > 0 && w.PlanPeriods > 0 && w.balance() >= w.PlanGB*int(w.PlanPeriods)
}

// appendTokens loads the wallet, appends new zero-knowledge tokens, and saves it (atomic temp+rename).
// ⚠ THE CALLER HOLDS THE WALLET LOCK, and took it BEFORE minting these (NWP-20261010-04; see drainClaim).
func appendTokens(walletPath string, toks []BlindToken) error {
	w, err := loadWallet(walletPath)
	if err != nil {
		return err
	}
	w.BlindTokens = append(w.BlindTokens, toks...)
	return saveWallet(walletPath, w)
}

// claimTokens redeems a paid CLAIM code for EXACTLY `count` zero-knowledge storage tokens and adds them to
// the wallet. Unlinkability comes from blinding: the device generates each token's nonce + a blinding
// factor locally, the gateway blind-signs WITHOUT ever seeing the token, and the device unblinds. Tokens
// persist only on full success -- a partial/HTTP failure leaves the wallet untouched. (drainClaim is the
// device path used when the purchased count isn't known.)
func claimTokens(g *gatewayClient, walletPath, claim string, count int) (int, error) {
	if claim == "" {
		return 0, errors.New("claim: empty claim code")
	}
	if count <= 0 {
		return 0, errors.New("claim: count must be > 0")
	}
	pub, denom, err := g.issuePubKey()
	if err != nil {
		return 0, err
	}
	// NWP-20261010-04: before the mint, and bounded, for the reasons drainClaim states.
	unlock, state := lockWalletWithin(walletPath, walletSignInWait)
	defer unlock()
	if state == walletLockBusy {
		return 0, errWalletBusy
	}
	toks, _, code, err := g.issueBatch(pub, denom, claim, count)
	if err != nil {
		return 0, err
	}
	if code != http.StatusOK {
		return 0, fmt.Errorf("issue: HTTP %d (claim invalid, spent, or insufficient)", code)
	}
	if err := appendTokens(walletPath, toks); err != nil {
		return 0, err
	}
	return count, nil
}

// recordClaimBatch saves one claim batch: when record is set, the plan the gateway reported, and the batch's tokens,
// in ONE load and ONE save, so the plan and its tokens land together or not at all (NWP-20261128-24; NWP-20261122-16
// records a plan only from a batch whose tokens land). Two saves let a failed second write leave a plan with no
// tokens, which the next paid lease bought with the credit the wallet already held.
//
// ⚠ applyPlanMode RUNS BEFORE THE APPEND: its planPending() must read the balance before this batch's tokens, so a
// waiting purchase means an EARLIER one (see applyPlanMode).
// ⚠ THE CALLER HOLDS THE WALLET LOCK (NWP-20261010-04) -- drainClaimOutcome, across the mint that produced toks.
func recordClaimBatch(walletPath string, record bool, periods int64, gb int, mode string, toks []BlindToken) error {
	w, err := loadWallet(walletPath)
	if err != nil {
		return err
	}
	if record {
		applyPlanMode(w, periods, gb, mode)
	}
	w.BlindTokens = append(w.BlindTokens, toks...)
	return saveWallet(walletPath, w)
}

// drainClaimMode redeems an ENTIRE paid claim code into the wallet WITHOUT knowing how many tokens it's worth
// (the device never sees the purchase -- this is the "Add credits" path). It claims in batches that double
// on success and back off on a 402 ("claim spent/insufficient"), converging on the exact remaining count
// in O(log n) round-trips and never over-claiming (the gateway reserves a batch all-or-nothing, so a too-
// large request signs nothing). Each successful batch is persisted as it lands, so an interrupted drain
// can simply be re-run on the same code to finish. Returns the tokens added (0 = unknown or fully spent).
// mode is the customer's answer at redemption ("keep", "convert" or ""), stored with the plan (h51 #5).
// It discards drainClaimOutcome's partial flag; a caller that must tell a drain cut short from a complete one calls that.
func drainClaimMode(g *gatewayClient, walletPath, claim, mode string) (int, error) {
	n, _, err := drainClaimOutcome(g, walletPath, claim, mode)
	return n, err
}

// claimBetweenBatches is a test seam, nil in production: called after a batch lands and before the next lock is taken.
var claimBetweenBatches func()

// drainClaimOutcome is drainClaimMode's body. partial is true when tokens landed (n > 0, err nil) and the drain stopped
// before the proving 402 -- a busy wallet, a refused batch or an unexpected status -- so the code may still hold more
// (NWP-20261201-21; decided 2026-11-06, h60 #15 in docs/product-decisions.md). Every other return has partial false.
func drainClaimOutcome(g *gatewayClient, walletPath, claim, mode string) (n int, partial bool, err error) {
	if claim == "" {
		return 0, false, errors.New("claim: empty claim code")
	}
	pub, denom, err := g.issuePubKey()
	if err != nil {
		return 0, false, err
	}
	const maxBatch = 256
	total, batch := 0, 1
	planned := false
	for {
		// NWP-20261010-04: THE WALLET LOCK IS TAKEN BEFORE THE MINT AND HELD UNTIL THE BATCH IS SAVED. Minted
		// tokens are bearer instruments the gateway cannot re-issue, and between the mint and the save they
		// exist only in this process's memory. Locking only around the save would put the WAIT for a busy
		// wallet -- a flush's leases, a payRent -- inside that window, and a daemon killed while waiting would
		// lose the batch. Waiting first means a kill during the wait loses nothing; the window is one /issue
		// round trip, as before the lock. Holding the lock across that round trip is allowed: it takes no lock
		// and opens no bracket. (A closure, so a panic in the batch still releases the lock.)
		//
		// ⚠ THE WAIT IS walletSignInWait, AND A WALLET STILL BUSY AFTER IT REFUSES THE CLAIM (errWalletBusy) BEFORE
		// THIS BATCH MINTS. A person is waiting on CLAIM, and CREATE-CODE creates the profile and shows its one-time
		// recovery code only after the drain: waiting out another holder's leases ran both past the chooser's read.
		// Refusing first leaves the code holding what was not minted, so a retry finishes the drain.
		//
		// ⚠ TO A WAITER THIS IS ONE HOLD: the lock is let go between batches and taken again at once, so a waiter
		// polling every walletLockPoll almost never gets in. A large plan (a 1 TB annual claim) is about fifty
		// round trips. A worker flush that meets it gives its wallet up (capFlushWalletWait) and neither spends,
		// folds nor saves -- harmless, because the claim saves every batch itself and handleClaim ends in
		// sealWalletDurable, whose head goes up unless a later writer of this session saved after it read
		// (putWalletHead), and that writer publishes its own.
		var toks []BlindToken
		var code int
		var err, perr error
		busy := false
		func() {
			unlock, state := lockWalletWithin(walletPath, walletSignInWait)
			defer unlock()
			if state == walletLockBusy {
				busy = true
				return
			}
			var plan issueResp
			toks, plan, code, err = g.issueBatch(pub, denom, claim, batch)
			// Record the term the FIRST time the gateway reports one. Doing it here rather than at lease time
			// is the only place the plan is visible: /lease is deliberately profile-scoped and never carries a
			// SKU, so the term has to be learned while the claim code is still in hand.
			//
			// ONLY FROM A BATCH WHOSE TOKENS LAND (NWP-20261122-16): a 200 whose signatures were refused (one short,
			// not base64, or refused by Finalize) comes back with err set and appends no token, so it records
			// nothing. A plan saved without its tokens was bought at the next paid lease with the credit the
			// wallet already held. AND IN THE SAME SAVE AS THEM (NWP-20261128-24): two saves let a failed token
			// write leave the plan behind on its own. recordClaimBatch applies the plan before it appends: its
			// planPending() read depends on it.
			record := !planned && err == nil && code == http.StatusOK && plan.Periods > 0
			if err == nil && code == http.StatusOK {
				perr = recordClaimBatch(walletPath, record, plan.Periods, plan.GB, mode, toks)
			}
			if record && perr == nil {
				planned = true
			}
		}()
		if busy {
			fmt.Fprintf(os.Stderr, "[agent] claim: the wallet is busy -- refused before minting; the code keeps the rest (NWP-20261010-04)\n")
			if total > 0 {
				return total, true, nil // what landed is saved; the code keeps the rest, as on any partial drain
			}
			return 0, false, errWalletBusy
		}
		if perr != nil {
			return total, false, perr
		}
		switch {
		case err != nil:
			if total > 0 {
				logClaimDrainStop(total, claimDrainErrWhy(code))
				return total, true, nil // keep what already landed; report partial success rather than erroring
			}
			return 0, false, err
		case code == http.StatusOK:
			total += len(toks)
			if batch < maxBatch {
				batch *= 2
			}
			if claimBetweenBatches != nil {
				claimBetweenBatches()
			}
		case code == http.StatusPaymentRequired:
			if batch == 1 {
				return total, false, nil // nothing left to claim -> done
			}
			batch /= 2 // overshot the remaining balance; back off and drain the tail
		default:
			if total > 0 {
				logClaimDrainStop(total, fmt.Sprintf("HTTP %d", code))
				return total, true, nil
			}
			return 0, false, fmt.Errorf("issue: HTTP %d", code)
		}
	}
}

// claimDrainErrWhy names in a fixed word why issueBatch returned an error: code 0 is a request that got no answer or was
// never sent, code 200 is signatures that could not be used.
func claimDrainErrWhy(code int) string {
	switch code {
	case 0:
		return "no answer"
	case http.StatusOK:
		return "signatures refused"
	}
	return "error"
}

// logClaimDrainStop writes the one line that tells a drain cut short from a complete one: the caller logs the landed
// count alone in both cases (NWP-20261129-43). Counts and a fixed reason only: never the code (h53 #6), a token, the
// error's text or the gateway URL, so it takes none of them.
func logClaimDrainStop(total int, why string) {
	fmt.Fprintf(os.Stderr, "[agent] claim: the drain stopped after %d token(s) (%s) -- the code keeps the rest, and redeeming it again finishes the drain (NWP-20261129-43)\n", total, why)
}

// drainClaim is drainClaimMode for the callers that carry only keep (true) or no answer (false).
func drainClaim(g *gatewayClient, walletPath, claim string, keep bool) (int, error) {
	return drainClaimMode(g, walletPath, claim, planModeFor(keep))
}

type leaseReq struct {
	// Periods is how many 30-day terms this lease should cover -- what the buyer actually paid for. Absent
	// (0) means one, which is exactly what every device sent before this existed, so an old gateway and a
	// wallet with no known plan both keep the previous behaviour.
	Periods int64 `json:"periods,omitempty"`
	// BuyGB DECLARES a purchase: "activate a plan of this many GB for Periods periods". Zero means this
	// lease buys nothing, and the gateway spends none of the tokens it carries.
	//
	// The declaration exists because the wallet rides along on EVERY lease. While pricing came from stored
	// bytes the gateway could infer intent from the arithmetic; once a plan is a service period there is no
	// arithmetic left, and an inferred purchase turns every 2-minute seal into one -- draining the wallet on
	// the first and re-buying a term on each one after. That is the #133 seal-churn drain.
	BuyGB int `json:"buy_gb,omitempty"`
	// PlanChange is the customer's choice at an upgrade, "keep" or nothing (convert is the gateway's default, and an
	// absent field is what every other lease sends). Sent only with BuyGB (NWP-20261031-10).
	PlanChange  string           `json:"plan_change,omitempty"`
	Tokens      []Token          `json:"tokens"`
	BlindTokens []BlindToken     `json:"blind_tokens,omitempty"` // zero-knowledge tokens (P3b): {msg,sig} base64
	Refs        map[string]int64 `json:"refs"`
	Free        bool             `json:"free,omitempty"`    // free-tier lease (no tokens; gateway meters per profile)
	Profile     string           `json:"profile,omitempty"` // the pseudonymous profileRef the free quota is metered under

	// SkipPresent asks the gateway to report which blobs it ALREADY holds rather than issuing a write cap
	// for them, so we do not re-upload bytes the store has (NWP-20260828-10). Always set: there is never a
	// reason to re-send a content-addressed blob the store can prove it holds.
	//
	// Safe against an OLD gateway: it ignores the unknown field, returns a cap for every ref as before, and
	// Present comes back empty -- so every blob is uploaded, exactly as today. The compatibility risk runs
	// the other way (a new gateway withholding caps from an old agent), which is why the gateway treats this
	// as an opt-in rather than a default.
	SkipPresent bool `json:"skip_present,omitempty"`

	// BoundCaps asks for write caps BOUND to their key (NWP-20261009-02, docs/store-write-authorization.md
	// §5): for a blob the gateway signs `x-amz-checksum-sha256` and `If-None-Match: *` into the presigned
	// PUT and returns them in CapHeaders, so the store itself refuses bytes that do not hash to the key and
	// refuses to overwrite a blob that exists. Always set, from all three builders: a cap that binds nothing
	// is the hole the row was filed for.
	//
	// Safe against an OLD gateway, which ignores the field and returns plain caps with no CapHeaders -- and
	// capPut then sends exactly what it sent before this existed. The flag is an opt-in rather than a
	// gateway default because a bound cap can only be used by a client that sends NO Content-MD5 beside the
	// signed checksum (R2 answers 400 InvalidRequest to the pair, measured 2026-10-08), which is every
	// agent before this slice.
	BoundCaps bool `json:"bound_caps,omitempty"`
	// Prior names the billing keys this profile's ledger rows may still be tagged with, so the gateway may
	// re-tag them to Profile (§4): a row changes hands only to itself, from a legacy untagged row, or to a
	// profile that names its current tag here. A credential change sends the key it moves off; every later
	// bare seal and payRent send the !bill-retag record until a full-footprint lease has settled it. Each
	// entry is a profileRefV2 (64 hex), never a pointer key -- a tombstoned head's row lives for months and
	// would be a skeleton key for the one party a rotation exists to exclude.
	Prior []string `json:"prior,omitempty"`
	// Expire marks the data export's own refs for deletion (NWP-20261010-02, docs/data-export-rekey.md §3): ref ->
	// {proof, when}. Each ref is in Refs and is exportKey(proof), so the gateway can tell an export key from every
	// other key without learning the name, the passphrase or K. "export" keeps the row about 7 days, "now" lets
	// the next GC take it. Only the bracket's own marks ride here (capMarkExpire), never the wallet fold's refs.
	// An older gateway ignores the field and answers no ExpireApplied, which is how the device tells them apart.
	Expire map[string]leaseExpire `json:"expire,omitempty"`
	// ReleaseCommit is blob key -> commitment (blobReleaseCommit, blob_release.go; docs/store-write-authorization.md
	// R5). Its keys are always a subset of Refs. The gateway keeps a commitment only on a blob row THIS lease
	// creates and never changes it afterwards. An older gateway ignores the field.
	ReleaseCommit map[string]string `json:"release_commit,omitempty"`
}

// leaseExpire is one `expire` entry: the proof, 64 lowercase hex, whose hash is the key, and when the row goes.
type leaseExpire struct {
	Proof string `json:"proof"`
	When  string `json:"when"`
}

// The two `when` values the gateway knows (docs/data-export-rekey.md §3).
const (
	expireExport = "export" // the row lives about 7 days from this lease; a re-export resets them
	expireNow    = "now"    // the next GC collects the row (Delete, a passphrase change's old export)
)

// leasePlanStep is one entry of a lease reply's `plans`: a plan size and the epoch its term runs through
// (nowhere-cloud planStep, NWC-20261118-01).
type leasePlanStep struct {
	GB           int   `json:"gb"`
	ThroughEpoch int64 `json:"through_epoch"`
}

type leaseInfo struct {
	ThroughEpoch int64             `json:"through_epoch"`
	Spent        int               `json:"spent"`
	WriteCaps    map[string]string `json:"write_caps"`
	// CapHeaders are, per ref in WriteCaps, the headers a PUT through that cap MUST carry byte-exact: they
	// are signed into the URL, so a missing or altered one is a 403 SignatureDoesNotMatch from the store
	// (NWP-20261009-02). Returned only for a BoundCaps request and only for blob keys; absent for a ref, and
	// entirely from a gateway that predates it -- capPut then takes its Content-MD5 path, which is what it
	// did before this field existed.
	CapHeaders map[string]map[string]string `json:"cap_headers,omitempty"`
	// Present lists refs the gateway already holds: no write cap was issued for them and they must NOT be
	// uploaded. Empty from a gateway that predates this, which simply means "upload everything" -- the
	// behaviour before the field existed.
	Present []string `json:"present,omitempty"`
	// DeadlineEpoch is when these refs become collectable, straight from the gateway's ledger. Zero from a
	// gateway that predates it -- cache nothing in that case rather than inventing a date.
	DeadlineEpoch int64 `json:"deadline_epoch,omitempty"`
	// PlanGB is the ACCOUNT's live purchased plan size (the gateway's LiveGB), in the same unit buy_gb is
	// declared in. Zero from a gateway that predates it, from a free-tier profile and from a lapsed one --
	// all three mean "no news", never "no plan". See learnPlanSize.
	PlanGB int `json:"plan_gb,omitempty"`
	// Plans is the account's live plans in the order they run, each with its size and term end (nowhere-cloud
	// leaseResp.Plans, NWC-20261118-01; h48 #9). Absent means no news, as for PlanGB: an older gateway, a failed
	// grants read, a free lease. See learnPlanSize.
	Plans []leasePlanStep `json:"plans,omitempty"`
	// Reason is NOT from the gateway's JSON: it is the bounded refusal text of a non-2xx reply (gatewayReason),
	// filled by the lease calls so a caller that branches on the status can say WHICH refusal it was. Empty on
	// 200 and on a refusal with no body.
	Reason string `json:"-"`
	// SpentNonces is NOT from a 200's JSON (whose `spent` is the count charged): it is the `spent` LIST of a
	// 409 refusal, the nonces this request presented that the gateway's ledger already held (NWP-20261020-03).
	// Nil when the body has no list, was truncated, malformed or not JSON -- which the 409 arms read as "names
	// none", the behaviour before the field existed.
	SpentNonces []string `json:"-"`
	// ExpireApplied names every `expire` entry the lease marked (NWP-20261010-02). A gateway that honours
	// `expire` names EVERY entry on a 200 -- the marks land in the same all-or-nothing write as the leases -- and
	// an older one never sends the field, so nil here means "not marked", never "marked nothing".
	ExpireApplied []string `json:"expire_applied,omitempty"`
	// BatchesShort is NOT from the gateway: how many LATER renewal batches (Q090) did not land -- an error or a
	// non-200. Zero on a whole renewal, and always zero outside leaseRefsLocked's profile branch and payRent's
	// free arm.
	BatchesShort int `json:"-"`
	// capAt is NOT from the gateway's JSON (unexported, so encoding/json never reads or writes it): per key in
	// WriteCaps, the capNow reading when mergeLeaseInfo merged the batch that minted that cap. capFlush's put
	// re-mints a cap near the end of its life before its PUT (capNearExpiry, NWP-20261123-03).
	capAt map[string]int64
}

func (g *gatewayClient) lease(tokens []Token, blind []BlindToken, refs map[string]int64) (leaseInfo, int, error) {
	var out leaseInfo
	code, reason, err := g.postJSONReasonOn(g.leaseClient(len(refs)), "/lease",
		leaseReq{Tokens: tokens, BlindTokens: blind, Refs: refs, SkipPresent: true, BoundCaps: true}, &out)
	out.Reason = reason
	return out, code, err
}

// leaseEntitled is the CAPACITY-model paid lease (#133): profile-tagged, so the gateway pools purchased
// GB per pseudonymous profile for the window and charges only what the profile's live bytes exceed
// free + entitled -- usually zero. Offered tokens beyond what's owed come back via settlePayment. An old
// gateway ignores the extra field and behaves like lease() (legacy per-call floor), which only overcharges
// the way the old client always did -- never breaks.
// prior: the billing keys this profile's rows may still be tagged with (leaseReq.Prior); nil when none.
func (g *gatewayClient) leaseEntitled(profile string, tokens []Token, blind []BlindToken, refs map[string]int64, periods int64, buyGB int, planChange string, prior []string) (leaseInfo, int, error) {
	return g.leaseEntitledExpire(profile, tokens, blind, refs, periods, buyGB, planChange, prior, nil, nil)
}

// leaseEntitledExpire is leaseEntitled carrying the bracket's `expire` marks (leaseReq.Expire) and the per-blob `release` commitments (leaseReq.ReleaseCommit); nil sends none.
func (g *gatewayClient) leaseEntitledExpire(profile string, tokens []Token, blind []BlindToken, refs map[string]int64, periods int64, buyGB int, planChange string, prior []string, expire map[string]leaseExpire, release map[string]string) (leaseInfo, int, error) {
	var out leaseInfo
	code, reason, conflict, err := g.postJSONRefusalOn(g.leaseClient(len(refs)), "/lease",
		leaseReq{Tokens: tokens, BlindTokens: blind, Refs: refs, Profile: profile, Periods: periods, BuyGB: buyGB, PlanChange: planChangeFor(buyGB, planChange), SkipPresent: true, BoundCaps: true, Prior: cleanPrior(profile, prior), Expire: expire, ReleaseCommit: release}, &out,
		leaseConflictRead(len(tokens)+len(blind)))
	out.Reason = reason
	out.SpentNonces = spentNamed(conflict)
	return out, code, err
}

// cleanPrior is `prior` as the gateway accepts it (docs/store-write-authorization.md §4): at most billRetagMax
// keys, each 64 hex, none repeated -- and NONE EQUAL TO THE PROFILE THE REQUEST IS MADE AS. The gateway answers
// any violation 400 `bad prior` and refuses the whole request (NWP-20261009-02).
//
// ⚠ THE OWN-PROFILE RULE IS REACHABLE, NOT THEORETICAL. A credential change A->B records A; changing back B->A
// before a renewal has settled the record leaves a profile whose record names its own current key. The write
// points drop it (billRetagPush, repointScopes' carry), and this drops it again at every SEND point, because a
// record written by anything else -- an older build, a hand-edited index -- must not turn into a permanent 400
// on every seal, renewal and delete with nothing able to clear it. Applied inside the three senders that pair
// `prior` with a profile (leaseFree, leaseEntitled, writeCapBound), so no caller can forget it. Keeps the
// NEWEST keys when it has to drop some, the same order billRetagPush keeps.
func cleanPrior(profile string, prior []string) []string {
	var out []string
	seen := map[string]bool{profile: true}
	for _, k := range prior {
		if !seen[k] && isContentHash(k) {
			seen[k] = true
			out = append(out, k)
		}
	}
	if len(out) > billRetagMax {
		out = out[len(out)-billRetagMax:]
	}
	return out
}

// leaseFree requests token-less leases on the free tier (up to the gateway's per-profile quota), metered
// under the pseudonymous profileRef. It returns the lease info AND the HTTP status so the caller can tell a
// granted free lease (200) from an over-quota refusal (402 -> fall back to paid) or a disabled free tier
// (403). No wallet is touched -- the free path spends nothing.
// prior: the billing keys this profile's rows may still be tagged with (leaseReq.Prior); nil when none.
func (g *gatewayClient) leaseFree(profile string, refs map[string]int64, prior []string) (leaseInfo, int, error) {
	return g.leaseFreeExpire(profile, refs, prior, nil, nil)
}

// leaseFreeExpire is leaseFree carrying the bracket's `expire` marks (leaseReq.Expire) and the per-blob `release` commitments (leaseReq.ReleaseCommit); nil sends none.
func (g *gatewayClient) leaseFreeExpire(profile string, refs map[string]int64, prior []string, expire map[string]leaseExpire, release map[string]string) (leaseInfo, int, error) {
	var out leaseInfo
	code, reason, err := g.postJSONReasonOn(g.leaseClient(len(refs)), "/lease",
		leaseReq{Free: true, Profile: profile, Refs: refs, SkipPresent: true, BoundCaps: true, Prior: cleanPrior(profile, prior), Expire: expire, ReleaseCommit: release}, &out)
	out.Reason = reason
	return out, code, err
}

// capResp is the gateway's reply to GET /cap: a single presigned URL for one ref + op.
type capResp struct {
	URL string `json:"url"`
}

// readCap fetches a FREE presigned GET URL for ref (reads cost no tokens -- this is what lets a device
// restore its wallet/data without first holding a token). writeCapBound fetches a presigned PUT URL, which
// the gateway grants only to the ref's holder. Both target the gateway's managed store, so a managed device
// uses them instead of store credentials and thus holds NO R2 creds (least-knowledge).
//
// ⚠ IT ASKS `POST /caps`, NOT `GET /cap?op=read&ref=` (NWP-20261009-02). A head key is profileRefV2(name,
// pass) in hex, and since the store binds write caps that same string is the HOLDER AUTHORITY the gateway
// checks: whoever has it can lease as the profile and, through `prior`, re-tag its head rows to a key only
// they know, after which every seal of the owner's is refused 403. A query string is what a proxy or edge
// access log keeps; a POST body is not. The batch route has served every gateway since #71 step 2 and
// presigns every ref it is given with no existence check, so a one-element batch is the same answer.
//
// ⚠ WHAT THIS DOES NOT DO: the presigned GET it returns still carries the key in its PATH, to the store --
// which holds every key anyway. This keeps the key off the GATEWAY's URL and log path, nothing more.
//
// The GET survives only for a gateway with NO /caps route, recognised by 404 or 405 and nothing else. Any
// other refusal, a 200 without this ref, a decode failure or a transport error is returned as an error and
// never falls back: retrying a blip through the GET would put the key back into a URL on exactly the day the
// gateway is unhealthy. capGet's retry asks again, through /caps.
func (g *gatewayClient) readCap(ref string) (string, error) {
	var c capsResp
	code, err := g.postJSON("/caps", map[string]any{"op": "read", "refs": []string{ref}}, &c)
	if err != nil {
		return "", err
	}
	switch code {
	case http.StatusOK:
		if u := c.Caps[ref]; u != "" {
			return u, nil
		}
		return "", errors.New("gateway /caps: 200 without a cap for the requested ref") // the ref is not named
	case http.StatusNotFound, http.StatusMethodNotAllowed: // a gateway that predates /caps
		var one capResp
		err := g.getJSON("/cap?op=read&ref="+url.QueryEscape(ref), &one)
		return one.URL, err
	}
	return "", fmt.Errorf("gateway /caps: HTTP %d", code)
}

// writeCap is the PLAIN write re-mint, GET /cap?op=write: no profile, no binding. It survives only as
// writeCapBound's fallback for a gateway that predates POST /cap (NWP-20261009-02); every caller goes
// through writeCapBound.
func (g *gatewayClient) writeCap(ref string) (string, error) {
	var c capResp
	err := g.getJSON("/cap?op=write&ref="+url.QueryEscape(ref), &c)
	return c.URL, err
}

// capBoundReq is the body of POST /cap, the write re-mint that carries the writer's identity
// (NWP-20261009-02, docs/store-write-authorization.md §5). The profile rides in a BODY, never a query string
// or a header, so it can never land in a proxy's access log -- it is the bare head's store key.
type capBoundReq struct {
	Ref     string   `json:"ref"`
	Profile string   `json:"profile,omitempty"` // profileRefV2 of the lease holder; absent for a throwaway
	Prior   []string `json:"prior,omitempty"`   // leaseReq.Prior, same rule
	Bound   bool     `json:"bound"`             // always true: a re-minted blob cap is bound like a leased one
}

// capBoundResp is POST /cap's reply: the presigned PUT URL and, for a blob, the headers signed into it.
type capBoundResp struct {
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers,omitempty"`
}

// writeCapBound re-mints a write cap for ref as the holder of profile, returning the URL and the headers the
// PUT must carry (nil for a ref key, and for a plain cap). It is what capPut's refresh and delRef call: a
// seal longer than the cap TTL, and a tombstone written outside a lease bracket.
//
// ⚠ 405 FALLS BACK TO GET /cap?op=write, AND NOTHING ELSE DOES. Every fielded gateway routes `GET /cap` as
// a method pattern, so a POST there is 405, and the fallback is byte-for-byte the re-mint every fielded
// device sends today -- a plain URL, no headers, so capPut then takes its Content-MD5 path. Any other
// refusal (403 `held by another profile`, 400 `bad ref shape`, and a 404 a later gateway may use for one)
// is the gateway's verdict on THIS write and is returned as an error rather than retried unauthenticated:
// the profile-less GET is answered only under the transition knob, and falling back to it on a refusal
// would turn an ownership verdict into a second attempt without identity.
func (g *gatewayClient) writeCapBound(ref, profile string, prior []string) (string, map[string]string, error) {
	var c capBoundResp
	code, reason, err := g.postJSONReason("/cap", capBoundReq{Ref: ref, Profile: profile, Prior: cleanPrior(profile, prior), Bound: true}, &c)
	if err != nil {
		return "", nil, err
	}
	switch code {
	case http.StatusOK:
		if c.URL == "" {
			return "", nil, errors.New("gateway POST /cap: 200 with no url")
		}
		return c.URL, c.Headers, nil
	case http.StatusMethodNotAllowed: // a gateway that predates POST /cap
		u, err := g.writeCap(ref)
		return u, nil, err
	}
	if reason != "" {
		return "", nil, fmt.Errorf("gateway POST /cap: HTTP %d (%s)", code, reason)
	}
	return "", nil, fmt.Errorf("gateway POST /cap: HTTP %d", code)
}

type capsResp struct {
	Caps       map[string]string `json:"caps"`
	TTLSeconds int64             `json:"ttl_seconds"`
}

// readCaps is the BATCH of readCap: one POST returns free presigned GET URLs for many refs (+ their shared
// lifetime), so a restore prefetches all its chunk caps in a handful of round-trips instead of one per chunk
// (#71 step 2). An old gateway without /caps returns non-200 -> the caller falls back to per-chunk readCap.
func (g *gatewayClient) readCaps(refs []string) (map[string]string, int64, error) {
	var c capsResp
	code, err := g.postJSON("/caps", map[string]any{"op": "read", "refs": refs}, &c)
	if err != nil {
		return nil, 0, err
	}
	if code != http.StatusOK {
		return nil, 0, fmt.Errorf("/caps: HTTP %d", code) // e.g. 404 on an old gateway -> caller falls back per-chunk
	}
	return c.Caps, c.TTLSeconds, nil
}

var errInsufficientCredit = errors.New("billing: insufficient credit in wallet")

// creditRefusal is errInsufficientCredit carrying the gateway's own refusal text (NWP-20260904-09). It
// unwraps to errInsufficientCredit, so every errors.Is site -- the create/promote NOCREDIT replies, main's
// exitNoCredit mapping, the lease/pay-rent verbs -- fires exactly as before; what changes is that the error
// can now SAY which refusal it was, and creditReason can get that back out without parsing a message.
type creditRefusal struct{ reason string }

func (e *creditRefusal) Error() string {
	return errInsufficientCredit.Error() + " (gateway said: " + e.reason + ")"
}

func (e *creditRefusal) Unwrap() error { return errInsufficientCredit }

// creditRefused is the error for a gateway 402: errInsufficientCredit wrapped with the bounded reason, or the
// bare sentinel when the reply carried none (so nothing downstream ever renders an empty "gateway said").
func creditRefused(reason string) error {
	if reason == "" {
		return errInsufficientCredit
	}
	return &creditRefusal{reason: reason}
}

// creditReason returns the gateway reason carried by a creditRefused error, "" for any other error.
func creditReason(err error) string {
	var cr *creditRefusal
	if errors.As(err, &cr) {
		return cr.reason
	}
	return ""
}

// owedTokens computes how many tokens the gateway will charge for refs, mirroring its server-side math
// (ceil(total bytes / bytes-per-token), at least one). Lets the device present exactly what's owed.
func owedTokens(q quoteInfo, refs map[string]int64) int {
	var total int64
	for _, sz := range refs {
		if sz > 0 {
			total += sz
		}
	}
	per := q.GBPerToken * giB
	if per <= 0 {
		per = giB
	}
	owed := int(math.Ceil(float64(total) / float64(per)))
	if owed == 0 {
		owed = 1 // any data kept alive costs at least one token
	}
	return owed
}

// installHeadroom decides whether adding addBytes of new app data keeps the profile within its storage plan,
// mirroring the gateway's capacity math (#133): covered = free + LIVE entitled; a footprint past covered owes
// ceil(excess/GB) tokens, and the install fits only if the wallet holds that many. Returns fits, the token
// SHORTFALL (0 when it fits), and current used + covered bytes (for the over-plan message). FAIL-OPEN: a gateway
// or footprint error (old-gateway 404, a 503 on a failed grants read, offline, unreadable profile) returns
// fits=true, so a transient hiccup never bricks installs. ⚠ There is no hard backstop behind this: the gateway
// never refuses a seal for being over plan, so for the length of the failure adds are unbounded (see entitlement
// above). Callers skip the gate entirely when GATEWAY_URL is unset (an unmanaged device has no plan to enforce).
//
// ⚠ THE ONE ADD GATE (Q082, FREE-1, decided 2026-10-20). It has two callers: the store install (catalog.go
// handleFetchApp) and the Keep switch (keep_headroom.go keepHeadroomReply, KEEP-HEADROOM, Q025 [BA], decided
// 2026-10-20: turning on Keep counts the app's own size). Nothing else on the device brings in bytes the store
// does not already hold for this profile. MATERIALIZE-APP is not an add: restoreAppCode fetches only the Deferred entries of the profile's own
// name#apps head, which addCDCChunks already counts in `used` (TestFootprintCountsDeferredChunks), so it
// copies held bytes to the device and the store total does not move. On-demand media pins are not an add for
// the same reason. There is no on-device media import verb (SEED-MEDIA was withdrawn on 2026-10-18; GET-INGEST
// serves files that already arrived in #media). A seal and a DELETE are never gated. `used` is every scope
// together, and the phone is the only party that knows that total: the gateway is asked about the bare ref
// alone and stays per scope ref. It is measured against coverage(), not EntitledBytes: on a lapse entitled is 0
// and covered falls back to free, which is read-only mode. Pinned by admission_gate_test.go.
func installHeadroom(g *gatewayClient, base, name, pass, walletPath string, addBytes int64, se []byte) (fits bool, shortBytes, usedBytes, coveredBytes int64) {
	ent, _, err := g.entitlement(profileRefV2(name, pass))
	if err != nil {
		return true, 0, 0, 0 // fail-open (old gateway / offline)
	}
	// NWP-20261117-14: a store read in the footprint that fails in transport raises errStoreUnreachable. Here that
	// is "a footprint error", so it fails OPEN like the gateway error above, and never escapes as a handler panic.
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[agent] install headroom: the footprint read failed, failing open: %s\n",
				logSafeStoreErr("footprint", recoveredErr("footprint", r)))
			fits, shortBytes, usedBytes, coveredBytes = true, 0, 0, 0
		}
	}()
	refs, measured := profileFootprint(base, name, pass, se)
	if refs == nil || !measured {
		// Fail OPEN, as before -- but now also for the case that used to fail SILENTLY WRONG. An unopenable
		// scope made `used` a few kilobytes, so the headroom check passed for an install that does not fit,
		// and the user met the refusal later at a seal instead of here.
		return true, 0, 0, 0 // can't project -> let the lease decide
	}
	var used int64
	for _, sz := range refs {
		if sz > 0 {
			used += sz
		}
	}
	covered := ent.coverage()
	short := headroomShortBytes(used, addBytes, covered)
	return short == 0, short, used, covered
}

// coverage is the profile's admission ceiling. Prefers the gateway's own covered_bytes; falls back to
// max(free, entitled) and NEVER to free+entitled, which is the bug this replaces: adding them allowed a
// whole extra free tier, so on a 10 GB plan the gate admitted 11 GiB and reported no shortfall while the
// gateway already considered the profile full at 10.
func (e entitlementInfo) coverage() int64 {
	if e.CoveredBytes > 0 {
		return e.CoveredBytes
	}
	if e.EntitledBytes > e.FreeBytes {
		return e.EntitledBytes
	}
	return e.FreeBytes
}

// headroomShortBytes is the pure gate decision: how many BYTES over the plan `used+add` would put the
// profile. 0 = it fits.
//
// A SIZE check, not a token check. It used to ask "does the wallet hold enough tokens for the excess",
// which is meaningless now that a plan is a service period: the wallet is EMPTY by design once a term is
// activated, so the old arithmetic degenerated to a size check by accident when the balance was 0 -- and
// was actively wrong when it was not. A wallet holding an unactivated plan (tokens present, still inside
// the activation jitter window) subtracted credit that will never be spent as coverage, masking a genuine
// over-plan and admitting the install anyway.
//
// The remedy the number implies also changed: it is delete-or-upsize, not buy-more-tokens. So the answer
// is bytes, in the same unit as everything else on the ERR-OVERPLAN line.
func headroomShortBytes(usedBytes, addBytes, coveredBytes int64) int64 {
	if over := usedBytes + addBytes - coveredBytes; over > 0 {
		return over
	}
	return 0
}

// entitlementLine backs the GET-ENTITLEMENT verb: a single local+gateway read of the profile's storage coverage
// for the app store's headroom header (and to enrich the Storage screen). used = the device's authoritative
// footprint (same figure GET-USAGE reports); free/entitled from the gateway; credit = spendable GB-month tokens.
// ⚠ TWO DIFFERENT ANSWERS, AND COLLAPSING THEM IS NWP-20260918-02 (fixed here).
//
//	"NONE"    -- there is genuinely no plan to report. Only handleGetEntitlement emits it, for an UNMANAGED
//	             device (GATEWAY_URL empty: its `if gw == ""` arm in main.go): no gateway means no billing at all.
//	"UNKNOWN" -- a gateway IS configured and we could not get an answer out of it, or we could not measure
//	             our own footprint. We do not know, and must not guess.
//
// A gateway that ANSWERS and holds no entitlement never reaches either: it returns "OK ... entitled=0", and
// the parsed path renders that state with its own carefully-chosen wording. So every arm below means "could
// not determine" and NOTHING below means "this profile is on the free tier".
//
// That mattered on device: the chooser's early return turned any non-OK reply into "On the free tier -- this
// profile roams within the free allowance, at no cost", so a brief network failure told a customer holding a
// live 50 GiB plan that they had none and invited them to buy one. The sibling `entitled` parameter in that
// same file already carries the rule this violated -- "-1 IS NOT 0, AND THE DIFFERENCE IS THE WHOLE POINT".
//
// ⚠ An OLDER chooser takes its `!startsWith("OK")` branch on "UNKNOWN" exactly as it did on "NONE", so this
// is safe to ship ahead of the chooser: old builds keep today's behaviour, they do not break.
func entitlementLine(g *gatewayClient, base, name, pass, walletPath string, se []byte) string {
	ent, _, err := g.entitlement(profileRefV2(name, pass))
	if err != nil {
		return "UNKNOWN\n" // the gateway is configured but did not answer -- not evidence of anything
	}
	var used int64
	fp, measured := profileFootprint(base, name, pass, se)
	if !measured {
		// A scope resolved to a vault no keyslot opened. `used` would be a few KB for a multi-GB profile,
		// so the honest answer is that we could not measure -- never a small number rendered as fact.
		return "UNKNOWN\n"
	}
	for _, sz := range fp {
		if sz > 0 {
			used += sz
		}
	}
	// credit goes through the SAME shim as GET-BILLING. Sending the raw balance here while GET-BILLING
	// sent remaining plan GB-months put two screens built from one wallet in contradiction: the store
	// header dropped its credit clause entirely (it is guarded on credit > 0) while the Storage screen
	// still read "Credit left: 30 GB-months".
	credit := 0
	if w, werr := loadWallet(walletPath); werr == nil {
		credit = displayCredit(w, nowEpoch())
	}
	return fmt.Sprintf("OK used=%d free=%d entitled=%d covered=%d credit=%d gbpertoken=%d\n",
		used, ent.FreeBytes, ent.EntitledBytes, ent.coverage(), credit, ent.GBPerToken)
}

// leaseRefs pays rent to keep refs alive: quote -> offer up to the owed estimate from the wallet
// (zero-knowledge first, faucet to top up) -> redeem -> persist the reduced wallet. With a profile it
// takes the CAPACITY path (#133): the gateway pools purchased GB per profile for the window and charges
// only the excess over free + entitled -- so the offer is capped at the wallet balance rather than
// refused outright (the actual charge is usually far below the estimate, often zero). The wallet on disk
// is only mutated on a successful redemption; a network/HTTP/402 failure leaves it untouched.
// ⚠ THE bool IS "DID THIS LEASE ACTUALLY BUY ANYTHING", and payRent needs it for the same reason capFlush
// does (NWP-20260906-03): recordCoverage assigns PaidThrough from ANY 200, and the 409 arm below
// WITHDRAWS the purchase and re-leases with buy_gb=0. Without the signal, a lease that bought nothing
// writes a live term -- and payRent passes full=true, which also authorises writing the DELETION date.
// capFlush has carried this guard since -03; payRent never got it, and NWP-20260915-12 is what makes
// payRent reachable on the profiles that matter most.
// prior is leaseReq.Prior (NWP-20261009-02): the billing keys these refs' rows may still be tagged with.
func leaseRefs(g *gatewayClient, walletPath, profile string, refs map[string]int64, prior []string) (leaseInfo, bool, error) {
	info, bought, _, _, err := leaseRefsGen(g, walletPath, walletGeneration(walletPath), profile, refs, prior)
	if errors.Is(err, errNoWalletFile) {
		return info, bought, nil // renewed; nothing to save (NWP-20261010-04)
	}
	return info, bought, err
}

// leaseRefsGen is leaseRefs for a caller that knows which generation of the wallet it is paying from (payRent,
// from the session it read; NWP-20261010-04). It also returns the wallet it saved, for the caller's own record, and
// whether gen's restore proof stood when that wallet was LOADED (NWP-20261013-20, pass 5): read under the wallet
// lock with the load, it is what a by-value publish of this wallet is judged by. A proof that lands later vouches
// for copies taken after it, never for this one.
//
// A wallet already at another generation when the lock is taken is refused before anything is presented
// (errWalletChangedHands: the session is over, and this is somebody else's credit). One that changes hands
// DURING the lease is not saved -- the file is the arriving profile's -- and the post-settle wallet comes back
// in a *walletReplaced, so the caller can publish the spend to its own profile's head.
func leaseRefsGen(g *gatewayClient, walletPath, gen, profile string, refs map[string]int64, prior []string) (leaseInfo, bool, *Wallet, bool, error) {
	q, err := g.quote()
	if err != nil {
		return leaseInfo{}, false, nil, false, err
	}
	// NWP-20261010-04: load, spend, lease, save under the wallet lock -- a flush in this process or in the seal
	// worker does the same to the same file, and whichever saved second used to erase the other's spend. Held
	// to the end of the function: nothing after the save below takes a bracket.
	unlock := lockWallet(walletPath)
	defer unlock()
	if walletGeneration(walletPath) != gen {
		return leaseInfo{}, false, nil, false, errWalletChangedHands
	}
	// NWP-20261010-04: A MISSING FILE IS NOT AN EMPTY WALLET. loadWallet answers {} for it, and saving or
	// publishing that {} replaces the profile's durable wallet with no tokens (walletForPublish merges the plan
	// facts, never the tokens). The lease still runs -- renewal keeps the footprint alive, and from {} it can
	// present nothing -- but nothing is saved, and the caller publishes nothing (errNoWalletFile).
	_, statErr := os.Stat(walletPath)
	missing := os.IsNotExist(statErr)
	w, err := loadWallet(walletPath)
	if err != nil {
		return leaseInfo{}, false, nil, false, err
	}
	proven := walletRestoreLanded(walletPath, gen) // NWP-20261013-20: with the copy, under the lock
	info, err := leaseRefsLocked(g, q, w, profile, refs, prior)
	if err != nil {
		return leaseInfo{}, false, nil, false, err
	}
	if missing {
		return info, leaseBoughtCoverage(info), nil, false, errNoWalletFile
	}
	// ⚠ THE CHECK IS THE LAST THING BEFORE THE SAVE, AND NOTHING SLOW SITS BETWEEN THEM: removeWallet relies on
	// that to call a timed-out wait safe (THE GENERATION, wallet_lock.go).
	if walletGeneration(walletPath) != gen {
		fmt.Fprintf(os.Stderr, "[agent] lease: the wallet changed hands during the lease -- not saved here; "+
			"the caller publishes the spend to its own head (NWP-20261010-04)\n")
		return info, leaseBoughtCoverage(info), w, proven, &walletReplaced{w: w}
	}
	if err := saveWallet(walletPath, w); err != nil {
		return info, false, nil, false, fmt.Errorf("lease ok but wallet save failed: %w", err)
	}
	return info, leaseBoughtCoverage(info), w, proven, nil
}

// leaseBatchRefs is how many refs one renewal /lease carries (Q090, docs/product-decisions.md, 2026-10-20): a
// quarter of the 65,536-ref bound the backlog row names, so the gateway can bound a body without refusing the
// largest profile's renewal. A var so tests can shrink it.
var leaseBatchRefs = 16384

// leaseBatches splits refs into consecutive batches of at most n refs in sorted key order, so the split is the
// same on a retry while the footprint is unchanged. Every ref is in exactly one batch; one batch (the map itself)
// when len(refs) <= n or n <= 0.
func leaseBatches(refs map[string]int64, n int) []map[string]int64 {
	if n <= 0 || len(refs) <= n {
		return []map[string]int64{refs}
	}
	keys := make([]string, 0, len(refs))
	for k := range refs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]map[string]int64, 0, (len(keys)+n-1)/n)
	for len(keys) > 0 {
		m := n
		if m > len(keys) {
			m = len(keys)
		}
		b := make(map[string]int64, m)
		for _, k := range keys[:m] {
			b[k] = refs[k]
		}
		out = append(out, b)
		keys = keys[m:]
	}
	return out
}

// leaseRefsLocked is leaseRefs' purchase, lease and settlement against w, which the caller loaded under the wallet
// lock and saves afterwards. On an error w must not be saved (the presented tokens are still taken out of it).
func leaseRefsLocked(g *gatewayClient, q quoteInfo, w *Wallet, profile string, refs map[string]int64, prior []string) (leaseInfo, error) {
	var err error
	offer := owedTokens(q, refs)
	var info leaseInfo
	var code int
	if profile != "" {
		// BUY THE PLAN, or buy nothing. Storing more inside a live term is not a chargeable event, so the
		// ordinary seal presents no signatures at all -- which also keeps the wallet off the wire on every
		// lease, and with it the count that carries the plan size.
		//
		// Q090: THE RENEWAL GOES IN BATCHES OF leaseBatchRefs, so no single body carries a million refs. The
		// purchase rides batch 0 only and is JUDGED ON THE WHOLE MAP: `incoming` and planPurchase see every ref
		// the renewal leases, so a profile over the allowance whose first batch is under it is not held in the
		// activation jitter while its data is at risk. Only this device-side judgment is guaranteed to see the
		// whole footprint: the gateway's total is ProfileLiveBytes (rows with through_epoch >= now, excluding the
		// request's own refs) + the request's bytes, so for a profile whose other rows have lapsed each batch is
		// judged on less than the whole.
		batches := leaseBatches(refs, leaseBatchRefs)
		var incoming int64
		for _, sz := range refs {
			incoming += sz
		}
		buyGB, periods, plain, blind := w.planPurchase(q.CurrentEpoch, incoming > q.FreeGB<<30)
		info, code, err = g.leaseEntitled(profile, plain, blind, batches[0], periods, buyGB, w.planChange(), prior)
		if err != nil {
			return leaseInfo{}, err
		}
		// NO short-term fallback. The previous shape retried for ONE period when the full term came back
		// 402, on the theory that partial coverage beats none. Under a service period that is buying a
		// twelfth of what was paid for and forfeiting the rest -- the accrual the model forbids. A plan the
		// wallet cannot fund is simply not activated (planPurchase declines and keeps the tokens), so a 402
		// here means genuinely unfunded, not under-funded.
		if code == http.StatusPaymentRequired {
			return leaseInfo{}, creditRefused(info.Reason)
		}
		// NWP-20260906-03: payRent's twin of the capFlush 409 arm -- same cause, different consequence.
		// This path does not wedge the seal (maybePayRent recovers and logs), but returning here leaves the
		// WHOLE-FOOTPRINT RENEWAL permanently stopped, and that renewal is the only thing keeping cold refs
		// off their deadlines. Withdraw the purchase and renew without buying; the tokens are kept, except the ones a
		// 409 that names its spent nonces retires (NWP-20261020-03).
		if code == http.StatusConflict {
			keepPlain, keepBlind, dead := dropNamedSpent(plain, blind, info.SpentNonces)
			if dead > 0 {
				fmt.Fprintf(os.Stderr, "[agent] lease: gateway named %d of %d presented token(s) already spent -- retired them; keeping %d\n",
					dead, len(plain)+len(blind), len(keepPlain)+len(keepBlind))
			}
			w.settlePayment(keepPlain, keepBlind, 0)
			plain, blind = nil, nil
			info, code, err = g.leaseEntitled(profile, nil, nil, batches[0], periods, 0, "", prior)
			if err != nil {
				return leaseInfo{}, err
			}
		}
		if code != http.StatusOK {
			return leaseInfo{}, fmt.Errorf("lease: HTTP %d", code)
		}
		w.settlePayment(plain, blind, info.Spent)
		if buyGB > 0 && info.Spent > 0 {
			w.ActivateAfter = 0 // the plan is live; the jitter gate has done its job
		}
		if buyGB > 0 && info.Spent >= buyGB*int(periods) {
			w.planActivated() // the purchase landed: the next queued one is the plan now, behind a fresh jitter
		}
		// Q090: the later batches present NO tokens and buy nothing: batch 0's 200 settled the purchase, so these
		// are in-term leases like a seal's. They carry the same periods (the gateway sizes the term from it) and
		// the same `prior`: the gateway re-tags only the rows a request names (ledger.Holder) and refuses one
		// that touches a row tagged with a key it does not name, so a batch without `prior` would leave its rows
		// on the old key. A failed later batch is counted and the loop CONTINUES: each batch is independent on
		// the gateway, and its refs simply keep their old deadline until the next renewal.
		for _, b := range batches[1:] {
			bi, bcode, berr := g.leaseEntitled(profile, nil, nil, b, periods, 0, "", prior)
			if berr != nil || bcode != http.StatusOK {
				info.BatchesShort++
				continue
			}
			if len(bi.WriteCaps) > 0 {
				if info.WriteCaps == nil {
					info.WriteCaps = map[string]string{}
				}
				for k, v := range bi.WriteCaps {
					info.WriteCaps[k] = v
				}
			}
			if len(bi.CapHeaders) > 0 {
				if info.CapHeaders == nil {
					info.CapHeaders = map[string]map[string]string{}
				}
				for k, v := range bi.CapHeaders {
					info.CapHeaders[k] = v
				}
			}
			info.Present = append(info.Present, bi.Present...)
			// The collector's date: the earliest is the safe direction, as recordLease says.
			if bi.DeadlineEpoch != 0 && (info.DeadlineEpoch == 0 || bi.DeadlineEpoch < info.DeadlineEpoch) {
				info.DeadlineEpoch = bi.DeadlineEpoch
			}
		}
	} else { // legacy profile-less path (throwaways)
		plain, blind, ok := w.choosePayment(offer)
		if !ok {
			return leaseInfo{}, errInsufficientCredit
		}
		info, code, err = g.lease(plain, blind, refs)
		if err != nil {
			return leaseInfo{}, err
		}
		if code != http.StatusOK {
			return leaseInfo{}, fmt.Errorf("lease: HTTP %d", code)
		}
		// Delta-lease (DIA-20260627): the gateway may spend FEWER tokens than presented. It consumes the
		// first info.Spent of (plain ++ blind); settlePayment returns the rest.
		w.settlePayment(plain, blind, info.Spent)
	}
	// ⚠ A TERM COMES FROM A GRANT, NEVER FROM PERMISSION TO WRITE (NWP-20260915-26).
	//
	// "No 409" is what shipped, and it was not the same as "bought". The withdrawal latch catches only a
	// spent nonce. A lease that bought NOTHING -- planPurchase declining from an empty wallet, a plan
	// held inside its activation jitter, a profile that never bought anything -- returned "bought" too,
	// and the gateway answers such a lease with a rolling one-epoch GRACE term. Recording that made a
	// lapsed plan read as a live one with a day left, and then, once the Storage screen learned to
	// notice the gateway disagreeing (-19), as "our servers do not show this plan" -- blaming us for the
	// customer’s own lapse and replacing their renewal prompt with an inert support prompt.
	//
	// ⚠ AND buyGB > 0 IS NOT THE FIX EITHER, though it was the obvious one. It is the DEVICE’S
	// DECLARATION, and gateway paths answer a declared purchase with 200 / through = now+1 /
	// Spent = 0 having bought nothing: a failed ledger read (the grants, or the live bytes with the
	// tokens short -- since nowhere-cloud NWC-20261010-02; before it, ANY live-bytes read error
	// grace-leased ahead of buy_gb), and a declaration whose signatures do not verify. The second is
	// reachable in the field, not in theory -- collectTokens silently skips a token that fails Verify,
	// so a wallet holding credit that expired unnoticed (the 365-day TokenTTL of tokens minted before
	// NWP-20261031-08, NWP-20260915-25) declares a purchase
	// the gateway cannot back and is grace-leased. Keying on buyGB would have left -26 half-fixed.
	//
	// So BOTH limbs are the gateway’s own answer, the same way payRent’s free-vs-paid routing was fixed
	// to ask rather than infer (see noCredit above). leaseBoughtCoverage states them and scopes them.
	//
	// ⚠ info.Spent ALONE would be the mistake this comment used to warn about, and it still would be:
	// an entitled profile renewing inside a live term legitimately spends nothing, so a Spent-only test
	// withholds the term from every paying customer between purchases -- the display bug
	// NWP-20260829-06 fixed. That case is carried by the PlanGB limb, which is why the rule needs both.
	//
	// PlanGB can also be absent when a grant IS live (a ledger read that timed out reports an empty
	// entitlement rather than an error). Every such miss costs a WITHHELD term, never a false one, and
	// the field it protects is the only surviving evidence that a purchase happened: stale beats wrong.
	// The same is true of a gateway predating plan_gb (NWC-20260907-01) -- a real purchase still records
	// through Spent. The fielded fleet is not on one: the beta gateway binary carries the plan_gb tag.
	// ⚠ THE WITHDRAWAL LATCH IS GONE, AND THAT IS PART OF THIS FIX RATHER THAN A SEPARATE ONE.
	// NWP-20260906-03 added it when this gate was the bare `!boughtNothing` and it was doing the WHOLE
	// job of stopping a false term. leaseBoughtCoverage now does that job precisely, and -03’s own
	// tests stay green on it: a purchase that failed against a profile with NO live grant is answered
	// by grace, which names no plan and spends nothing, so nothing is recorded -- exactly what -03
	// asked for, reached by a rule that cannot be fooled by the shape of the reply.
	//
	// What the latch still did was SUPPRESS A TRUE TERM, permanently. The re-lease declares buy_gb=0,
	// so `owed` and therefore Spent are 0 by construction: the only limb it could ever veto was PlanGB,
	// which is positive only when the gateway holds a live grant -- and that reply carries
	// through = ent.LatestThrough(now), the customer’s real purchased term. And the 409 state does not
	// clear: on a 409 WITHOUT the spent list (an older gateway, or one whose read failed) settlePayment
	// returns every presented token to the wallet, nothing prunes a spent nonce,
	// and capFlush states the consequence in its own words -- "DETERMINISTIC -- re-presenting the same
	// nonces reproduces it exactly". So planPending stays true, every later lease re-declares and
	// re-409s, and the latch would withhold the term FOREVER: a customer holding 300 days reads
	// "Plan expired" and is routed to buy a plan they already own. That is NWP-20260829-06 again,
	// through the one door still open to it.
	//
	// It is retired HERE rather than filed because it is a conjunct of the very expression this slice
	// rewrites: leaving a provably harmful term in it would be shipping a known defect to keep a diff
	// tidy.
	//
	// A 409 that names its spent nonces now retires them (NWP-20261020-03), which ends the re-declare loop
	// above; a 409 without the list keeps every token, advertises it as spendable and re-presents it every
	// seal, so the loop still holds for that gateway (NWP-20260915-27).
	return info, nil // the caller returns leaseBoughtCoverage(info) as "bought"; the comment above is why
}

// profileFootprint returns the refs a profile must keep leased -- its (vault) head, the CDC manifest blob, and
// every chunk -- each with its stored size (the gateway leases per ref by size). Handles the vault head
// (current) and the legacy bare-manifest head. Defensive: an unopenable/odd head leases just what it can.
// (DIA-20260626-B; was the stale item-Manifest model.) A store read that fails in transport is NOT skipped: the
// head reads and, since NWP-20261117-14, the manifest reads raise errStoreUnreachable (NWP-20260903-01).
// scopeFootprint adds the store object keys for ONE sealed scope's data into refs -- the mutable head pointer
// (ref/<headkey>, nominal size 0 so it gets a write cap in cap mode), the head blob, the LIVE manifest's
// chunks, and the #58 retained-snapshot chunks. Lease the OBJECT KEYS the device reads/writes and the gateway
// presigns/GCs (blob/<hash>, ref/<name>) -- NOT bare hashes (a bare-hash lease never matched the device's
// blob/<hash> objects, so the gateway GC couldn't find them). A scope with no head yet (a sibling scope
// lazy-creates on its FIRST seal) is a no-op. refs is content-addressed, so chunks shared across scopes or
// versions collapse.
// ⚠ THE se ARGUMENT IS WHY NWP-20260915-12 IS NOT A ONE-LINE FIX, and fixing resolveDK without it would
// have been WORSE THAN FIXING NOTHING. This function opens the vault INDEPENDENTLY, and on nil it returns
// having added only the head refs. So a payRent that could open the profile but could not open it HERE
// would sail past its own gate, lease the heads alone, and re-stamp their deadlines as a successful
// renewal -- while every chunk aged out underneath them. The comment two lines down already says what
// happens then, for the 2FA case: "else the GC reaps a 2FA profile's chunks".
//
// It matters on a SCOPE head too, since NWP-20261007-11: a tie re-keys a scope into a vault with only an
// `se` slot (scope_tie.go), which this function opens through `se` and nothing else -- so a payRent
// without the session's se would lease such a scope's head and none of its chunks. Untied scopes are bare
// manifests, or a re-pointed vault with a single `pass` slot (buildScopeVault).
// ⚠ THE bool IS "I FOUND A VAULT I COULD NOT OPEN" (NWP-20260915-15), and it is NOT the same as
// "this scope is empty". A scope with no head yet is legitimately zero and returns false; a scope
// whose head resolved, parsed as a vault, and opened by NO keyslot is a MEASUREMENT FAILURE, and
// every caller that renders a number needs to tell those apart. Before this they could not: the
// function added the head refs and returned, so the Storage screen summed a few KB across six scopes
// and showed ~0 GB for a multi-GB profile -- at the moment a user is deciding whether to pay.
// A store read that fails in transport is neither: it raises errStoreUnreachable, the head reads and the
// manifest reads alike (NWP-20261117-14). A head the store refuses -- a 403, even on a fresh cap -- raises
// errStoreUnreachable like a transport failure, never "scope not sealed yet" (h48 #10, NWP-20261118-02). So
// blind=true still means only "a vault no keyslot opened".
func scopeFootprint(base, scope, pass string, se []byte, refs map[string]int64) (blind bool) {
	return scopeFootprintRec(base, scope, pass, se, nil, refs)
}

// scopeFootprintRec is scopeFootprint with the 12-word recovery code's ENTROPY threaded in, so a HARDENED
// vault can be enumerated without the secure element.
//
// NWP-20260918-10. Every Endospore profile is hardened at create, which DROPS the pass slots -- so
// openVaultDKSE (pass -> se -> seDK -> fido2) cannot open one from anywhere but the handset that holds the
// SE. But profile-export-restore.md section 5 requires the profile be LOGGED OFF during an export, and
// seFromSession has no session to read. The two requirements are individually correct and jointly made a
// complete footprint of a hardened profile impossible: measured on odtest56, the CLI produced 53 objects
// where the daemon produced 65 -- 12 blobs and 744,067 B, 22.3% of the profile, silently absent.
//
// The doc already named the way out (section 4): the recovery code reaches the VAULT where the passphrase
// cannot, and doing so is a CLIENT-SIDE READ -- recoveryRef -> head -> kekRecovery -> DK -- with no store
// write and no credential change. That is emphatically NOT recoverVault, which is the WRITE path: it resets
// the passphrase and leaves an Endospore profile de-hardened until it re-enrols. Enumerating must cost the
// caller nothing.
//
// ⚠ BOTH CREDENTIALS ARE STILL REQUIRED, which is the doc's own rule and not an inconvenience to design
// around: the recovery code reaches the bare vault but NO scope, because the five scope heads are located
// AND keyed by the passphrase (deriveKey(name#scope, pass)). A caller holding only the code would enumerate
// the vault and silently miss every scope -- the same short-list failure in a new costume.
func scopeFootprintRec(base, scope, pass string, se, recEntropy []byte, refs map[string]int64) (blind bool) {
	hk, head := footprintHeadStrict(base, scope, pass) // #80: the live head key (v2 if migrated, else legacy), read strictly
	if head == "" {
		return // scope not sealed yet
	}
	hblob := getHeadBlob(base, head)
	refs["blob/"+head] = int64(len(hblob))
	refs["ref/"+hk] = 0
	if v, isV := parseVault(hblob); isV {
		// NWP-20260905-06: THE RECOVERY REF -- a second pointer at this same head, and on a HARDENED
		// (Endospore E.3b) vault the only key that opens this profile off this handset.
		//
		// The push path maintains it on every seal with exactly this guard (pushProfile's `if v.RecoveryRef != ""` putRef, main.go), so leaving it
		// out here means the WRITER and the ENUMERATOR disagree about what a profile is. Two consequences,
		// both silent:
		//   lease/GC -- an un-leased ref is precisely what the #media/#de/#apps/#keys notes in
		//               profileFootprint exist to prevent. A reaped recovery ref does not look like data
		//               loss: the profile still opens on THIS phone through its `se` slot, and the 12-word
		//               code just stops working, with nothing to say why.
		//   copy     -- a footprint-driven copy of a hardened profile otherwise carries NEITHER of its two
		//               keys. recoverVault resolves the code by getRef(base, recoveryRef(name, entropy))
		//               (recoverVault, main.go); absent at the destination that returns "no profile for that name
		//               + phrase", which is indistinguishable from a wrong code.
		// Size 0 like the head ref above: a ref is a pointer, and the blob it names is already counted.
		if v.RecoveryRef != "" {
			refs["ref/"+v.RecoveryRef] = 0
		}
		dk := openVaultDKSE(v, scope, pass, se) // pass -> secure element -> fido2 (#81); a hardened or 2FA head
		if dk == nil && len(recEntropy) > 0 {
			// NWP-20260918-10: the RECOVERY rung, tried only after every other slot has failed and only
			// when the caller supplied the code. On a hardened vault this is the sole rung that can open
			// from off-handset, and it is a pure read -- kekRecovery derives a KEK, unwrapDK unwraps the
			// existing slot, nothing is minted and nothing is published.
			//
			// ⚠ `scope` IS THE BARE NAME HERE OR NOTHING WORKS. kekRecovery and recoveryRef are keyed on
			// (name, entropy) with no scope suffix, so this rung is meaningful only for the bare vault --
			// which is correct, because it is the only head that has a recovery slot. On a scope head
			// unwrapDK simply finds no such slot and returns nil, leaving `blind` true exactly as before.
			dk = unwrapDK(v, "recovery", kekRecovery(scope, recEntropy))
		}
		if dk == nil { // must lease its FULL footprint, else the GC reaps its chunks
			return true // a vault we cannot open: the head is leased, the chunks are NOT, and we say so
		}
		if v.Manifest == "" {
			return false // opened, and genuinely nothing sealed under it yet
		}
		addManifestChunks(base, dk, v.Manifest, refs) // the LIVE head's chunks
		// #58: also lease the last-K retained snapshots' chunks (+ each snapshot manifest blob), so a rollback
		// target's data survives the store GC. Content-addressed, so chunks shared with the live head collapse.
		for _, sn := range v.History {
			addManifestChunks(base, dk, sn.Manifest, refs)
		}
		// NWP-20261008-03: a background re-key in flight names chunks no head names yet. Without this the GC reaps
		// work done across sessions before the switch, and the switched head would name chunks that are gone.
		if !strings.Contains(scope, "#") {
			addRekeyProgress(base, dk, v.Scopes, refs)
		}
		return
	}
	// legacy: the head blob IS the sealed manifest (pre-vault; no snapshot history)
	func() {
		defer footprintSkip() // a bad/legacy manifest is skipped; a transport failure is raised (NWP-20261117-14)
		addCDCChunks(base, unseal(deriveKey(scope, pass), hblob), refs)
	}()
	// A legacy bare head opens by passphrase alone and has no keyslots to fail, so reaching here is
	// never a measurement failure -- an unreadable one is caught by footprintSkip above and leaves
	// the chunks unadded, which the pre-vault shape has always done. A chunk size read that fails in
	// transport raises errStoreUnreachable like the head reads (NWP-20261117-14).
	return false
}

// profileFootprint is the full set of store object keys a profile's data occupies -- for GET-USAGE (sum the
// sizes) and payRent (the lease set that keeps them alive against the gateway GC). It spans ALL FIVE sealed
// scopes: the vault (name), device-encrypted app data (name#de), external offline media (name#media, e.g.
// OrganicMaps maps under /data/media), captured user-installed app CODE (name#apps, #199 -- the opted-in
// APK bytes), and carried Keystore blobs (name#keys, #210 p2). task_2cd90cd1: counting/leasing ONLY the vault undercounted GET-USAGE (a 72MB offline map read
// as ~1MB) AND left the #media/#de blobs un-leased, so the gateway GC reaped them = offline-media data-loss;
// the same un-leased-GC-reap trap applies to #apps (a kept app's bytes would vanish). A call already scoped to
// a sub-identity (name#media / name#apps / name#wallet) returns just that scope -- no further fan-out.
// The second return is MEASURED: false when any scope was found and could not be opened, so a caller
// rendering a number can say "not measured" instead of a confidently small one, and a caller writing
// a copy recipe can refuse to write an incomplete one. A profile with nothing sealed is measured and
// empty -- that is a real answer, not a failure. measured=false still means only "a vault no keyslot opened":
// a store read that fails in transport raises errStoreUnreachable instead (NWP-20261117-14), and so does a scope
// head the store refuses -- a 403, even on a fresh cap (h48 #10, NWP-20261118-02).
func profileFootprint(base, profile, pass string, se []byte) (map[string]int64, bool) {
	return profileFootprintRec(base, profile, pass, se, nil)
}

// profileFootprintRec is profileFootprint with the recovery code's ENTROPY available for the bare vault.
// nil entropy is exactly today's behaviour, which is why every existing caller keeps its signature.
//
// NWP-20260918-10: this is what makes a LOGGED-OFF HARDENED profile enumerable, and therefore what makes
// the export in profile-export-restore.md possible on the Endospore fleet at all -- every profile there is
// hardened at create, and section 5 requires the export run with no session.
//
// ⚠ THE ENTROPY REACHES ONLY THE BARE SCOPE, DELIBERATELY. The five scope heads are located AND keyed by
// deriveKey(name#scope, pass), so the passphrase already opens them and the recovery code never could --
// it is keyed on (name, entropy) with no scope suffix. Passing it to the fan-out below would be noise that
// reads like a fallback, and a reader would reasonably conclude the code alone suffices. It does not: a
// complete export needs BOTH credentials, which is section 4's rule and the reason this signature takes
// both rather than either.
func profileFootprintRec(base, profile, pass string, se, recEntropy []byte) (map[string]int64, bool) {
	refs := map[string]int64{}
	blind := scopeFootprintRec(base, profile, pass, se, recEntropy, refs)
	if len(refs) == 0 {
		return nil, !blind // unknown profile or wrong passphrase (no base head)
	}
	if !strings.Contains(profile, "#") {
		blind = scopeFootprint(base, profile+"#de", pass, se, refs) || blind
		// NWP-20260905-06: #sys -- accounts_ce.db / accounts_de.db, the Google account. Sealed on every
		// logoff (acct_seal's `push s3 "${name}#sys"`, nowhere_roamd.sh), prefetched on every login
		// (prefetchHeadBlobs' scope list, head_prefetch.go) and purged on delete (deleteScopeSuffixes,
		// main.go) -- a first-class scope by every other measure, and the
		// only one this fan-out omitted. The seal itself leases what it uploads, which is why nothing has
		// been lost yet; the exposure is the refs a seal does NOT re-upload (retained-snapshot chunks) and
		// any profile idle past its lease + grace. It also undercounted GET-USAGE by the account dbs.
		blind = scopeFootprint(base, profile+"#sys", pass, se, refs) || blind
		blind = scopeFootprint(base, profile+"#media", pass, se, refs) || blind
		blind = scopeFootprint(base, profile+"#apps", pass, se, refs) || blind // #199: captured user-installed APK bytes (app persistence)
		// #210 p2: carried Keystore blobs ("stay signed in to <app> on this device"). Listed here for exactly the
		// reason the comment above records for #media/#de/#apps -- an un-leased scope is REAPED by the gateway GC.
		// A reaped #keys head would not look like data loss, it would look like the feature quietly not working:
		// the app signs out again and nothing says why. Cheap to lease (the bundle is kilobytes).
		blind = scopeFootprint(base, profile+"#keys", pass, se, refs) || blind
	}
	return refs, !blind
}

// footprintSkip is the footprint's manifest-read recover. Use it only as `defer footprintSkip()`: recover() works
// only when the deferred function calls it directly. The walk's head reads already raise a store read that fails
// in transport; footprintSkip makes the manifest reads agree, so it panics errStoreUnreachable again unchanged
// (NWP-20260903-01: a transport error must never read as "nothing stored"; NWP-20261117-14). Any other value -- an
// absent blob, a manifest that does not unseal or parse -- is swallowed, so one broken snapshot cannot fail every
// renewal.
func footprintSkip() {
	r := recover()
	if err, ok := r.(error); ok && errors.Is(err, errStoreUnreachable) {
		panic(r)
	}
}

// footprintHeadStrict resolves a scope's head and its value with ONE strict walk of the head ladder (refProbeStrict,
// as appsHeadAbsent and readStoredWalletStrict do), so a head the store refuses -- a 403, even on a fresh cap -- is a
// failed read, never "scope not sealed yet" (h48 #10, NWP-20261118-02; NWP-20260903-01). A definite not-found on
// every rung still returns head "". Every failure leaves it marked errStoreUnreachable: cap mode's capGetStrict
// already panics that way, and a plain-HTTP fail() is re-panicked as storeReadErr, so each reader of the footprint
// meets the failure it already handles for a transport cut. It wraps only the walk. Never a blind-login read: every
// caller of the footprint holds the session's credentials (export: both credentials).
func footprintHeadStrict(base, scope, pass string) (hk, head string) {
	defer func() {
		if r := recover(); r != nil {
			if err, ok := r.(error); ok && errors.Is(err, errStoreUnreachable) {
				panic(r)
			}
			panic(storeReadErr{fmt.Errorf("footprint: head of a scope refused: %v", r)})
		}
	}()
	hk, head, _ = headRefWith(base, scope, pass, refProbeStrict)
	return hk, head
}

// addManifestChunks fetches a sealed CDC manifest by hash, then leases the manifest blob + every chunk it
// references (keyed by object key -> size). Used for the live head and each retained snapshot (#58).
// Best-effort: a bad/legacy/unreadable manifest is skipped. A store read that fails in transport raises
// errStoreUnreachable like the head reads (footprintSkip, NWP-20261117-14).
func addManifestChunks(base string, dk []byte, manifestHash string, refs map[string]int64) {
	defer footprintSkip()
	if manifestHash == "" {
		return
	}
	mb := getBlob(base, manifestHash)
	refs["blob/"+manifestHash] = int64(len(mb))
	addCDCChunks(base, unseal(dk, mb), refs)
}

// addCDCChunks adds every chunk of a decrypted CDC manifest to refs. #85: prefer the per-chunk sizes carried
// in the manifest (local, instant); only a legacy pre-#85 manifest (no Sizes) falls back to blobSize -- which
// in cap mode DOWNLOADS each chunk.
func addCDCChunks(base string, pt []byte, refs map[string]int64) {
	if !bytes.HasPrefix(pt, cdcMagic) {
		return
	}
	var m chunkManifest
	if json.Unmarshal(pt[len(cdcMagic):], &m) != nil {
		return
	}
	haveSizes := len(m.Sizes) == len(m.Chunks)
	for i, ch := range m.Chunks {
		if ch == "" {
			continue
		}
		if haveSizes {
			refs["blob/"+ch] = m.Sizes[i]
		} else {
			refs["blob/"+ch] = blobSize(base, ch)
		}
	}
	// #84 P3d: DEFERRED chunks are part of the profile exactly like essential ones -- they must be leased or
	// the store GC reaps the media the daemon serves on-access. Sized from the record's Sz (the deferred twin
	// of Sizes, #85); only a pre-Sz record falls back to the per-chunk probe.
	for _, d := range m.Deferred {
		haveSz := len(d.Sz) == len(d.Chunks)
		for i, ch := range d.Chunks {
			if ch == "" {
				continue
			}
			if haveSz {
				refs["blob/"+ch] = d.Sz[i]
			} else {
				refs["blob/"+ch] = blobSize(base, ch)
			}
		}
	}
}

// ---- wallet roaming (DIA-20260627-B): the wallet seals/restores with the profile so the token balance
// survives the power-off wipe. It rides a distinct unguessable sub-ref (not the heavy data head), is
// fetched at login via a free read, and re-published whenever it changes. The store/gateway only ever
// hold ciphertext. ----

// walletHeadKey resolves where an identity's roaming wallet head CURRENTLY lives -- v2 if migrated, else the
// legacy sha256 ref. The wallet is a distinct unguessable sub-ref of the profile (name+"#wallet", bound to
// BOTH name and passphrase, so a wrong passphrase finds nothing: blind, like the data head); it's just another
// head for that sub-identity, so headKey/putHead handle its v2 migration + tombstoning for free. (#80)
func walletHeadKey(base, name, pass string) string { return headKey(base, name+"#wallet", pass) }

// resolveDK opens a profile's data key the way the footprint does: a vault head unwraps DK via the
// passphrase slot (or the device's secure-element slot for a hardened identity); a legacy bare head
// derives the key directly. Returns nil for an unknown profile or a wrong passphrase. The wallet seals
// under this same key, so it's reachable by exactly whoever can open the data.
// ⚠ se IS THE SECURE-ELEMENT SECRET, AND PASSING nil IS A REAL ANSWER, not a placeholder: it means "this
// caller has none", which is correct for the su:s0 worker and the CLI, where openVaultDKSE's env rung
// still fires because nowhere_roamd.sh exports NOWHERE_SE_SECRET there. It is NOT correct in the login
// daemon, whose environment never carries that variable -- see NWP-20260915-12.
func resolveDK(base, name, pass string, se []byte) []byte {
	dk, _ := resolveDKVault(base, name, pass, se)
	return dk
}

// resolveDKVault is resolveDK that also hands back the vault it opened -- nil for a legacy bare head and for
// no head at all (NWP-20261009-02). payRent needs the vault for its scope index, the !bill-retag record it
// sends as `prior`, and this call has the parsed vault in hand; a second openVaultHead would re-resolve the
// ref and re-fetch a blob just verified, the exact round trip NWP-20260917-24 removed from this path.
func resolveDKVault(base, name, pass string, se []byte) ([]byte, *vault) {
	// NWP-20260917-24: the FUSED probe and the head-blob cache, for the reasons openVaultHead states. This
	// runs on every login, and it used to resolve the ref twice (headKey discards the value headRef already
	// fetched) and fetch the blob past the cache the rest of the login path fills.
	//
	// ⚠ NOT openVaultHead itself: this function distinguishes THREE outcomes where that helper has two --
	// no head at all returns nil (there is nothing to open), while a head that is not a vault falls through
	// to deriveKey for a legacy profile. Collapsing those would hand a legacy DK to a profile that has no
	// head, so the shape stays and only the accessors change.
	ref, head, have := headRef(base, name, pass)
	if !have {
		head = getRef(base, ref)
	}
	if head == "" {
		return nil, nil
	}
	if v, isV := parseVault(headBlobGet(base, head)); isV {
		return openVaultDKSE(v, name, pass, se), v // pass -> secure element -> fido2 (#81)
	}
	return deriveKey(name, pass), nil
}

// sealWallet seals the wallet at walletPath under dk and publishes it, updating the wallet head ref. A
// missing walletPath (nothing minted yet) is a no-op. Returns the new head's content hash. The publish runs
// in a bracket of its own (NWP-20261029-02).
//
// NWP-20261128-22: the file is read under the wallet lock and published only at g0, the generation the entry check
// judged. The bracket wait is the window: a sign-in that lands while this waits for capBracketMu replaces the file
// with the ARRIVING profile's wallet and proves that generation, and a read after the wait published the arriving
// profile's bearer tokens at the departed profile's #wallet head (the hazard logout_wallet.go's header names). So
// the bytes, the generation and its proof are read together under the lock, as sealWalletDurable does, and a
// generation other than g0 is refused (errWalletChangedHands). Lock order: the bracket is ours, and the wallet lock
// is taken inside it and released before any store write.
func sealWallet(base, name, pass string, dk []byte, walletPath string) (string, error) {
	if capMode() {
		return "", nil // managed mode: the wallet rides the seal flush (capFlush fold), not a standalone write
	}
	g0 := walletGeneration(walletPath) // the generation judged here; the read below publishes only this one
	if walletNotRestored(walletPath, g0) {
		fmt.Fprintf(os.Stderr, "[agent] sealWallet: refused -- this generation has no wallet restore proof (its sign-in read did not land), so the local wallet could drop the stored tokens (NWP-20261013-20)\n")
		return "", errWalletNotRestored
	}
	var h string
	var err error
	// NWP-20261029-02: the publish runs in a bracket of its own. Outside one, the refusal its head write meets
	// (the fence, a stale head) sets sealFenceHit / the stale flag while some OTHER bracket is open, and that
	// bracket's capEnd reports it as its own verdict. The verdict is not consulted: callers are told what they
	// always were.
	capWrite(name, pass, dk, func() {
		// NWP-20261128-22: bounded by walletSignInWait and read either way, as sealWalletDurable does: the bytes
		// first, then the generation, so a bump between the two can only make the generation differ from g0 and
		// refuse, never publish another profile's bytes as this one's.
		unlock, _ := lockWalletWithin(walletPath, walletSignInWait)
		data, rerr := os.ReadFile(walletPath)
		gen := walletGeneration(walletPath)
		proven := walletRestoreLanded(walletPath, gen)
		unlock()
		if rerr != nil {
			if !os.IsNotExist(rerr) {
				err = rerr
			}
			return
		}
		if gen != g0 {
			fmt.Fprintf(os.Stderr, "[agent] sealWallet: refused -- the wallet changed hands while this publish waited (NWP-20261128-22)\n")
			err = errWalletChangedHands
			return
		}
		if !proven {
			fmt.Fprintf(os.Stderr, "[agent] sealWallet: refused -- the wallet it read has no restore proof for its generation (NWP-20261013-20)\n")
			err = errWalletNotRestored
			return
		}
		// NWP-20260907-12: the THIRD wallet publisher, and it needs the same merge as the other two. It is
		// the direct-store path rather than the fielded cap-mode one, which is exactly why it would have
		// been left behind -- the fleet does not exercise it, so nothing would have complained.
		// NWP-20261128-22: the local wallet is parsed from `data`, never re-read: a read after the unlock could be
		// the next profile's file.
		var local Wallet
		if json.Unmarshal(data, &local) == nil {
			if merged := walletForPublish(readStoredWallet(base, name, pass, dk), &local, walletSeen(walletPath, gen)); merged != nil {
				if mj, merr := json.Marshal(merged); merr == nil {
					data = mj
				}
			}
		}
		h = postBlob(base, seal(dk, data))
		putHead(base, name+"#wallet", pass, h) // #80: migrates a legacy wallet ref to v2 + tombstones the legacy
	})
	return h, err
}

// errStoredWalletUnreadable: the stored wallet could not be read, so the #wallet head was not written; the next save
// that can read it publishes the merge (dn-1031 #1).
var errStoredWalletUnreadable = errors.New("the stored wallet could not be read, so the #wallet head was not written; the next save that can read it publishes the merge (dn-1031 #1)")

// storedWalletForDurable is the stored copy a durable publisher merges. Not strict: readStoredWallet, which takes every
// failure for no copy. Strict: storedWalletForPublish's three answers, as the fold takes them -- the stored wallet; nil
// for a copy that is absent or damaged, so the local set publishes; errStoredWalletUnreadable for any other failure.
func storedWalletForDurable(strict bool, base, name, pass string, dk []byte) (*Wallet, error) {
	if !strict {
		return readStoredWallet(base, name, pass, dk), nil
	}
	w, readable := storedWalletForPublish(base, name, pass, dk)
	if !readable {
		return nil, errStoredWalletUnreadable
	}
	return w, nil
}

// sealWalletDurable publishes the wallet and does not return until the bytes have actually landed in the
// store. Use it wherever "saved" is about to be reported to a HUMAN; use sealWallet where the wallet is
// merely being kept in step with a flush that is already going to happen.
//
// DIA-20260806-20. sealWallet is a no-op in cap mode -- correct for its contract, and silently wrong for a
// caller asking "is this money safe yet?". handleClaim asked exactly that, got nil, and told the user their
// credit was durable when nothing had been written. This is the version that can answer honestly.
//
// ⚠ NWP-20261010-04: its #wallet head is left out (capFlush's putWalletHead) when another writer saved the
// wallet after this read it, and that is still reported as success: the later writer loaded this wallet under
// the lock, so what it publishes carries everything here -- payRent and a claim end in this function, and a
// flush folds. The exception is a writer that publishes nothing of its own (the dev `lease` CLI, a SCOPE
// flush that bought a plan); until the next fold or durable seal the store then keeps the head before both.
//
// In cap mode the write primitives REQUIRE a capBegin/capFlush bracket (postBlob fails loudly outside one),
// so this opens its own. capFlush panics via check() on a store error -- deliberate everywhere else, but
// here the whole point is to report failure rather than die, so it is recovered and turned into an error.
func sealWalletDurable(base, name, pass string, dk []byte, walletPath string) (h string, err error) {
	return sealWalletFilePublish(false, base, name, pass, dk, walletPath)
}

// sealWalletDurableStrict is sealWalletDurable for a publisher that may wait for a readable stored copy (dn-1031 #1,
// option (b)): while the stored wallet cannot be read it writes no #wallet head and answers errStoredWalletUnreadable.
// A claim publishes this way, and its tokens stay in the file for the next save that can read. Direct-store mode
// delegates to sealWallet, as sealWalletDurable does.
func sealWalletDurableStrict(base, name, pass string, dk []byte, walletPath string) (h string, err error) {
	return sealWalletFilePublish(true, base, name, pass, dk, walletPath)
}

// sealWalletFilePublish is the one body of sealWalletDurable and sealWalletDurableStrict; strict is how it reads the
// stored copy it merges (storedWalletForDurable).
func sealWalletFilePublish(strict bool, base, name, pass string, dk []byte, walletPath string) (h string, err error) {
	if !capMode() {
		return sealWallet(base, name, pass, dk, walletPath) // direct-store mode: already synchronous
	}
	// NWP-20261013-20: refused unless the current generation carries its restore proof (wallet_restore.go) -- a fast
	// refusal before the bracket. The one the copy is judged by is read under the lock below, with the copy (pass 5),
	// and putWalletHead asks again of the generation read there (the basis).
	if walletNotRestored(walletPath, walletGeneration(walletPath)) {
		fmt.Fprintf(os.Stderr, "[agent] sealWalletDurable: refused -- this generation has no wallet restore proof (its sign-in read did not land), so the local wallet could drop the stored tokens (NWP-20261013-20)\n")
		return "", errWalletNotRestored
	}
	if _, statErr := os.Stat(walletPath); statErr != nil {
		if os.IsNotExist(statErr) {
			return "", nil // nothing minted yet: nothing to lose
		}
		return "", statErr
	}
	defer func() {
		if r := recover(); r != nil {
			h, err = "", fmt.Errorf("cap flush failed: %v", r)
		}
	}()
	// NWP-20261009-07: and END it on a panic too. The recover above turns a store failure into an error, but
	// it never closed the bracket, which used to cost only a leaked spill file; now an open bracket holds
	// capBracketMu, and every later bracket in the daemon would wait on it for the rest of the boot.
	n := capBegin()
	defer capEndBracket(n)
	capSetSession(name, pass, dk)
	// NWP-20261010-04: read under the wallet lock and recorded as the head's basis, so capFlush publishes this
	// head only while the file still holds these bytes (putWalletHead). Lock order holds: the bracket is ours,
	// and the wallet lock is taken inside it, never the reverse.
	// ...bounded by walletSignInWait (a person is waiting on a claim) and read either way: the bytes first, then
	// the generation, so a bump between the two can only make putWalletHead compare and leave the head out, never
	// publish another profile's bytes as this one's.
	unlock, _ := lockWalletWithin(walletPath, walletSignInWait)
	data, rerr := os.ReadFile(walletPath)
	gen := walletGeneration(walletPath)
	proven := walletRestoreLanded(walletPath, gen) // NWP-20261013-20 (pass 5): the proof that stood with this copy
	unlock()
	if rerr != nil {
		capFlush(n) // close the bracket we opened; nothing was buffered
		return "", rerr
	}
	if !proven {
		// The generation moved on while this waited for the lock, to one with no proof yet (or its proof was
		// forfeited): the copy is not a wallet this session may publish, whatever that generation's proof says by the
		// time the head would be written.
		capFlush(n) // close the bracket we opened; nothing was buffered
		fmt.Fprintf(os.Stderr, "[agent] sealWalletDurable: refused -- the wallet it read has no restore proof for its generation (NWP-20261013-20)\n")
		return "", errWalletNotRestored
	}
	capSetWalletBasis(data, gen)
	// NWP-20260907-12: merge the account's monotonic facts forward before writing over them. This is
	// the money path, so the extra ref+blob read is affordable and the wallet blob is a few hundred
	// bytes; walletForPublish explains why a merge rather than a version compare.
	// NWP-20261010-04: the local wallet is parsed from `data`, not re-read -- the head must derive from its basis.
	var local Wallet
	if json.Unmarshal(data, &local) == nil {
		stored, serr := storedWalletForDurable(strict, base, name, pass, dk)
		if serr != nil {
			capFlush(n) // close the bracket we opened; nothing was buffered
			return "", serr
		}
		if merged := walletForPublish(stored, &local, walletSeen(walletPath, gen)); merged != nil {
			if mj, merr := json.Marshal(merged); merr == nil {
				data = mj
				// NWP-20261107-02: the fold merges against this while no fold of the flush has read the stored
				// copy, so a re-fold that cannot read still publishes the post-spend wallet, not this one.
				capSetPublisherCopy(merged)
			}
		}
	}
	h = postBlob(base, seal(dk, data))
	putHead(base, name+"#wallet", pass, h)
	capFlush(n) // the actual upload -- this is the line that makes the credit durable
	return h, nil
}

// sealWalletValueDurable is sealWalletDurable for a wallet held in MEMORY: it publishes w to (name, pass)'s
// #wallet head and does not return until it has landed (NWP-20261010-04). payRent publishes what it spent this
// way, through sealWalletValueDurableStrict, because by the time it publishes the file may be another profile's (THE
// GENERATION, wallet_lock.go); a successful create publishes its staged claim this way (finishStagedClaim).
//
// walletPath is the file w belongs to. basis and gen are the bytes and generation w was saved as at walletPath;
// basis is nil when it was NOT saved (the wallet
// changed hands). capFlush publishes the head only while the file still holds basis at gen -- a later writer
// of this session publishes its own -- or once the generation has moved on, when this is the departed
// session's last word (putWalletHead). The bracket runs walletNotOurs: its flush never reads, spends from or
// folds the file, which may belong to someone else.
//
// proven is whether gen's restore proof stood WHEN w WAS TAKEN, read by the caller under the wallet lock with its
// copy (NWP-20261013-20, pass 5). Without it nothing is published, in either mode, whatever gen's proof says by now:
// a proof vouches only for copies taken after it, and a retry that lands while this publish is on its way proves gen
// for a merged file that w predates -- w lacks the stored tokens, and once the generation has moved on nothing
// compares it with the file (a fix review reproduced it: stored 10 -> 1). gen's proof is asked again where the head
// is written (putWalletHead; here, direct): removeWallet forfeits a departed generation's proof it could not move on.
func sealWalletValueDurable(base, name, pass string, dk []byte, walletPath string, w *Wallet, basis []byte, gen string, proven bool) (h string, err error) {
	return sealWalletValuePublish(false, base, name, pass, dk, walletPath, w, basis, gen, proven)
}

// sealWalletValueDurableStrict is sealWalletValueDurable for a publisher that may wait for a readable stored copy
// (dn-1031 #1, option (b)): while the stored wallet cannot be read it writes no #wallet head, in either mode, and
// answers errStoredWalletUnreadable. payRent publishes its spend this way.
func sealWalletValueDurableStrict(base, name, pass string, dk []byte, walletPath string, w *Wallet, basis []byte, gen string, proven bool) (h string, err error) {
	return sealWalletValuePublish(true, base, name, pass, dk, walletPath, w, basis, gen, proven)
}

// sealWalletValuePublish is the one body of sealWalletValueDurable and sealWalletValueDurableStrict; strict is how it
// reads the stored copy it merges (storedWalletForDurable).
func sealWalletValuePublish(strict bool, base, name, pass string, dk []byte, walletPath string, w *Wallet, basis []byte, gen string, proven bool) (h string, err error) {
	if !proven {
		fmt.Fprintf(os.Stderr, "[agent] sealWalletValueDurable: refused -- this wallet was taken while its generation had "+
			"no wallet restore proof, so it could drop the stored tokens (NWP-20261013-20)\n")
		return "", errWalletNotRestored
	}
	defer func() {
		if r := recover(); r != nil {
			h, err = "", fmt.Errorf("wallet publish failed: %v", r)
		}
	}()
	data, err := json.Marshal(w)
	if err != nil {
		return "", err
	}
	// NWP-20260907-12: the account's monotonic facts merged forward, as every other wallet publisher does.
	stored, serr := storedWalletForDurable(strict, base, name, pass, dk)
	if serr != nil {
		return "", serr
	}
	if merged := walletForPublish(stored, w, walletSeen(walletPath, gen)); merged != nil {
		if mj, merr := json.Marshal(merged); merr == nil {
			data = mj
		}
	}
	if !capMode() {
		// NWP-20261013-20: gen must carry its restore proof -- judged by gen, the generation w was saved as, never the
		// file's current one. In cap mode putWalletHead asks the same of gen (the basis).
		if walletNotRestored(walletPath, gen) {
			fmt.Fprintf(os.Stderr, "[agent] sealWalletValueDurable: refused -- the session this wallet belongs to "+
				"has no wallet restore proof (NWP-20261013-20)\n")
			return "", errWalletNotRestored
		}
		// NWP-20261029-02: in a bracket of its own, so a refusal its head write meets is that bracket's verdict
		// and never another's (see sealWallet).
		capWrite(name, pass, dk, func() {
			h = postBlob(base, seal(dk, data))
			putHead(base, name+"#wallet", pass, h)
		})
		return h, nil
	}
	n := capBegin()
	defer capEndBracket(n)
	capSetSessionAttr(name, pass, dk, true)
	capSetWalletBasis(basis, gen)
	capSetWalletPath(walletPath) // the file basis and gen describe, for putWalletHead to check
	h = postBlob(base, seal(dk, data))
	putHead(base, name+"#wallet", pass, h)
	capFlush(n)
	return h, nil
}

// walletForPublish is what a handset may write to the ACCOUNT's shared wallet ref. It is the local
// wallet with the account's MONOTONIC FACTS merged forward, so a handset can never lower one.
//
// THE DEFECT IT CLOSES, confirmed in the field 2026-09-07. Chester bought 50 GB on frankel while lynx
// was signed in. lynx sealed afterwards, its whole wallet replaced the stored one, and BOTH handsets
// then read 10 GB -- a paid plan erased by a handset that had not bought anything and did not know a
// purchase had happened.
//
// ⚠ WHY A MERGE AND NOT A VERSION COUNTER, WHICH IS THE OBVIOUS FIX AND IS WRONG. A per-device counter
// is not a clock. Both handsets restore the same wallet and then write independently, so their counters
// advance for unrelated reasons: routine lease bookkeeping (recordCoverage, learnPlanSize) writes the
// wallet just as a purchase does. A "refuse a lower count" rule would have fixed the observed case only
// BY ACCIDENT -- because redeeming happens to write more times than bookkeeping does -- and would fail
// silently the moment that stopped being true. Ordering two independent writers needs a real clock or a
// conditional write, and the store cannot express one (seal_cas.go).
//
// So do not order them: merge the fields where LATER IS DEFINABLE WITHOUT A CLOCK. Every field below is
// monotonic in MEANING -- a term never shortens, a deadline never nears, a plan size never falls except
// through the gateway (which is why AccountPlanGB is NOT here; it is the gateway's own answer and must
// be free to go down when a plan genuinely lapses). Taking the max is therefore not a guess about which
// write came last; it is the true value in both. The plan pair has two exceptions, each a waiting purchase: this
// phone's (NWP-20261031-07, below) and the stored copy's, when the tokens carried fund it (NWP-20261129-10, below).
//
// ⚠ THE TOKENS ARE MERGED BY THE DECIDED RULE (NWP-20261031-01; decided 2026-10-20, Q107 -- "two signed-in handsets
// merge their wallets"). Until then they were published unchanged, and a second handset's seal replaced the stored
// wallet whole: handset A claimed 30 tokens, handset B sealed afterwards, and A's 30 were gone from the store once A
// signed out. The rule: the published tokens are this phone's, PLUS each stored token whose key is neither held here
// nor in seen -- the keys of every token this session's wallet file has ever held (wallet_seen.go; tmpfs only,
// so nothing new roams). A token this session held and spent is therefore never resurrected (a plain union would
// bring back nonces the gateway has marked spent), and a token the other phone added, which this session never held,
// is kept. The cost is one-sided and bounded: a token the OTHER phone spent but this one still holds is published
// again, and lasts until this phone's next paid lease, where the gateway's 409 retires it (capFlush, NWP-20261020-03
// / NOWHERE-487). That 409 and the gateway's ledger are the only spent-set of record; seen is a filter against
// this session's own history, never a record of what is spent anywhere.
//
// The pending claim codes (Wallet.PendingClaims, NWP-20261125-05) follow the token rule and its seen semantics. The
// cost is the same shape: a code the OTHER phone cleared but this one still holds is published again, and lasts until
// this phone's next drain, where the gateway's 402 proves it empty and clears it (one /issue round trip).
//
// ⚠ AN IDLE PHONE PUBLISHES THE OTHER PHONE'S PURCHASE WHOLE (NWP-20261129-10; decided 2026-10-20, "a bigger plan
// starts at once ...": a smaller purchase "is never stranded: the wallet activates each purchase at its own size and
// term"; and Q107: a publish carries the other phone's new credit). A phone that publishes the other phone's credit
// must publish the purchase that credit pays for, at its own size, term, answer and queue. planPurchase prices at
// PlanGB x PlanPeriods, so a max of two purchases prices a plan no balance funds: a 10 x 3 keep top-up redeemed on one
// phone under the 50 x 12 plan the other holds was published as 50 x 12 beside 30 tokens, paid for and unspendable.
// So when this phone has nothing waiting, the stored copy has, stored tokens were carried, and the published balance
// funds the stored purchase, that purchase's plan fields, answer and queue are published; otherwise the max stands.
// The carried count is what keeps this phone's own history out: a stored copy whose tokens this session has already
// held or spent pays for nothing new, even when this phone's own tokens would fund the price. Both phones holding a
// DIFFERENT waiting purchase is covered by the purchase ids (h60 #14): every waiting purchase of the stored copy that
// this session never held is queued after this phone's, and it becomes the head when this phone has nothing waiting.
// The NWP-20261129-10 rule above applies only to a stored purchase with no id, and only when the ids took nothing: a
// wallet rewritten by an older build drops the ids and falls back to it. A wallet already stored in the maxed shape is
// not repaired.
//
// seen == nil means no union: today's publish of the local set alone. That is what a set that cannot be read, is
// absent or belongs to another generation gives (walletSeen), and what mergeLateRestore passes because its own union
// is already right. It errs toward keeping the old behaviour, never toward resurrecting. The same holds for
// readStoredWallet's fail-soft, with one exception decided 2026-10-21 (dn-1031 #1, NWP-20261107-02): the cap-mode
// fold (capFlush) writes no #wallet head while the stored copy cannot be read (storedWalletForPublish), and neither do
// payRent's spend (sealWalletValueDurableStrict) and the claim (sealWalletDurableStrict) (NWP-20261129-33). A landed
// sign-out no longer publishes over a copy it could not read before its switch (NWP-20261201-22); a read that fails
// after that check is still fail-soft until its publisher (sealLogoutWalletAndDrop) is strict. END-UNSAVED's and
// RESTART-UNSAVED's publish no longer goes over an unreadable copy: publishWalletBeforeDiscard reads it strictly first
// and publishes nothing when it cannot (NWP-20261201-27). These still publish the local set unchanged over an
// unreadable copy: create's finishStagedClaim and sealWallet (left). In sealWalletDurable's own bracket, whose head is
// written whatever the read, the fold never unstages that head: a fold that cannot read merges the wallet as it is then
// (post-spend, on a re-fold) against the last copy a fold of the same flush read or, before one has, the wallet the
// publisher merged and sealed.
func walletForPublish(stored, local *Wallet, seen map[string]bool) *Wallet {
	if stored == nil || local == nil {
		return local
	}
	out := *local // copy: the caller's wallet must not be mutated by a publish
	// ⚠ A WAITING PURCHASE (OR A QUEUE) IS NOT MAXED (NWP-20261031-07): planPurchase prices at PlanGB x PlanPeriods, so
	// a stored 50 GB raised over this phone's waiting 10 GB top-up would demand 50 x periods signatures and strand the
	// money. The plan fields and the queue stay this phone's; the union below only adds the other phone's purchases by id
	// after them (h60 #14). With nothing waiting the max stands (a stale handset must not lower the account's plan),
	// unless the union below publishes a stored purchase (h60 #14, or NWP-20261129-10 for one without an id).
	if !local.planPending() && len(local.PlanQueue) == 0 {
		if stored.PlanGB > out.PlanGB {
			out.PlanGB = stored.PlanGB
		}
		if stored.PlanPeriods > out.PlanPeriods {
			out.PlanPeriods = stored.PlanPeriods
		}
	}
	if stored.PaidThrough > out.PaidThrough {
		out.PaidThrough = stored.PaidThrough
	}
	if stored.DeadlineEpoch > out.DeadlineEpoch {
		out.DeadlineEpoch = stored.DeadlineEpoch
	}
	if stored.RenewedEpoch > out.RenewedEpoch {
		out.RenewedEpoch = stored.RenewedEpoch
	}
	// ActivateAfter is the privacy jitter on a purchase that has not started. Keeping the LATER one is
	// the safe direction: it can only delay an activation, never bring one forward, and bringing one
	// forward is what would narrow the window the jitter exists to widen.
	if stored.ActivateAfter > out.ActivateAfter {
		out.ActivateAfter = stored.ActivateAfter
	}
	if seen != nil {
		// The tokens: copied first so appending never writes into the caller's backing arrays.
		out.Tokens = append([]Token(nil), local.Tokens...)
		out.BlindTokens = append([]BlindToken(nil), local.BlindTokens...)
		have := map[string]bool{}
		for _, k := range walletSeenKeys(local) {
			have[k] = true
		}
		carried := 0
		for _, t := range stored.Tokens {
			if k := plainSeenKey(t); !have[k] && !seen[k] {
				have[k] = true
				out.Tokens = append(out.Tokens, t)
				carried++
			}
		}
		for _, t := range stored.BlindTokens {
			if k := blindSeenKey(t); !have[k] && !seen[k] {
				have[k] = true
				out.BlindTokens = append(out.BlindTokens, t)
				carried++
			}
		}
		// The pending claim codes (NWP-20261125-05) by the same rule: this phone's, plus each stored code neither held
		// here nor in seen. A code this session held and cleared stays out; a code the other phone added is kept.
		out.PendingClaims = append([]string(nil), local.PendingClaims...)
		for _, c := range stored.PendingClaims {
			if k := pendingClaimSeenKey(c); !have[k] && !seen[k] {
				have[k] = true
				out.PendingClaims = append(out.PendingClaims, c)
			}
		}
		// Every waiting purchase of the stored copy that this session never held (h60 #14). have holds this phone's plan
		// id and queue ids (walletSeenKeys), and seen holds every id this session held, so a purchase that activated here
		// stays out. taken is appended after this phone's, and the first becomes the head when this phone has none waiting.
		var storedWaiting []PlanSpec
		if stored.planPending() {
			storedWaiting = append(storedWaiting, PlanSpec{ID: stored.PlanID, GB: stored.PlanGB, Periods: stored.PlanPeriods, Keep: stored.PlanKeep, Convert: stored.PlanConvert})
		}
		storedWaiting = append(storedWaiting, stored.PlanQueue...)
		idless := false
		var taken []PlanSpec
		for _, s := range storedWaiting {
			if s.ID == "" {
				idless = true
				continue
			}
			if k := "p:" + s.ID; !have[k] && !seen[k] {
				have[k] = true
				taken = append(taken, s)
			}
		}
		took := len(taken) > 0
		if took {
			queue := append([]PlanSpec(nil), local.PlanQueue...)
			if idle := !local.planPending() && len(local.PlanQueue) == 0; idle {
				head := taken[0]
				out.PlanGB, out.PlanPeriods, out.PlanKeep, out.PlanConvert, out.PlanID = head.GB, head.Periods, head.Keep, head.Convert, head.ID
				taken = taken[1:]
			}
			out.PlanQueue = append(queue, taken...)
			if len(out.PlanQueue) == 0 {
				out.PlanQueue = nil
			}
		}
		// The other phone's waiting purchase, whole (NWP-20261129-10, above), for a stored purchase with no id. A waiting
		// head with an id is settled above, even when nothing was taken: its purchase may have activated here. An id in
		// the queue does not take the rule from a head without one, and the ids this session refused stay out of the
		// queue. Read after the union: out.balance() is the published balance.
		olderRule := idless && (!stored.planPending() || stored.PlanID == "")
		if carried > 0 && !local.planPending() && len(local.PlanQueue) == 0 && (stored.planPending() || len(stored.PlanQueue) > 0) &&
			stored.PlanGB > 0 && stored.PlanPeriods > 0 && out.balance() >= stored.PlanGB*int(stored.PlanPeriods) && !took && olderRule {
			out.PlanGB, out.PlanPeriods = stored.PlanGB, stored.PlanPeriods
			out.PlanKeep, out.PlanConvert = stored.PlanKeep, stored.PlanConvert
			out.PlanID = stored.PlanID
			out.PlanQueue = append([]PlanSpec(nil), stored.PlanQueue...)
			var kept []PlanSpec
			for _, q := range out.PlanQueue {
				if q.ID == "" {
					kept = append(kept, q)
				}
			}
			out.PlanQueue = kept
		}
	}
	return &out
}

// readStoredWallet fetches the account's current wallet, or nil if there is none or it cannot be read.
// Fails SOFT on purpose: a wallet publish must never be blocked by a store hiccup, and a nil result
// simply means walletForPublish has nothing to merge and the local copy goes as-is -- today's behaviour.
func readStoredWallet(base, name, pass string, dk []byte) (w *Wallet) {
	defer func() {
		if recover() != nil {
			w = nil
		}
	}()
	head := getRef(base, walletHeadKey(base, name, pass))
	if head == "" {
		return nil
	}
	blob := getBlob(base, head)
	if len(blob) == 0 {
		return nil
	}
	pt := unseal(dk, blob)
	var got Wallet
	if json.Unmarshal(pt, &got) != nil {
		return nil
	}
	return &got
}

// freeRenewedThrough throttles free-tier (#54) lease renewal to once per epoch, so a free session renews
// its 90-day window when it first becomes due each epoch rather than on every keep-alive cycle. The map is
// forgotten at every session end (forgetBillingLatches), so the next sign-in renews on access. Reset in tests.
//
// ⚠ KEYED PER PROFILE (NWP-20260915-12). It was one process-wide int, and the login daemon is ONE process
// for the whole boot serving every profile in turn -- so the first profile to renew in an epoch
// throttled every OTHER profile signed in that day out of its own renewal. That renewal is the only
// thing re-presenting cold chunks before their deadlines, so the cost of throttling the wrong profile
// is the same cost this whole slice is about.
//
// Guarded by freeRenewedMu since NWP-20261112-14: the sign-out renewal (logout_renew.go) runs payRentGenRule beside
// a session's periodic one, and a concurrent map access is a fatal runtime throw that recover() cannot catch.
var (
	freeRenewedMu      sync.Mutex
	freeRenewedThrough = map[string]int64{}
)

// freeRenewedEpoch reads the free-tier latch for one profile under freeRenewedMu.
func freeRenewedEpoch(meterKey string) int64 {
	freeRenewedMu.Lock()
	defer freeRenewedMu.Unlock()
	return freeRenewedThrough[meterKey]
}

// latchFreeRenewed records a whole free renewal for one profile under freeRenewedMu.
func latchFreeRenewed(meterKey string, nowEpoch int64) {
	freeRenewedMu.Lock()
	freeRenewedThrough[meterKey] = nowEpoch
	freeRenewedMu.Unlock()
}

// noWalletRenewed remembers, per profile (keyed like freeRenewedThrough), what a renewal made with NO wallet file
// would have recorded had there been one (NWP-20261010-04). Such a renewal saves nothing -- a missing file is not
// an empty wallet -- so without this renewalDue({}) stays true and every payRent call re-leases the whole
// footprint, holding the wallet lock through each lease. The map is forgotten at every session end
// (forgetBillingLatches). Reset in tests.
var (
	noWalletRenewedMu sync.Mutex
	noWalletRenewed   = map[string]*Wallet{}
)

// recordNoWalletRenewal records a no-file renewal on a stand-in wallet, exactly as payRent would have recorded it
// in a file: recordCoverage when the lease stood behind a term, recordLease otherwise.
func recordNoWalletRenewal(meterKey string, info leaseInfo, bought bool, nowEpoch int64) {
	sim := &Wallet{}
	if bought {
		recordCoverage(sim, info, true, nowEpoch)
	} else {
		recordLease(sim, info, true, nowEpoch)
	}
	noWalletRenewedMu.Lock()
	noWalletRenewed[meterKey] = sim
	noWalletRenewedMu.Unlock()
}

// noWalletRenewalDue says whether a profile with no wallet file is due to renew. It asks renewalDue of the
// stand-in wallet, so the footprint is renewed no later than it would be with a file that recorded the lease,
// and adds one rule: not twice in the epoch it last renewed. A lease's deadlines are epoch-granular, so a second
// lease inside the same epoch extends nothing; it would only repeat the whole-footprint lease every 120 s, as
// renewalDue does for a wallet whose lease named no term. Nothing recorded (a fresh daemon) means due.
func noWalletRenewalDue(meterKey string, nowEpoch int64) bool {
	noWalletRenewedMu.Lock()
	sim, ok := noWalletRenewed[meterKey]
	noWalletRenewedMu.Unlock()
	if !ok {
		return true
	}
	return sim.RenewedEpoch < nowEpoch && renewalDue(sim, nowEpoch)
}

// periodicRenewalDue is the periodic and manual seals' due test: renewalDue, and not twice in the epoch the footprint
// was last renewed (docs/product-decisions.md, "seventeen answers to harvest 59 ...", #9). The renewal that already
// ran this epoch either bought (PaidThrough moved on, planPending false) or could buy nothing, because the wallet's
// tokens are short of the plan's price or its purchase is inside its ActivateAfter hold; a second one inside the epoch
// extends no deadline (they are epoch-granular) and buys nothing. A purchase claimed after it activates at the next
// epoch, which is the decided cost. A renewal that fell short (Q090 batches) stamps no RenewedEpoch, so it is still
// retried this epoch. noWalletRenewalDue is the same rule for a profile with no wallet file.
func periodicRenewalDue(w *Wallet, nowEpoch int64) bool {
	return w.RenewedEpoch < nowEpoch && renewalDue(w, nowEpoch)
}

// signOutRenewalDue is the sign-out's due test (NWP-20261112-14, Q088's device half): renew unless the footprint
// was already renewed in this epoch. It is an inference from Q088's day granularity -- the ledger stamps each row
// with the DAY it was last presented, so a second full-footprint renewal inside the epoch the footprint was last
// renewed cannot make any row's last-presented day newer, while one on a later day re-presents every in-use chunk
// past every row a seal superseded. renewalDue is kept as an arm so the sign-out never renews less than the
// periodic path would.
func signOutRenewalDue(w *Wallet, nowEpoch int64) bool {
	return w.RenewedEpoch < nowEpoch || renewalDue(w, nowEpoch)
}

// noWalletSignOutDue is signOutRenewalDue for a profile with no wallet file: the stand-in noWalletRenewed holds
// the epoch its last no-file renewal ran. Nothing recorded (a fresh daemon) means due.
func noWalletSignOutDue(meterKey string, nowEpoch int64) bool {
	noWalletRenewedMu.Lock()
	sim, ok := noWalletRenewed[meterKey]
	noWalletRenewedMu.Unlock()
	if !ok {
		return true
	}
	return sim.RenewedEpoch < nowEpoch
}

// forgetBillingLatches is h60 #18 (NWP-20261201-37, docs/product-decisions.md 2026-11-06): both latches are keyed by
// a profile's holder key, and the login daemon is one process for the whole boot, so each session end forgets them.
// The whole maps go, as the KDF cache's does: naming one entry would mean re-deriving the key the cache just dropped.
// A same-boot re-sign-in, or a session still kept at that moment, renews once more in that epoch (the accepted cost).
func forgetBillingLatches() {
	freeRenewedMu.Lock()
	freeRenewedThrough = map[string]int64{}
	freeRenewedMu.Unlock()
	noWalletRenewedMu.Lock()
	noWalletRenewed = map[string]*Wallet{}
	noWalletRenewedMu.Unlock()
}

// renewRule selects payRentGenRule's due test (NWP-20261112-14).
type renewRule int

const (
	renewPeriodic renewRule = iota // renewalDue / noWalletRenewalDue: the periodic and manual seals' rule
	renewSignOut                   // signOutRenewalDue / noWalletSignOutDue: a landed sign-out's rule
)

// dueBy is rule's due test for a wallet file.
func dueBy(rule renewRule, w *Wallet, nowEpoch int64) bool {
	if rule == renewSignOut {
		return signOutRenewalDue(w, nowEpoch)
	}
	return periodicRenewalDue(w, nowEpoch)
}

// noWalletDueBy is rule's due test with no wallet file.
func noWalletDueBy(rule renewRule, meterKey string, nowEpoch int64) bool {
	if rule == renewSignOut {
		return noWalletSignOutDue(meterKey, nowEpoch)
	}
	return noWalletRenewalDue(meterKey, nowEpoch)
}

// payRentWho is the profile a pay-rent line names: logProfile(name) on the periodic rule, and no name on the sign-out
// rule, whose lines land after the reap's log scrub (NWP-20261127-03, logout_renew.go).
func payRentWho(rule renewRule, name string) string {
	if rule == renewSignOut {
		return "(sign-out renewal)"
	}
	return logProfile(name)
}

// payRentErrText is the error text s as a pay-rent line on rule prints it: redactNameIn with the profile's name on the
// sign-out rule (NWP-20261127-03), s unchanged on the periodic rule.
func payRentErrText(rule renewRule, name, s string) string {
	if rule == renewSignOut {
		return redactNameIn(s, name)
	}
	return s
}

// payRentLeaseDone, when set (tests only), runs in payRentGenRule between leaseRefsGen and the record section: the one
// point with no network call where a sign-in can still land, and so the only way to pin that section's
// generation check (NWP-20261010-04).
var payRentLeaseDone func()

// payRent keeps a profile's data alive for the current lease window and is safe to call on every sync: it
// only spends once the window has lapsed. Flow: quote the current epoch; if the wallet's recorded
// paid-through still covers it, do nothing. Otherwise resolve the footprint (the profile's data refs PLUS
// the wallet's own previous-epoch blob, so the wallet itself stays alive), redeem the owed tokens, record
// the new paid-through epoch, and re-seal the reduced wallet back to the store. Returns the lease info and
// whether rent was actually paid.
// ⚠ se IS LOAD-BEARING HERE ABOVE EVERYWHERE ELSE (NWP-20260915-12). This is the ONLY full-footprint
// re-lease in the system -- capFlush leases only what a flush writes, and postBlob skips a chunk it has
// already seen -- so a chunk that is not re-presented HERE is never re-presented at all, ages past its
// deadline, and is deleted by the gateway GC individually, underneath a head that is still live. The
// one process that pays rent is the login daemon, and its environment never carries NOWHERE_SE_SECRET,
// so before this a hardened profile died at resolveDK below and lost every cold byte 120 days later.
func payRent(g *gatewayClient, base, name, pass, walletPath string, se []byte) (leaseInfo, bool, error) {
	return payRentGen(g, base, name, pass, walletPath, se, walletGeneration(walletPath))
}

// payRentGen is payRent paying from the wallet generation gen -- the one that was current when the caller read
// the session it is paying for (NWP-20261010-04). syncLoop runs payRent AFTER the seal, so it can outlive its
// session's logoff, and the file can by then be another profile's: a wallet at any other generation is never
// spent from, saved over or published from here (THE GENERATION, wallet_lock.go).
func payRentGen(g *gatewayClient, base, name, pass, walletPath string, se []byte, gen string) (leaseInfo, bool, error) {
	return payRentGenRule(g, base, name, pass, walletPath, se, gen, renewPeriodic)
}

// payRentGenSignOut is payRentGen with the sign-out's due test (signOutRenewalDue, Q088): it renews the whole
// footprint unless it was already renewed in this epoch, whatever the term. Its only caller is renewAtSignOut.
func payRentGenSignOut(g *gatewayClient, base, name, pass, walletPath string, se []byte, gen string) (leaseInfo, bool, error) {
	return payRentGenRule(g, base, name, pass, walletPath, se, gen, renewSignOut)
}

// payRentGenRule is the body payRentGen and payRentGenSignOut share; rule picks only the due test.
func payRentGenRule(g *gatewayClient, base, name, pass, walletPath string, se []byte, gen string, rule renewRule) (leaseInfo, bool, error) {
	q, err := g.quote()
	if err != nil {
		return leaseInfo{}, false, err
	}
	// NWP-20261010-04: with no wallet file a renewal records nothing, so without this every call would re-lease
	// the whole footprint (and hold the wallet lock through it). See noWalletRenewalDue.
	if _, serr := os.Stat(walletPath); os.IsNotExist(serr) && !noWalletDueBy(rule, profileRefV2(name, pass), q.CurrentEpoch) {
		return leaseInfo{}, false, nil
	}
	w, err := loadWallet(walletPath)
	if err != nil {
		return leaseInfo{}, false, err
	}
	// Rent DUE, or the footprint simply STALE -- see renewalDue. The staleness arm is what keeps cold refs
	// alive; without it this returns early for the whole term and nothing ever re-stamps them.
	if !dueBy(rule, w, q.CurrentEpoch) {
		return leaseInfo{}, false, nil // covered, and the footprint was re-leased recently enough
	}
	// A session with no spendable credit is on the FREE tier (#54): the gateway renews its lease for free
	// (metered per profile) and PaidThrough is never advanced, so renewal recurs every due cycle. Throttle
	// it to once per epoch per process so we don't recompute the footprint on every keep-alive; a fresh login
	// starts the process at -1, so renewal always runs on access.
	// FREE means "no plan", not "no tokens left". Once a plan is bought outright the wallet is EMPTY by
	// design -- the whole term was paid for at activation -- so keying this on the balance alone sent every
	// paying customer down the free path, into a 402, and told someone who had just bought twelve months to
	// "add credit". The live term is what distinguishes them.
	// ⚠ AND `PaidThrough` CANNOT CARRY THAT FACT -- which is what turned this into a LATCH
	// (NWP-20260829-06). The free branch below returns WITHOUT calling recordCoverage, deliberately ("no
	// PaidThrough advance, so the next epoch renews again"), so once a paid-up wallet is empty and its
	// remembered term has run out, BOTH halves of the old condition are permanently true -- and the only
	// code that would learn the real term sits on the other side of the branch. The discriminator was being
	// read from state that the branch it selects refuses to refresh.
	//
	// Measured on lynx 2026-08-29, odimport9: a full login/logoff wrote ledger leases at through=20784
	// (= now + 90, the FREE window) while the wallet came out byte-identical at paid_through=20694 with a
	// LIVE 10 GB grant sitting on the gateway. The phone reported "expires today" for a plan it held.
	//
	// So ASK instead of inferring. EntitledBytes > 0 is the gateway's own `LatestThrough(now) >= now` --
	// the very branch that makes this lease cost ZERO WHATEVER THE BYTE COUNT -- rather than a guess about
	// a reply we have not had yet.
	//
	// ⚠ ROUTING CANNOT SPEND, which is what makes it safe to be wrong in the paid direction: only
	// planPurchase buys, and it declines from an empty wallet -- choosePayment's take(n) fails, the tokens
	// are put back, and it returns gb=0, so the request carries buy_gb=0 and no signatures. FAIL OPEN: an
	// older gateway or an offline device leaves freeUser true, i.e. exactly today's behaviour.
	noCredit := w.balance() == 0 && w.PaidThrough <= q.CurrentEpoch
	meterKey := profileRefV2(name, pass)
	if noCredit && freeRenewedEpoch(meterKey) >= q.CurrentEpoch {
		return leaseInfo{}, false, nil
	}
	freeUser := noCredit
	if noCredit {
		if ent, _, eerr := g.entitlement(profileRefV2(name, pass)); eerr == nil && ent.EntitledBytes > 0 {
			freeUser = false
		}
	}
	// ⚠ THE LATCH IS NOT SET HERE ANY MORE (NWP-20260915-12), and where it used to sit is the defect. It was
	// assigned BEFORE resolveDK, before profileFootprint and before the lease itself -- so it was spent on
	// the ATTEMPT, not on a success. Any failure downstream (an unopenable vault, a store read error inside
	// the footprint, a transport error, a 402) burned this profile's single whole-footprint renewal for the
	// entire epoch, and nothing in the call chain retries: maybePayRent logs and returns. It now latches
	// immediately after the free lease is accepted, so a failed attempt is simply retried next cycle.
	//
	// An entitled profile is still never throttled -- the check above is gated on noCredit, and the paid
	// path is the only one that records coverage, so latching it would leave the NWP-20260829-06 latch in
	// place by a different route.
	dk, pv := resolveDKVault(base, name, pass, se)
	if dk == nil {
		return leaseInfo{}, false, fmt.Errorf("pay-rent: cannot open profile %q (unknown or wrong passphrase)", name)
	}
	// NWP-20261009-02: the billing keys this profile's rows may still carry from a credential change, sent
	// as `prior` so the gateway re-tags them to the current key -- and THIS is the lease that settles the
	// record, because it is the only one that names the whole footprint (docs/store-write-authorization.md
	// §4). nil for a legacy bare head, for an index without the record, and for every profile that has not
	// changed its credential since its last renewal, which is nearly all of them.
	var prior []string
	if pv != nil {
		if idx, ok := openScopeIndex(dk, pv.Scopes); ok {
			prior = billRetagOf(idx)
		}
	}
	refs, measured := profileFootprint(base, name, pass, se)
	if !measured {
		// ⚠ BELT AND BRACES OVER resolveDK ABOVE, and not redundant: that gate opens the BARE vault, while
		// scopeFootprint opens each scope again on its own. A renewal that leased the heads alone would
		// re-stamp their deadlines as a success while every chunk aged out -- the NWP-20260915-12 shape,
		// arrived at through a scope rather than through the profile.
		// %s, not %q: logProfile already quotes the name (with its tag outside the quotes). Wrapping that in a
		// second %q escaped its quotes, and the scrub then paired the wrong ones and left the name in the clear
		// (NWP-20261008-09).
		return leaseInfo{}, false, fmt.Errorf("pay-rent: cannot measure %s -- refusing to renew a footprint "+
			"it cannot see", logProfile(name))
	}
	if len(refs) == 0 {
		return leaseInfo{}, false, nil // nothing stored yet -> nothing to keep alive
	}
	whk := walletHeadKey(base, name, pass) // #80: the live wallet head key (v2 or legacy) -- resolve once
	if cur := getRef(base, whk); cur != "" {
		refs["blob/"+cur] = blobSize(base, cur) // keep the wallet's own (prior-epoch) blob alive through this lease
	}
	refs["ref/"+whk] = 0 // and its mutable pointer (so it gets a write cap in cap mode)
	if freeUser {
		// Free renewal: a token-less lease that pushes the 90-day window forward without spending. No
		// PaidThrough advance, so the next epoch renews again. Over quota / disabled -> the user needs credit.
		// Q090: in batches like the paid arm. The gateway's FreeBytesInUse counts only the profile's free rows with
		// through_epoch >= now, so a batch is judged on the whole footprint only while the other rows are live; for
		// a lapsed profile each batch is judged on less than the whole.
		batches := leaseBatches(refs, leaseBatchRefs)
		finfo, code, ferr := g.leaseFree(profileRefV2(name, pass), batches[0], prior) // #80: stable per-profile metering key
		if ferr != nil {
			return leaseInfo{}, false, ferr
		}
		if code != http.StatusOK {
			if finfo.Reason != "" {
				return leaseInfo{}, false, fmt.Errorf("pay-rent: free tier unavailable for %q (HTTP %d, gateway said: %s) -- add credit", name, code, finfo.Reason)
			}
			return leaseInfo{}, false, fmt.Errorf("pay-rent: free tier unavailable for %q (HTTP %d) -- add credit", name, code)
		}
		for _, b := range batches[1:] {
			_, bcode, berr := g.leaseFree(profileRefV2(name, pass), b, prior)
			if berr != nil || bcode != http.StatusOK {
				finfo.BatchesShort++
			}
		}
		if finfo.BatchesShort == 0 {
			// The renewal LANDED, every batch of it -- throttle the rest of this epoch. See the note above the
			// freeUser branch for why this is here and not up there. A short renewal is not latched, so the next
			// keep-alive in this epoch renews again (Q090).
			latchFreeRenewed(meterKey, q.CurrentEpoch)
			// NWP-20261009-02: ...and the whole footprint was presented with `prior`, so the re-tag has settled;
			// the record comes off the vault. Only here and on the paid arm below, never from a seal's lease,
			// which names only what that flush wrote.
			dropBillRetag(base, name, pass, dk, prior)
		} else {
			fmt.Fprintf(os.Stderr, "[agent] pay-rent %s: %d of %d renewal batches did not land -- their refs keep their old deadline until the next renewal (Q090)\n",
				payRentWho(rule, name), finfo.BatchesShort, len(batches))
		}
		if walletGeneration(walletPath) != gen {
			return finfo, true, nil // NWP-20261010-04: the file is another profile's now -- never publish it as ours
		}
		_, err := sealWallet(base, name, pass, dk, walletPath) // no-op in cap mode; publishes the wallet otherwise
		return finfo, true, err
	}
	info, bought, spent, spentProven, err := leaseRefsGen(g, walletPath, gen, profileRefV2(name, pass), refs, prior)
	// Q090: FULL means every batch of the renewal landed. A short one records the spend and the term (both true:
	// batch 0 landed) but never the renewal stamp or the collector's date, so renewalDue stays true and the next
	// payRent re-runs the renewal; it spends nothing new, planPurchase declines once the plan is activated. The
	// vault's retag record stays too: a batch that did not land has not been re-tagged.
	full := info.BatchesShort == 0
	if !full && (err == nil || errors.Is(err, errNoWalletFile) || errors.As(err, new(*walletReplaced))) {
		fmt.Fprintf(os.Stderr, "[agent] pay-rent %s: %d of %d renewal batches did not land -- their refs keep their old deadline until the next renewal (Q090)\n",
			payRentWho(rule, name), info.BatchesShort, len(leaseBatches(refs, leaseBatchRefs)))
	}
	// NWP-20261010-04: DEPARTED -- the wallet changed hands during the lease. leaseRefsGen did not save; what it
	// spent comes back here, is recorded below on that wallet, and goes to THIS profile's head by value.
	if errors.Is(err, errNoWalletFile) {
		// NWP-20261010-04: renewed, and nothing else. There was no wallet file to record into, and publishing the
		// {} loadWallet stood in for it would replace the durable wallet's tokens with none. The durable head
		// stays what it is; the next sign-in restores it. Restoring it HERE instead was rejected: a head can lag
		// a spend (the residual row), and resurrecting one into a live session is the 409 this slice exists for.
		// ...except in memory, so the NEXT call knows this renewal happened (noWalletRenewalDue).
		if full {
			recordNoWalletRenewal(profileRefV2(name, pass), info, bought, q.CurrentEpoch)
		}
		fmt.Fprintf(os.Stderr, "[agent] pay-rent %s: no wallet file -- renewed, nothing recorded or published (NWP-20261010-04)\n", payRentWho(rule, name))
		if full {
			dropBillRetag(base, name, pass, dk, prior)
		}
		return info, true, nil
	}
	var replaced *walletReplaced
	departed := errors.As(err, &replaced)
	if err != nil && !departed {
		return leaseInfo{}, false, err
	}
	if payRentLeaseDone != nil {
		payRentLeaseDone() // tests only: a sign-in between leaseRefsGen's save and the record below
	}
	// record paid-through on the now-reduced wallet and re-seal so the roamed copy reflects the spend.
	// NWP-20261010-04: re-load, record and save under the wallet lock (a flush may have spent from this file
	// since leaseRefs released it -- this load sees that), and RELEASE IT BEFORE the durable publish below: that
	// opens a bracket whose capFlush takes the wallet lock, and holding it here would wait on ourselves. The
	// generation is checked first, with nothing slow before the save: a sign-in between leaseRefsGen's save and
	// here makes this departed too, with leaseRefsGen's saved wallet as the record.
	unlock := lockWallet(walletPath)
	defer unlock() // the error returns between here and the explicit release
	w = spent
	if !departed && walletGeneration(walletPath) != gen {
		departed = true
	}
	if !departed {
		if w, err = loadWallet(walletPath); err != nil {
			return info, true, err
		}
	}
	// NWP-20260915-12: capFlush's -03 guard, which payRent never got. A 409 withdraws the purchase and
	// re-leases for nothing; recording coverage then paints a live term AND a deletion date the gateway
	// holds no grant for -- telling a customer whose purchase just failed that it succeeded. The plan
	// SIZE is still the gateway's own answer about the account and is true either way, so it is learned
	// on both arms rather than withheld from the handset that hit the 409.
	if bought {
		recordCoverage(w, info, full, q.CurrentEpoch) // the deadline only when every batch landed
	} else {
		// recordLease, not learnPlanSize: this lease DID re-stamp the whole footprint, so the renewal
		// stamp is true, and withholding it is what re-leases that footprint every 120s
		// (NWP-20260915-26). The term and the deadline are the only claims withheld.
		recordLease(w, info, full, q.CurrentEpoch)
	}
	// NWP-20261013-20 (pass 5): THE PROOF THE PUBLISH BELOW IS JUDGED BY IS THE ONE THAT STOOD WHEN ITS COPY WAS TAKEN,
	// read under this lock with the copy: here for the wallet saved below, at leaseRefsGen's load for the departed
	// one. The publish runs after the lock is released, and a retry that lands meanwhile proves gen for copies taken
	// after its merge, never for this one, which lacks the stored tokens (a fix review reproduced it: stored 10 -> 1).
	// A copy refused this way loses nothing: the file at gen keeps the spend, and the retry's merge, which loads the
	// file after this save, carries it into the fold.
	proven := spentProven
	var basis []byte
	if !departed {
		if err := saveWallet(walletPath, w); err != nil {
			return info, true, err
		}
		basis, _ = json.Marshal(w) // exactly the bytes saveWallet wrote
		proven = walletRestoreLanded(walletPath, gen)
	}
	unlock()
	// NWP-20260829-14: DURABLE, not sealWallet. In cap mode sealWallet returns immediately -- "the wallet
	// rides the seal flush (capFlush fold)" -- and both of capFlush's doFold calls run BEFORE its own
	// recordCoverage, so nothing that payRent learns here is ever folded. The term was written to a tmpfs
	// wallet and died with it: measured on lynx 2026-08-29, a seal recorded paid_through=20782 and the very
	// next login restored 20694, so a paying customer kept seeing "expires today" no matter how correctly
	// the routing above worked.
	//
	// ⚠ IT IS NOT ONLY THE DISPLAY. leaseRefs above SPENT tokens, and settlePayment recorded that spend in
	// this same wallet. Losing the write loses the spend record while the gateway keeps the nonces marked
	// spent -- the wallet resurrects tokens the gateway will refuse, which is the shape that burns credit
	// for nothing.
	//
	// Safe to open a bracket here: capBegin does NOT nest (since NWP-20261009-07 a nested one waits forever on
	// capBracketMu), but no caller of payRent is inside one -- maybePayRent is called from the daemon's seal
	// loop and its manual-seal goroutine, outside any bracket (the seal itself runs in the `push` process),
	// and the CLI verb has none. A bracket another goroutine holds, a re-key batch or an export, is simply
	// waited for. handleClaim set the precedent for exactly this reason (DIA-20260806-20). And no caller holds
	// the wallet lock, which this bracket's capFlush takes: it was released just above (NWP-20261010-04).
	//
	// NWP-20261010-04: BY VALUE, not by reading the file back. The file may already be another profile's (THE
	// GENERATION), and reading it under this profile's DK is how one profile's tokens would be published at
	// another's head. On the departed path the spend reaches this profile's head here or nowhere.
	//
	// NWP-20261129-33 (dn-1031 #1): strict, so an unreadable stored copy keeps another handset's tokens. The saved path's
	// next save that can read publishes the merge. On the departed path the stored copy keeps the spent tokens, which
	// the next paid lease's 409 retires.
	_, err = sealWalletValueDurableStrict(base, name, pass, dk, walletPath, w, basis, gen, proven)
	if departed && err == nil {
		fmt.Fprintf(os.Stderr, "[agent] pay-rent %s: the wallet changed hands mid-renewal -- the spend was published "+
			"to this profile's own head, not saved locally (NWP-20261010-04)\n", payRentWho(rule, name))
	} else if departed {
		fmt.Fprintf(os.Stderr, "[agent] pay-rent %s: the wallet changed hands mid-renewal -- the spend was not "+
			"published (%s)\n", payRentWho(rule, name), payRentErrText(rule, name, logSafeStoreErr("wallet", err)))
	}
	// NWP-20261009-02: the full footprint was leased with `prior`, so the re-tag has settled (see the free
	// arm). dropBillRetag publishes the vault through its own cap bracket, which since NWP-20261010-04 never
	// touches the wallet file (walletNotOurs), so its order against the publish above no longer matters.
	if full {
		dropBillRetag(base, name, pass, dk, prior)
	}
	return info, true, err
}

// carryWallet moves a profile's wallet to the credential it is changing to, and it is a POINTER MOVE --
// one getRef at the old location, one putRef at the new one. That is the whole of it, and the narrowness
// is the safety argument (NWP-20260915-17).
//
// ⚠ IT NEVER MERGES, AND THAT IS NOT A SIMPLIFICATION. walletForPublish already refuses to merge token
// sets and says why: a union resurrects nonces the gateway has marked spent -- which then sit in the
// wallet permanently undeadable, because redemption is all-or-nothing and one dead nonce rejects every
// token presented -- and an intersection destroys credit that was just claimed. Neither is safe without a
// spent-set the device does not have. So do not compute the published token set from two inputs. Select
// one object and move its address: no expression here mentions a nonce, so losing or resurrecting one is
// unrepresentable rather than merely avoided.
//
// ⚠ AND IT MOVES THE CIPHERTEXT, NOT A RE-SERIALISATION. Decoding to a Wallet and re-marshalling would
// silently DROP any field this build does not know -- an older agent quietly deleting a newer one's wallet
// state, on a staged rollout. The blob is opaque here and stays opaque.
//
// src is where to look: a rotation holds the old passphrase and DERIVES it (headKey resolves the unit/v2/
// legacy ladder, so it also finds a pre-#80 wallet the recorded ref would miss); a recovery has no old
// passphrase by premise and passes the location the scope index recorded, which is the reason #wallet is
// in that index at all. Absence is an ordinary answer -- a profile that never had credit -- and returns
// false without publishing.
//
// The blob is re-POSTED rather than merely pointed at, and only for its lease: capFlush bills what this
// bracket buffered, so a pointer published without its object would be the first wallet head in the tree
// whose blob this flush does not keep alive. seal is convergent (the GCM nonce is an HMAC of the
// plaintext), so re-posting identical bytes yields the identical hash: the ref still ends up naming the
// same immutable object, and there is no second copy in the store.
func carryWallet(base, name, newpass string, dk []byte, src string) bool {
	if src == "" {
		return false
	}
	cur := getRef(base, src)
	if cur == "" {
		fmt.Fprintf(os.Stderr, "[agent] wallet carry: nothing at %s -- recording the new location only\n", short(src))
		return false
	}
	newRef, _ := headWriteRef(name+"#wallet", newpass)
	if newRef == src {
		return false // already there (the credential did not move this head)
	}
	putRef(base, newRef, postBlob(base, getBlob(base, cur)))
	fmt.Fprintf(os.Stderr, "[agent] wallet carry: %s -> %s (blob %s)\n", short(src), short(newRef), short(cur))
	return true
}
