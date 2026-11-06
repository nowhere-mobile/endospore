package com.nowhere.chooser;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * NWP-20261118-16: the cases for MessageGroup, compiled with it as-is, and the source checks over TelIngest and
 * MessagingSuppressor that a javac run cannot reach (they need Android). Run by
 * core/vendor-common/bin/test-message-group-java.sh, which passes the chooser's source dir as args[0].
 *
 * The source checks run on the text with its comments stripped, so a comment that names a call never satisfies a
 * check. A method's body is found by its declaration, which must occur exactly once, and by brace matching from its
 * first '{'. A declaration that is missing or repeated is a FAILED check, never a pass.
 */
public final class MessageGroupCases {
    private static int runs, fails;

    private static void check(String id, boolean ok, String what) {
        runs++;
        if (ok) return;
        fails++;
        System.out.println("  FAIL  " + id + ": " + what);
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.out.println("usage: MessageGroupCases <chooser source dir>");
            System.exit(2);
        }
        cases();
        pins(Paths.get(args[0]));
        System.out.println(runs + " checks, " + fails + " failed");
        System.exit(fails == 0 ? 0 : 1);
    }

    static void cases() {
        check("C1", !MessageGroup.wantSummary(0) && !MessageGroup.wantSummary(-1),
                "wantSummary is true with no message notice showing");
        check("C2", MessageGroup.wantSummary(1) && MessageGroup.wantSummary(2) && MessageGroup.wantSummary(5),
                "wantSummary is false with 1, 2 or 5 message notices showing");
        check("C3", "New message".equals(MessageGroup.summaryText(1))
                        && "2 new messages".equals(MessageGroup.summaryText(2)),
                "summaryText(1) is not \"New message\" or summaryText(2) is not \"2 new messages\"");
        String tag = MessageGroup.SUMMARY_TAG;
        check("C4", tag != null && tag.indexOf(':') < 0 && !tag.startsWith("sms:") && !tag.startsWith("mms:")
                        && !tag.equals("sms:1") && !tag.equals("mms:1"),
                "SUMMARY_TAG has a ':' or has the shape of a noticeTag (\"sms:<ms>\", \"mms:<ms>\")");
        check("C5", MessageGroup.KEY != null && !MessageGroup.KEY.isEmpty(), "KEY is null or empty");
    }

    static void pins(Path dir) throws Exception {
        String tel = strip(read(dir.resolve("TelIngest.java")));
        String sup = strip(read(dir.resolve("MessagingSuppressor.java")));

        String post = body("P1", tel, "private static void postRoamedMessageNotice(");
        if (post != null) {
            check("P1", post.contains(".setGroup(MessageGroup.KEY)"),
                    "postRoamedMessageNotice's builder does not hold .setGroup(MessageGroup.KEY)");
            int notify = post.indexOf("nm.notify(");
            int sync = post.indexOf("syncMessageSummary(ctx)");
            check("P2", notify >= 0 && sync > notify,
                    "postRoamedMessageNotice does not call syncMessageSummary(ctx) after nm.notify(");
        }

        String sync = body("P3", tel, "static void syncMessageSummary(Context ctx)");
        if (sync != null) {
            for (String s : new String[]{"setGroupSummary(true)", "setGroup(MessageGroup.KEY)", "GROUP_ALERT_CHILDREN",
                    "setPublicVersion(", "messageTapIntent(ctx, null)", "MessageGroup.wantSummary(",
                    "cancel(MessageGroup.SUMMARY_TAG, MessageGroup.SUMMARY_ID)"}) {
                check("P4", sync.contains(s), "syncMessageSummary does not hold " + s);
            }
            check("P4", !sync.contains("getLaunchIntentForPackage"),
                    "syncMessageSummary builds a launch intent itself (the chooser's own is Profile)");
        }

        String clear = body("P5", tel, "static int[] clearReadNotices(Context ctx)");
        if (clear != null) {
            check("P5", clear.contains("syncMessageSummary(ctx)"), "clearReadNotices does not call syncMessageSummary(ctx)");
        }

        String removed = body("P6", sup, "public void onNotificationRemoved(StatusBarNotification sbn)");
        if (removed != null) {
            check("P6", removed.contains("TelIngest.syncMessageSummary("),
                    "onNotificationRemoved does not call TelIngest.syncMessageSummary(");
        }

        String missed = body("P7", tel, "static void postMissedCallNotice(");
        if (missed != null) {
            check("P7", !missed.contains("setGroup"), "postMissedCallNotice is in a group");
        }
    }

    static String read(Path p) throws Exception {
        return new String(Files.readAllBytes(p), StandardCharsets.UTF_8);
    }

    /** The body of the one declaration that holds `decl`, from its first '{' to the matching '}', or null (a FAILED
     *  check under `id`) when `decl` is missing, occurs twice, or has no balanced body. */
    static String body(String id, String src, String decl) {
        int at = src.indexOf(decl);
        if (at < 0) { check(id, false, "declaration not found: " + decl); return null; }
        if (src.indexOf(decl, at + 1) >= 0) { check(id, false, "declaration found twice: " + decl); return null; }
        int open = src.indexOf('{', at);
        if (open < 0) { check(id, false, "no body: " + decl); return null; }
        int depth = 0;
        for (int i = open; i < src.length(); i++) {
            char c = src.charAt(i);
            if (c == '"' || c == '\'') { i = skipLiteral(src, i); continue; }
            if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return src.substring(open, i + 1);
        }
        check(id, false, "unbalanced body: " + decl);
        return null;
    }

    /** The index of the closing quote of the string or char literal that opens at `i`. */
    static int skipLiteral(String s, int i) {
        char q = s.charAt(i);
        for (int j = i + 1; j < s.length(); j++) {
            char c = s.charAt(j);
            if (c == '\\') { j++; continue; }
            if (c == q || c == '\n') return j;
        }
        return s.length();
    }

    /** `src` with its // and block comments removed (newlines kept), string and char literals left whole. */
    static String strip(String src) {
        StringBuilder out = new StringBuilder(src.length());
        int n = src.length();
        for (int i = 0; i < n; i++) {
            char c = src.charAt(i);
            if (c == '"' || c == '\'') {
                int end = Math.min(skipLiteral(src, i), n - 1);
                out.append(src, i, end + 1);
                i = end;
            } else if (c == '/' && i + 1 < n && src.charAt(i + 1) == '/') {
                while (i < n && src.charAt(i) != '\n') i++;
                if (i < n) out.append('\n');
            } else if (c == '/' && i + 1 < n && src.charAt(i + 1) == '*') {
                int end = src.indexOf("*/", i + 2);
                if (end < 0) end = n - 2;
                for (int j = i; j < end + 2; j++) if (src.charAt(j) == '\n') out.append('\n');
                i = end + 1;
            } else {
                out.append(c);
            }
        }
        return out.toString();
    }
}
