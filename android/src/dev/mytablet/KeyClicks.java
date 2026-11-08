package dev.mytablet;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.SoundPool;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Random;

/** Soft keyboard clicks, synthesized at startup so the project ships no third-party audio. */
final class KeyClicks {
    private static final int RATE = 44100;
    private final SoundPool pool;
    private final int[] ids = new int[3];

    KeyClicks(Context c) {
        pool = new SoundPool.Builder().setMaxStreams(4)
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .setFlags(AudioAttributes.FLAG_LOW_LATENCY).build()).build();
        ids[0] = load(c, "letter", 2600, 0.012f, 0.55f);
        ids[1] = load(c, "delete", 1500, 0.020f, 0.60f);
        ids[2] = load(c, "modifier", 1900, 0.016f, 0.50f);
    }

    void play(int kind) {
        if (kind >= 0 && kind < ids.length) pool.play(ids[kind], 0.7f, 0.7f, 1, 0, 1f);
    }

    /** A short damped tone with a noise transient, like a light tap on glass. */
    private int load(Context c, String name, float hz, float decay, float gain) {
        int n = (int) (RATE * 0.05f);
        ByteBuffer pcm = ByteBuffer.allocate(44 + n * 2).order(ByteOrder.LITTLE_ENDIAN);
        pcm.put("RIFF".getBytes()).putInt(36 + n * 2).put("WAVEfmt ".getBytes()).putInt(16)
           .putShort((short) 1).putShort((short) 1).putInt(RATE).putInt(RATE * 2)
           .putShort((short) 2).putShort((short) 16).put("data".getBytes()).putInt(n * 2);
        Random noise = new Random(name.hashCode());
        for (int i = 0; i < n; i++) {
            float t = i / (float) RATE;
            float tone = (float) Math.sin(2 * Math.PI * hz * t) * (float) Math.exp(-t / decay);
            float tick = (noise.nextFloat() * 2 - 1) * (float) Math.exp(-t / 0.002f);
            pcm.putShort((short) (Math.max(-1f, Math.min(1f, (tone * 0.7f + tick * 0.5f) * gain)) * 32767));
        }
        File f = new File(c.getCacheDir(), "click_" + name + ".wav");
        try (FileOutputStream o = new FileOutputStream(f)) { o.write(pcm.array()); } catch (Exception e) { return 0; }
        return pool.load(f.getPath(), 1);
    }
}
