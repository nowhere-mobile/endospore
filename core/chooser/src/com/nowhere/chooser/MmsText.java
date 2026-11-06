package com.nowhere.chooser;

import com.google.android.mms.pdu.CharacterSets;

import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;

/** NWP-20261117-24: an MMS text part reaches SEAL-MMS as UTF-8. The SEAL-MMS wire carries no charset, and every
 *  reader (TelIngest.insertMmsPart, TelIngest.deliverMms's preview, the owner inbox) decodes a text part as UTF-8,
 *  so the gate -- the one place PduPart.getCharset is still known -- transcodes here. An unset (0), UTF-8 (106) or
 *  US-ASCII (3) label passes through: ASCII is a subset of UTF-8, so a pure-ASCII part is already UTF-8, and a byte
 *  over 0x7F under that label means the label is wrong, where the UTF-8 read is the better guess and a US-ASCII
 *  decode would make it U+FFFD. An unknown or unsupported charset passes through too, and so does any throw: best
 *  effort, never worse than the UTF-8 read every reader did before. java.* and CharacterSets only, so
 *  test-mms-text-java.sh compiles it off the build host. */
final class MmsText {
    private MmsText() {}

    /** The parts TelIngest.insertMmsPart stores as text (chset 106), and so the parts the gate transcodes. */
    static boolean storedAsText(String ct) {
        return ct != null && (ct.startsWith("text/") || "application/smil".equals(ct));
    }

    /** data as UTF-8 when ct is stored as text and mib names another charset Java supports; else data unchanged. */
    static byte[] toUtf8(String ct, int mib, byte[] data) {
        if (data == null || !storedAsText(ct)) return data;
        if (mib == CharacterSets.ANY_CHARSET || mib == CharacterSets.UTF_8
                || mib == CharacterSets.US_ASCII) return data;
        try {
            String name = CharacterSets.getMimeName(mib);
            if (!Charset.isSupported(name)) return data;
            return new String(data, Charset.forName(name)).getBytes(StandardCharsets.UTF_8);
        } catch (Exception e) {
            return data;
        }
    }
}
