package com.nowhere.chooser;

/**
 * NWP-20261203-04: the words and numbers of the sign-in chooser-kill evidence. Backlog row "At every sign-in the
 * session's chooser process is killed for "permissions revoked" and its CredentialService is left restarting with the
 * sign-in's starts pending". Three probes write through ChooserActivity.idleTrace into login.log, which the issue
 * reporter carries:
 *   - `smsprobe step= u= holder= perms= up=` (the gate, around cedeSmsToMessagingInRoamedUser in roamLogin);
 *   - `credsvc <kind> u= id= up=` (the session's CredentialService, once per start delivered);
 *   - `exitinfo u= reason= ago= up=` (the session chooser's next process birth, NowhereApp).
 * The daemon prints only its closed vocabulary (core/agent/idle_trace.go), so every value here is an integer or one
 * of the fixed lower-case words below: never a package, profile or app name. Pure java.lang / java.util, so
 * core/chooser/tests/signin-trace compiles and runs it off the build host.
 */
final class SignInTrace {
    private SignInTrace() {}

    /** An exit older than this is not the sign-in's kill. */
    static final long EXIT_WINDOW_MS = 15 * 60 * 1000L;

    /** The session's SMS-role holders as one class: -1 unreadable (null), 0 none, 1 the chooser holds it (checked
     *  first, so the chooser among others is 1), 2 Messaging, 3 another app. */
    static int holderClass(java.util.List<String> holders, String self, String messaging) {
        if (holders == null) return -1;
        if (holders.isEmpty()) return 0;
        if (holders.contains(self)) return 1;
        if (holders.contains(messaging)) return 2;
        return 3;
    }

    /** Bit i set when PermDeclines.SMS_ROLE_PERMS[i] is granted to the chooser; -1 when the grants are unreadable. */
    static int permBits(boolean[] granted) {
        if (granted == null) return -1;
        int bits = 0;
        for (int i = 0; i < granted.length; i++) if (granted[i]) bits |= 1 << i;
        return bits;
    }

    /** One word per CredentialService.onStartCommand branch, tested in that method's branch order, so two extras on
     *  one start name the branch that runs. Lower case: the daemon filter drops capitals. */
    static String startKind(java.util.function.Predicate<String> has) {
        if (has.test("claimsLogin")) return "claimslogin";
        if (has.test("claims")) return "claims";
        if (has.test("alarm")) return "alarm";
        if (has.test("relayprefs")) return "relayprefs";
        if (has.test("gosstate")) return "gosstate";
        if (has.test("ingest")) return "ingest";
        if (has.test("smsrole")) return "smsrole";
        if (has.test("smsretry")) return "smsretry";
        if (has.test("telingest")) return "telingest";
        return "pw";
    }

    /** `reason=<r> ago=<ms>` for the last process exit, or null when it is in the future (agoMs < 0) or older than
     *  EXIT_WINDOW_MS. The reason is ApplicationExitInfo.getReason() (REASON_PERMISSION_CHANGE is 8); never the
     *  description text. */
    static String exitLine(int reason, long agoMs) {
        if (agoMs < 0 || agoMs > EXIT_WINDOW_MS) return null;
        return "reason=" + reason + " ago=" + agoMs;
    }
}
