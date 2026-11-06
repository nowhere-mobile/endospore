// NWP-20261114-02 (Q044): the cases for NowhereInCallService.secondCall, lifted into Lifted by run.sh.
// A second call takes the line only when it is an emergency call and the call on screen is not: a ringing current is
// rejected (TAKE_REJECT_CURRENT), an answered one ends when the callback is answered (TAKE_END_ON_ANSWER).
final class Cases {
    static int fails = 0;

    static String name(int a) {
        if (a == Lifted.REJECT_NEW) return "REJECT_NEW";
        if (a == Lifted.TAKE_REJECT_CURRENT) return "TAKE_REJECT_CURRENT";
        if (a == Lifted.TAKE_END_ON_ANSWER) return "TAKE_END_ON_ANSWER";
        return "unknown(" + a + ")";
    }

    static void check(String what, int got, int want) {
        if (got == want) System.out.println("ok   " + what + " -> " + name(got));
        else { System.out.println("FAIL " + what + " -> " + name(got) + ", want " + name(want)); fails++; }
    }

    public static void main(String[] args) {
        if (Lifted.REJECT_NEW == Lifted.TAKE_REJECT_CURRENT || Lifted.REJECT_NEW == Lifted.TAKE_END_ON_ANSWER
                || Lifted.TAKE_REJECT_CURRENT == Lifted.TAKE_END_ON_ANSWER) {
            System.out.println("FAIL the three actions are not distinct");
            fails++;
        }
        // { incomingIsEmergency, currentIsEmergency, currentRinging } -> the decided action
        boolean[][] in = {
            { false, false, false }, { false, false, true }, { false, true, false }, { false, true, true },
            { true, false, false }, { true, false, true }, { true, true, false }, { true, true, true },
        };
        int[] want = {
            Lifted.REJECT_NEW, Lifted.REJECT_NEW, Lifted.REJECT_NEW, Lifted.REJECT_NEW,
            Lifted.TAKE_END_ON_ANSWER, Lifted.TAKE_REJECT_CURRENT, Lifted.REJECT_NEW, Lifted.REJECT_NEW,
        };
        for (int i = 0; i < in.length; i++) {
            check("incoming=" + in[i][0] + " current=" + in[i][1] + " ringing=" + in[i][2],
                    Lifted.secondCall(in[i][0], in[i][1], in[i][2]), want[i]);
        }
        // An emergency call on screen is never displaced, whatever arrives and whatever its state.
        for (boolean inc : new boolean[]{ false, true }) {
            for (boolean ring : new boolean[]{ false, true }) {
                check("emergency current never displaced (incoming=" + inc + " ringing=" + ring + ")",
                        Lifted.secondCall(inc, true, ring), Lifted.REJECT_NEW);
            }
        }
        if (fails > 0) { System.out.println(fails + " case(s) FAILED"); System.exit(1); }
        System.out.println("all cases passed");
    }
}
