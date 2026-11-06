package com.nowhere.chooser;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.TreeSet;

/**
 * Q033 (docs/product-decisions.md, 2026-10-20): when the gate removes a multipart SMS segment whose siblings never
 * arrive. A waiting segment goes 24 hours after the gate FIRST SAW it, and the clock is the gate's own wall clock,
 * not the row's `date`: that column is the SMSC timestamp, so a text the network held for a day while the phone was
 * off arrives with a `date` already past the window, and expiring on it would delete its first segments the moment
 * they land, before the siblings follow. First sight is written to disk by the caller and so survives a power-off;
 * a monotonic clock cannot, as it restarts at every boot. The accepted cost: a text whose segments arrive more than
 * a day apart is lost.
 *
 * #36 (docs/product-decisions.md, 2026-10-22, NWP-20261115-07): only ORPHAN segments wait and go; a complete text
 * the framework stored but never dispatched (one stranded at a power loss, say) is excluded (orphans). A row whose
 * count is 1 is a whole single-part text by its own count, whatever its sequence or reference number. Rows whose
 * count is 2 or more, with a sequence, group by (address, reference_number, count, destination_port), a NULL a key
 * value of its own, and a group is complete only when its DISTINCT sequences are exactly 1..count. Every other row
 * is an orphan: a NULL or < 1 count, a multipart row with no sequence (that row alone), an incomplete group, one with
 * a gap, a value outside 1..count or more values than count, and any other numbering, 0..count-1 included. Every
 * doubt reads toward an orphan, which was the rule for every row before #36. The key is narrower than the
 * framework's own (address, reference number and count at deleted = 0, plus destination_port's 3GPP2-WAP flag), so
 * it can only split a framework group, which leaves its rows orphans, and never exclude a row the framework would not
 * reassemble. The accepted cost: a complete undispatched text stays on user 0 until the framework delivers it (on
 * lynx, the day-in-service rescan) or expires it.
 *
 * Pure java.lang / java.util: no Android, no I/O, no clock read. The caller (TelScrub) owns the query, the record
 * file and the deletes; this decides which rows have waited long enough. Every doubt reads in the never-early
 * direction: a malformed record line is skipped, so that row reads as first seen now, and past the cap the lowest
 * ids are kept and the rest read as first seen now at every scan.
 */
final class RawSegmentAge {
    private RawSegmentAge() {}

    /** Q033: 24 hours from first sight. */
    static final long WINDOW_MS = 24L * 60 * 60 * 1000;
    /** Records kept; past it, the lowest ids. */
    static final int CAP = 512;

    /** What a scan does: the record to write back, the ids to remove, and how many it stamped this scan. */
    static final class Plan {
        final TreeMap<Long, Long> record;
        final List<Long> remove;
        final int stamped;

        Plan(TreeMap<Long, Long> record, List<Long> remove, int stamped) {
            this.record = record;
            this.remove = remove;
            this.stamped = stamped;
        }
    }

    /** One deleted = 0 raw row, as rawSegmentAge reads it. A NULL column is null. */
    static final class Row {
        final long id;
        final String address;
        final Integer referenceNumber;
        final Integer count;
        final Integer sequence;
        final Integer destinationPort;

        Row(long id, String address, Integer referenceNumber, Integer count, Integer sequence, Integer destinationPort) {
            this.id = id;
            this.address = address;
            this.referenceNumber = referenceNumber;
            this.count = count;
            this.sequence = sequence;
            this.destinationPort = destinationPort;
        }
    }

    /** #36: the ids of the rows that are not part of a complete text, ascending; the class doc gives the rule. Only
     *  these are handed to plan, so a complete text is never stamped and never removed. */
    static List<Long> orphans(Collection<Row> rows) {
        TreeSet<Long> out = new TreeSet<>();
        Map<List<Object>, List<Row>> groups = new HashMap<>();
        for (Row r : rows) {
            if (r.count != null && r.count == 1) continue;
            if (r.count == null || r.count < 1 || r.sequence == null) {
                out.add(r.id);
                continue;
            }
            groups.computeIfAbsent(Arrays.asList(r.address, r.referenceNumber, r.count, r.destinationPort),
                    k -> new ArrayList<>()).add(r);
        }
        for (List<Row> g : groups.values()) {
            int count = g.get(0).count;
            TreeSet<Integer> seqs = new TreeSet<>();
            for (Row r : g) seqs.add(r.sequence);
            boolean complete = seqs.size() == count && seqs.first() == 1 && seqs.last() == count;
            if (!complete) for (Row r : g) out.add(r.id);
        }
        return new ArrayList<>(out);
    }

    /** id -> first-seen millis from lines `<id> <millis>`. Any other line is skipped (blank, a stray field, a
     *  non-number, a negative one), so that id reads as first seen now and can never expire early. An id met twice
     *  keeps the later stamp. */
    static TreeMap<Long, Long> parse(String text) {
        TreeMap<Long, Long> out = new TreeMap<>();
        if (text == null) return out;
        for (String line : text.split("\n", -1)) {
            if (line.endsWith("\r")) line = line.substring(0, line.length() - 1);
            String[] f = line.split(" ", -1);
            if (f.length != 2) continue;
            long id, ms;
            try {
                id = Long.parseLong(f[0]);
                ms = Long.parseLong(f[1]);
            } catch (NumberFormatException e) {
                continue;
            }
            if (id < 0 || ms < 0) continue;
            Long prev = out.get(id);
            out.put(id, prev == null ? ms : Math.max(prev, ms));
        }
        return out;
    }

    /** `<id> <millis>` per line, ascending id. */
    static String format(Map<Long, Long> record) {
        StringBuilder sb = new StringBuilder();
        for (Map.Entry<Long, Long> e : new TreeMap<>(record).entrySet()) {
            sb.append(e.getKey()).append(' ').append(e.getValue()).append('\n');
        }
        return sb.toString();
    }

    /** One scan. A waiting id with no record, or stamped after now (the clock moved back), is stamped now. One with
     *  now - first >= WINDOW_MS is to be removed and KEEPS its stamp, so a failed delete retries at the next scan
     *  (which drops it once it is gone). A record whose id is no longer waiting is dropped. Past CAP the lowest ids
     *  are kept. */
    static Plan plan(Map<Long, Long> record, Collection<Long> waitingIds, long nowMs) {
        TreeSet<Long> waiting = new TreeSet<>(waitingIds);
        TreeMap<Long, Long> next = new TreeMap<>();
        List<Long> remove = new ArrayList<>();
        int stamped = 0;
        for (Long id : waiting) {
            if (next.size() >= CAP) break;
            Long first = record.get(id);
            if (first == null || first > nowMs) {
                next.put(id, nowMs);
                stamped++;
            } else {
                next.put(id, first);
                if (nowMs - first >= WINDOW_MS) remove.add(id);
            }
        }
        return new Plan(next, remove, stamped);
    }
}
