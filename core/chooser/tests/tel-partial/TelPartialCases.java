// NWP-20261110-12 (Q029): the cases for SmsDeliverReceiver.holdMs and .partialLoss, lifted by name with
// TelArrival.Reply from the real source by run.sh and executed under plain javac. Exit 1 when a case fails.
public final class TelPartialCases {
    private static int fails = 0;

    private static void check(String name, boolean ok) {
        System.out.println((ok ? "  ok    " : "  FAIL  ") + name);
        if (!ok) fails++;
    }

    private static TelArrival.Reply reply(String kind, String vis, boolean partial) {
        TelArrival.Reply r = new TelArrival.Reply();
        r.kind = kind;
        r.vis = vis;
        r.partial = partial;
        return r;
    }

    public static void main(String[] args) {
        // H1: the hold runs to the deadline the seal's retries ran to, never below 0, and not at all when it is unknown
        check("H1 holdMs(60000, 1000) = 59000", SmsDeliverReceiver.holdMs(60000, 1000) == 59000);
        check("H1 holdMs(1000, 5000) = 0 (the deadline has passed)", SmsDeliverReceiver.holdMs(1000, 5000) == 0);
        check("H1 holdMs(0, 5) = 0 (no deadline known)", SmsDeliverReceiver.holdMs(0, 5) == 0);
        check("H1 a fresh Reply's deadline is 0, so it holds nothing", SmsDeliverReceiver.holdMs(new TelArrival.Reply().deadline, 5) == 0);

        // P1: an OK PARTIAL leaves the loss notice, under the failure branch's Private rule
        check("P1 OK + partial + open: the loss notice", SmsDeliverReceiver.partialLoss(reply("OK", "open", true), false));
        check("P1 OK + partial + number: the loss notice", SmsDeliverReceiver.partialLoss(reply("OK", "number", true), false));
        check("P1 a Private reply: no notice", !SmsDeliverReceiver.partialLoss(reply("OK", "private", true), false));
        check("P1 a line known to be Private: no notice", !SmsDeliverReceiver.partialLoss(reply("OK", "open", true), true));
        check("P1 an OK without PARTIAL: no loss notice", !SmsDeliverReceiver.partialLoss(reply("OK", "open", false), false));
        check("P1 an ERR (partial set): not a partial loss", !SmsDeliverReceiver.partialLoss(reply("ERR", "open", true), false));
        check("P1 no reply: not a partial loss", !SmsDeliverReceiver.partialLoss(null, false));

        System.out.println(fails == 0 ? "every case passed" : fails + " case(s) failed");
        System.exit(fails == 0 ? 0 : 1);
    }
}
