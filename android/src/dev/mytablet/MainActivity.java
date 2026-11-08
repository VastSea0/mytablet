package dev.mytablet;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.view.Gravity;
import android.widget.FrameLayout;
import android.widget.TextView;
import android.graphics.Color;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Bundle;
import android.provider.Settings;
import android.util.Log;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;

import java.io.DataInputStream;
import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.concurrent.LinkedBlockingQueue;

/** Fullscreen hardware-decoded video sink that streams raw touches back to the Mac. */
public class MainActivity extends Activity implements SurfaceHolder.Callback {
    private static final String TAG = "MyTablet";
    private static final int PORT = 27183, W = 1920, H = 1200;

    private SurfaceView view;
    private volatile Surface surface;
    private final LinkedBlockingQueue<byte[]> outbox = new LinkedBlockingQueue<>();
    private Thread server;
    private volatile boolean running, streaming;
    private KeyClicks clicks;
    private volatile boolean wirelessSession;
    private TextView status;
    private WifiManager.WifiLock wifiLock;
    private NsdManager.RegistrationListener nsdListener;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().getAttributes().layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS;
        getWindow().setDecorFitsSystemWindows(false);
        view = new SurfaceView(this);
        view.setBackgroundColor(Color.TRANSPARENT);
        view.getHolder().setFixedSize(W, H);
        view.getHolder().addCallback(this);
        FrameLayout root = new FrameLayout(this);
        root.addView(view);
        status = new TextView(this);
        status.setTextColor(Color.WHITE);
        status.setTextSize(20);
        status.setText("Mac bekleniyor…");
        root.addView(status, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));
        setContentView(root);
        WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "mytablet");
        wifiLock.setReferenceCounted(false);
        advertise();
        clicks = new KeyClicks(this);
        view.requestUnbufferedDispatch(InputDevice.SOURCE_TOUCHSCREEN);
        hideBars();
        // An edge swipe can reveal the transient system bars; take them away again quickly.
        getWindow().getDecorView().setOnApplyWindowInsetsListener((v, insets) -> {
            if (insets.isVisible(WindowInsets.Type.systemBars())) {
                v.removeCallbacks(rehide);
                v.postDelayed(rehide, 500);
            }
            return v.onApplyWindowInsets(insets);
        });
    }

    private final Runnable rehide = this::hideBars;

    private void hideBars() {
        WindowInsetsController c = getWindow().getInsetsController();
        if (c == null) return;
        c.hide(WindowInsets.Type.systemBars());
        c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
    }

    @Override public void onWindowFocusChanged(boolean f) { if (f) hideBars(); }

    @Override public void surfaceCreated(SurfaceHolder h) {
        surface = h.getSurface();
        if (server == null) { running = true; server = new Thread(this::serve, "server"); server.start(); }
    }
    @Override public void surfaceChanged(SurfaceHolder h, int f, int w, int ht) { }
    @Override public void surfaceDestroyed(SurfaceHolder h) { surface = null; }

    @Override public boolean dispatchTouchEvent(MotionEvent e) {
        int n = Math.min(e.getPointerCount(), 10), mask = e.getActionMasked(), action;
        switch (mask) {
            case MotionEvent.ACTION_DOWN: case MotionEvent.ACTION_POINTER_DOWN: action = 0; break;
            case MotionEvent.ACTION_UP: case MotionEvent.ACTION_POINTER_UP: action = 1; break;
            case MotionEvent.ACTION_MOVE: action = 2; break;
            case MotionEvent.ACTION_CANCEL: action = 3; break;
            default: return true;
        }
        float w = view.getWidth(), h = view.getHeight();
        ByteBuffer b = ByteBuffer.allocate(4 + n * 9);
        b.put((byte) 1).put((byte) action).put((byte) e.getPointerId(e.getActionIndex())).put((byte) n);
        for (int i = 0; i < n; i++) b.put((byte) e.getPointerId(i)).putFloat(e.getX(i) / w).putFloat(e.getY(i) / h);
        outbox.offer(b.array());
        return true;
    }

    private File keyFile() { return new File(getFilesDir(), "pair.key"); }

    private byte[] pairingKey() {
        try { byte[] k = Files.readAllBytes(keyFile().toPath()); return k.length == 32 ? k : null; }
        catch (Exception e) { return null; }
    }

    private void savePairingKey(byte[] data, int len) {
        if (len != 32) return;
        try (FileOutputStream o = new FileOutputStream(keyFile())) { o.write(data, 0, len); }
        catch (Exception e) { Log.w(TAG, "pairing key not saved", e); return; }
        runOnUiThread(this::advertise);
    }

    /** Lets the Mac find this tablet by name after its IP address changes. */
    private void advertise() {
        if (nsdListener != null || pairingKey() == null) return;
        String ip = wifiAddress();
        if (ip == null) return;
        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName("MyTablet");
        info.setServiceType("_mytablet._tcp");
        info.setPort(PORT);
        info.setAttribute("ip", ip);
        nsdListener = new NsdManager.RegistrationListener() {
            @Override public void onRegistrationFailed(NsdServiceInfo i, int e) { Log.w(TAG, "nsd register failed " + e); }
            @Override public void onUnregistrationFailed(NsdServiceInfo i, int e) { }
            @Override public void onServiceRegistered(NsdServiceInfo i) { }
            @Override public void onServiceUnregistered(NsdServiceInfo i) { }
        };
        ((NsdManager) getSystemService(Context.NSD_SERVICE)).registerService(info, NsdManager.PROTOCOL_DNS_SD, nsdListener);
    }

    @SuppressWarnings("deprecation")
    private String wifiAddress() {
        int ip = ((WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE)).getConnectionInfo().getIpAddress();
        if (ip == 0) return null;
        return (ip & 255) + "." + ((ip >> 8) & 255) + "." + ((ip >> 16) & 255) + "." + ((ip >> 24) & 255);
    }

    private void setStatus(boolean visible) { runOnUiThread(() -> status.setVisibility(visible ? View.VISIBLE : View.GONE)); }

    private int readBrightness() {
        try { return Settings.System.getInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS); }
        catch (Exception e) { return 128; }
    }

    private void applyBrightness(int v) {
        try {
            Settings.System.putInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS_MODE, 0);
            Settings.System.putInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, v);
        } catch (Exception e) { Log.w(TAG, "brightness unchanged", e); }
    }

    private void serve() {
        try (ServerSocket ss = new ServerSocket(PORT, 1)) {
            ss.setReuseAddress(true);
            while (running) {
                try (Socket s = ss.accept()) {
                    s.setTcpNoDelay(true);
                    boolean local = s.getInetAddress().isLoopbackAddress();
                    InputStream in; OutputStream out;
                    if (local) { in = s.getInputStream(); out = s.getOutputStream(); }
                    else {
                        // Anything arriving over the network must prove it holds the pairing key first.
                        byte[] key = pairingKey();
                        if (key == null) continue;
                        SecureLink link = SecureLink.accept(s, key);
                        in = link.in; out = link.out;
                    }
                    wirelessSession = !local;
                    out.write(0x4D);
                    runSession(in, out);
                } catch (Exception e) { Log.w(TAG, "session ended", e); }
            }
        } catch (Exception e) { Log.e(TAG, "server", e); }
    }

    /**
     * Android ignores edge swipes while setup is marked incomplete, which is the only thing that fully
     * stops its bars appearing over the stream. Always restored when streaming stops or we leave the screen.
     */
    private void setEdgeGestures(boolean enabled) {
        try { Settings.Secure.putInt(getContentResolver(), "user_setup_complete", enabled ? 1 : 0); }
        catch (SecurityException e) { Log.w(TAG, "edge gestures unchanged", e); }
    }

    @Override protected void onStop() {
        setEdgeGestures(true);
        // With no cable the Mac can't bring this app back, so it does it itself.
        if (streaming && wirelessSession) startActivity(new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
        super.onStop();
    }
    @Override protected void onStart() { super.onStart(); if (streaming) setEdgeGestures(false); }

    private void runSession(InputStream socketIn, OutputStream socketOut) throws Exception {
        while (surface == null) Thread.sleep(50);
        streaming = true;
        setEdgeGestures(false);
        outbox.clear();
        final OutputStream os = socketOut;
        if (wirelessSession) wifiLock.acquire();
        outbox.offer(ByteBuffer.allocate(5).put((byte) 4).putInt(readBrightness()).array());
        Thread writer = new Thread(() -> {
            try { while (true) { byte[] p = outbox.take(); os.write(p); } }
            catch (Exception ignored) { }
        }, "writer");
        writer.setPriority(Thread.MAX_PRIORITY);
        writer.start();

        MediaFormat fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, W, H);
        fmt.setInteger(MediaFormat.KEY_PRIORITY, 0);
        // Without these the decoder's output is treated as the wrong matrix and range, which washes colours out.
        fmt.setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709);
        fmt.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED);
        fmt.setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO);
        fmt.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 * 1024 * 1024);
        MediaCodec codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
        Log.i(TAG, "decoder " + codec.getName());
        if (codec.getCodecInfo().getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
                .isFeatureSupported(android.media.MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)) {
            fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
        }
        try {
            codec.configure(fmt, surface, null, 0);
            codec.start();
        } catch (Exception e) {
            codec.release(); // the T618 only has a handful of hardware decoder slots
            writer.interrupt();
            throw e;
        }

        final java.util.concurrent.atomic.AtomicBoolean live = new java.util.concurrent.atomic.AtomicBoolean(true);
        Thread out = new Thread(() -> drain(codec, live), "drain");
        out.setPriority(Thread.MAX_PRIORITY);
        out.start();

        try {
            DataInputStream in = new DataInputStream(new BufferedInputStream(socketIn, 1 << 18));
            byte[] data = new byte[1 << 20];
            while (true) {
                int type = in.readUnsignedByte();
                int seq = in.readInt();
                long ts = in.readLong();
                int flags = in.readUnsignedByte();
                int len = in.readInt();
                if (len > data.length) data = new byte[len * 2];
                in.readFully(data, 0, len);
                if (type == 3) { clicks.play(seq); continue; }
                if (type == 4) { applyBrightness(seq); continue; }
                if (type == 5) { savePairingKey(data, len); continue; }
                if (type == 2) {
                    outbox.offer(ByteBuffer.allocate(9).put((byte) 3).putLong(ts).array());
                    continue;
                }
                int idx;
                while ((idx = codec.dequeueInputBuffer(20000)) < 0) { }
                ByteBuffer ib = codec.getInputBuffer(idx);
                ib.clear(); ib.put(data, 0, len);
                boolean config = (flags & 1) != 0;
                // The sequence number travels through the decoder as the timestamp so the ack matches the frame.
                codec.queueInputBuffer(idx, 0, len, config ? 0 : seq * 1000L, config ? MediaCodec.BUFFER_FLAG_CODEC_CONFIG : 0);
            }
        } finally {
            streaming = false;
            if (wifiLock.isHeld()) wifiLock.release();
            setEdgeGestures(true);
            setStatus(true);
            live.set(false);
            writer.interrupt();
            out.join(500);
            try { codec.stop(); } catch (Exception ignored) { }
            codec.release();
        }
    }

    private void drain(MediaCodec codec, java.util.concurrent.atomic.AtomicBoolean live) {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        while (live.get()) {
            int i;
            try { i = codec.dequeueOutputBuffer(info, 10000); } catch (IllegalStateException e) { return; }
            if (i < 0) continue;
            codec.releaseOutputBuffer(i, true);
            if (status.getVisibility() == View.VISIBLE) setStatus(false);
            int seq = (int) (info.presentationTimeUs / 1000);
            outbox.offer(ByteBuffer.allocate(13).put((byte) 2).putInt(seq).putLong(System.nanoTime()).array());
        }
    }

    @Override protected void onDestroy() { running = false; setEdgeGestures(true); super.onDestroy(); }
}
