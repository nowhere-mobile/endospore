package com.nowhere.chooser;

/** NWP-20261103-06: the wallet-repair reply classifier and dialog copy (WalletRepairCopy). */
final class Cases {
    private static int n = 0, fails = 0;

    private static void check(boolean ok, String what) {
        n++;
        if (!ok) { fails++; System.out.println("  FAIL  " + what); }
    }

    public static void main(String[] args) {
        check(WalletRepairCopy.CHECK_REQUEST.equals("REPAIR-WALLET\nCHECK\n"), "CHECK request bytes");
        check(WalletRepairCopy.CONFIRM_REQUEST.equals("REPAIR-WALLET\nCONFIRM\n"), "CONFIRM request bytes");

        for (String r : new String[] {"DAMAGED", "DAMAGED\n", " DAMAGED "})
            check(WalletRepairCopy.offerRepair(r), "offerRepair true for [" + r.trim() + "]");
        for (String r : new String[] {"OK", "UNKNOWN", "NONE", "ERR", null, "", "OK REPAIRED", "REFUSED UNKNOWN", "DAMAGEDX", "damaged"})
            check(!WalletRepairCopy.offerRepair(r), "offerRepair false for [" + r + "]");

        check(WalletRepairCopy.repaired("OK REPAIRED") && WalletRepairCopy.repaired("OK REPAIRED\n"), "repaired on OK REPAIRED");
        for (String r : new String[] {"REFUSED OK", "REFUSED UNKNOWN", "REFUSED BUSY", "REFUSED GEN", "NONE", "ERR", null, ""})
            check(!WalletRepairCopy.repaired(r), "not repaired for [" + r + "]");

        for (String r : new String[] {"REFUSED UNKNOWN", "REFUSED BUSY"})
            check(WalletRepairCopy.keepButton(r), "button kept for " + r);
        for (String r : new String[] {"OK REPAIRED", "REFUSED OK", "REFUSED GEN", "NONE", "ERR", null, ""})
            check(!WalletRepairCopy.keepButton(r), "button dropped for [" + r + "]");

        check(WalletRepairCopy.reasonLine("OK REPAIRED").isEmpty(), "no reason line when it landed");
        check(WalletRepairCopy.reasonLine("REFUSED OK").contains("Nothing to repair"), "REFUSED OK says nothing to repair");
        check(!WalletRepairCopy.reasonLine("REFUSED OK").contains("Try again"), "REFUSED OK does not say try again");
        check(WalletRepairCopy.reasonLine("REFUSED UNKNOWN").contains("Try again"), "REFUSED UNKNOWN says try again");
        check(WalletRepairCopy.reasonLine("REFUSED BUSY").contains("busy"), "REFUSED BUSY says busy");
        String gen = WalletRepairCopy.reasonLine("REFUSED GEN");
        check(!gen.isEmpty() && gen.contains("changed"), "REFUSED GEN says the credit changed");
        String dflt = WalletRepairCopy.reasonLine("");
        check(!dflt.isEmpty(), "a default reason line exists");
        for (String r : new String[] {null, "NONE", "ERR"})
            check(WalletRepairCopy.reasonLine(r).equals(dflt), "default reason line for [" + r + "]");
        String[] lines = {WalletRepairCopy.reasonLine("REFUSED OK"), WalletRepairCopy.reasonLine("REFUSED UNKNOWN"),
            WalletRepairCopy.reasonLine("REFUSED BUSY"), gen, dflt};
        for (int i = 0; i < lines.length; i++)
            for (int j = i + 1; j < lines.length; j++)
                check(!lines[i].equals(lines[j]), "reason lines " + i + " and " + j + " are distinct");

        String m = WalletRepairCopy.MESSAGE;
        check(m.contains("damaged"), "dialog says the copy is damaged");
        check(m.contains("nobody can read it"), "dialog says nobody can read it");
        check(m.contains("can't be recovered"), "dialog says the credit can't be recovered");
        check(m.contains("gives that credit up"), "dialog says repairing gives that credit up");
        check(m.contains("saved again"), "dialog says new credit is saved again");
        check(m.contains("Credit this phone holds now is kept"), "dialog says the phone's own credit is kept");
        check(WalletRepairCopy.NEGATIVE.equals("Cancel"), "negative button is Cancel");
        check(!WalletRepairCopy.POSITIVE.equals(WalletRepairCopy.NEGATIVE), "positive and negative differ");
        check(WalletRepairCopy.BUTTON_LABEL.equals("Repair stored credit"), "button label");

        if (fails == 0) { System.out.println("ok: " + n + " cases"); System.exit(0); }
        System.out.println(fails + " of " + n + " cases failed");
        System.exit(1);
    }
}
