package dev.mytablet;

import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.security.MessageDigest;
import java.security.SecureRandom;

import javax.crypto.Cipher;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** Mutually authenticated, AES-256-GCM encrypted streams for connections arriving over the network. */
final class SecureLink {
    final InputStream in;
    final OutputStream out;

    private SecureLink(InputStream in, OutputStream out) { this.in = in; this.out = out; }

    private static byte[] hmac(byte[] key, String label, byte[] a, byte[] b) throws Exception {
        Mac m = Mac.getInstance("HmacSHA256");
        m.init(new SecretKeySpec(key, "HmacSHA256"));
        m.update(label.getBytes("UTF-8")); m.update(a); m.update(b);
        return m.doFinal();
    }

    /** The Mac must prove it holds the pairing key before it can send or receive anything. */
    static SecureLink accept(Socket s, byte[] psk) throws Exception {
        s.setSoTimeout(3000);
        byte[] nr = new byte[16];
        new SecureRandom().nextBytes(nr);
        OutputStream rawOut = s.getOutputStream();
        DataInputStream rawIn = new DataInputStream(s.getInputStream());
        rawOut.write(nr);
        byte[] nm = new byte[16], proof = new byte[32];
        rawIn.readFully(nm);
        rawIn.readFully(proof);
        if (!MessageDigest.isEqual(proof, hmac(psk, "mytablet-client", nr, nm))) throw new IOException("bad pairing proof");
        rawOut.write(hmac(psk, "mytablet-server", nr, nm));
        s.setSoTimeout(0);
        SecretKeySpec key = new SecretKeySpec(hmac(psk, "mytablet-session", nr, nm), "AES");
        return new SecureLink(new RecordIn(rawIn, key), new RecordOut(rawOut, key));
    }

    private static GCMParameterSpec nonce(int direction, long counter) {
        return new GCMParameterSpec(128, ByteBuffer.allocate(12).putInt(direction).putLong(counter).array());
    }

    private static final class RecordIn extends InputStream {
        private final DataInputStream raw;
        private final SecretKeySpec key;
        private long counter;
        private byte[] plain = new byte[0];
        private int pos;

        RecordIn(DataInputStream raw, SecretKeySpec key) { this.raw = raw; this.key = key; }

        private void fill() throws IOException {
            int n = raw.readInt();
            if (n < 16 || n > 32 * 1024 * 1024) throw new IOException("bad record");
            byte[] rec = new byte[n];
            raw.readFully(rec);
            try {
                Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
                c.init(Cipher.DECRYPT_MODE, key, nonce(1, counter++));
                plain = c.doFinal(rec);
                pos = 0;
            } catch (Exception e) { throw new IOException("record rejected", e); }
        }

        @Override public int read() throws IOException {
            while (pos >= plain.length) fill();
            return plain[pos++] & 0xff;
        }

        @Override public int read(byte[] b, int off, int len) throws IOException {
            while (pos >= plain.length) fill();
            int n = Math.min(len, plain.length - pos);
            System.arraycopy(plain, pos, b, off, n);
            pos += n;
            return n;
        }
    }

    private static final class RecordOut extends OutputStream {
        private final OutputStream raw;
        private final SecretKeySpec key;
        private long counter;

        RecordOut(OutputStream raw, SecretKeySpec key) { this.raw = raw; this.key = key; }

        @Override public void write(int b) throws IOException { write(new byte[]{(byte) b}, 0, 1); }

        @Override public void write(byte[] b, int off, int len) throws IOException {
            try {
                Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
                c.init(Cipher.ENCRYPT_MODE, key, nonce(2, counter++));
                byte[] ct = c.doFinal(b, off, len);
                raw.write(ByteBuffer.allocate(4 + ct.length).putInt(ct.length).put(ct).array());
            } catch (IOException e) { throw e; } catch (Exception e) { throw new IOException(e); }
        }
    }
}
