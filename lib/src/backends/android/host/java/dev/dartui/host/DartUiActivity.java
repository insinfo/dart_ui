package dev.dartui.host;

import android.app.Activity;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.InputType;
import android.util.Log;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.Window;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;

import java.io.BufferedReader;
import java.io.EOFException;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;

import android.net.LocalServerSocket;
import android.net.LocalSocket;

/**
 * The window of a dart_ui application on Android.
 *
 * <p>This activity owns everything Android insists on owning - the UI thread,
 * the {@link SurfaceView}, input, the lifecycle - and starts the Dart VM as a
 * child process from the native-library directory. The two talk over one
 * Unix socket in the abstract namespace; the protocol is described in
 * {@code android_host_protocol.dart}, and the numbers below must match it.
 * Frames arrive as shared memory ({@code memfd}) whose descriptors ride on
 * the socket; this side copies them into a bitmap and draws it.
 *
 * <p>No JNI and no native code of its own: the VM is an executable.
 */
public final class DartUiActivity extends Activity implements SurfaceHolder.Callback {
  private static final String TAG = "dart_ui";
  private static final int PROTOCOL_VERSION = 1;

  // Host -> Dart.
  private static final int HELLO = 1;
  private static final int RESIZED = 2;
  private static final int POINTER = 3;
  private static final int KEY = 4;
  private static final int TEXT = 5;
  private static final int FOCUS = 6;
  private static final int VISIBILITY = 7;
  private static final int BACK = 8;
  private static final int PRESENTED = 9;
  private static final int SCROLL = 10;
  private static final int SURFACE_LOST = 11;

  // Dart -> host.
  private static final int SURFACE = 101;
  private static final int PRESENT = 102;
  private static final int TITLE = 103;
  private static final int KEYBOARD = 104;
  private static final int QUIT = 105;

  private static final int ACTION_DOWN = 0;
  private static final int ACTION_MOVE = 1;
  private static final int ACTION_UP = 2;
  private static final int ACTION_CANCEL = 3;

  private final Handler ui = new Handler(Looper.getMainLooper());
  private final Object lock = new Object();
  private final Bitmap[] bitmaps = new Bitmap[2];
  private final MappedByteBuffer[] frames = new MappedByteBuffer[2];

  private HostView view;
  private LocalServerSocket server;
  private LocalSocket socket;
  private OutputStream out;
  private Process dart;
  private volatile boolean finishing;

  // Guarded by lock.
  private SurfaceHolder holder;
  private int widthPx;
  private int heightPx;
  private boolean helloSent;

  @Override
  protected void onCreate(Bundle state) {
    super.onCreate(state);
    requestWindowFeature(Window.FEATURE_NO_TITLE);
    view = new HostView(this);
    view.getHolder().addCallback(this);
    setContentView(view);
    view.requestFocus();
    String name = "dart_ui-" + android.os.Process.myPid() + "-" + SystemClock.uptimeMillis();
    try {
      server = new LocalServerSocket(name);
      startDart(name);
    } catch (IOException e) {
      Log.e(TAG, "could not start the Dart process", e);
      finish();
      return;
    }
    Thread reader = new Thread(this::serve, "dart_ui-host");
    reader.setDaemon(true);
    reader.start();
  }

  private void startDart(String socketName) throws IOException {
    String libs = getApplicationInfo().nativeLibraryDir;
    ProcessBuilder builder = new ProcessBuilder(libs + "/libdartvm.so", libs + "/libdartui_app.so");
    builder.environment().put("DART_UI_ANDROID_SOCKET", socketName);
    builder.environment().put("HOME", getFilesDir().getAbsolutePath());
    builder.environment().put("TMPDIR", getCacheDir().getAbsolutePath());
    String backend = getIntent().getStringExtra("dart_ui_backend");
    if (backend != null) builder.environment().put("DART_UI_BACKEND", backend);
    builder.redirectErrorStream(true);
    dart = builder.start();
    Thread log = new Thread(() -> {
      try (BufferedReader lines = new BufferedReader(
          new InputStreamReader(dart.getInputStream(), StandardCharsets.UTF_8))) {
        for (String line; (line = lines.readLine()) != null; ) Log.i(TAG, line);
      } catch (IOException ignored) {
        // The process is gone; the socket says so too.
      }
      int code = waitFor(dart);
      Log.i(TAG, "Dart process exited with " + code);
      ui.post(this::finish);
    }, "dart_ui-log");
    log.setDaemon(true);
    log.start();
  }

  private static int waitFor(Process process) {
    try {
      return process.waitFor();
    } catch (InterruptedException e) {
      return -1;
    }
  }

  // ---------------------------------------------------------------------------
  // The socket
  // ---------------------------------------------------------------------------

  private void serve() {
    try {
      LocalSocket accepted = server.accept();
      synchronized (lock) {
        socket = accepted;
        out = accepted.getOutputStream();
      }
      maybeSendHello();
      InputStream in = accepted.getInputStream();
      byte[] header = new byte[4];
      while (true) {
        readFully(in, header, 4);
        int length = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN).getInt();
        if (length < 2 || length > (1 << 20)) throw new IOException("frame of " + length + " bytes");
        byte[] body = new byte[length];
        readFully(in, body, length);
        FileDescriptor[] fds = accepted.getAncillaryFileDescriptors();
        ByteBuffer frame = ByteBuffer.wrap(body).order(ByteOrder.LITTLE_ENDIAN);
        handle(frame.getShort() & 0xFFFF, frame, fds);
      }
    } catch (IOException e) {
      if (!finishing) Log.i(TAG, "host socket closed: " + e.getMessage());
    }
    ui.post(this::finish);
  }

  private static void readFully(InputStream in, byte[] into, int length) throws IOException {
    int read = 0;
    while (read < length) {
      int n = in.read(into, read, length - read);
      if (n < 0) throw new EOFException();
      read += n;
    }
  }

  private void handle(int type, ByteBuffer p, FileDescriptor[] fds) throws IOException {
    switch (type) {
      case SURFACE: {
        int slot = p.getInt();
        int width = p.getInt();
        int height = p.getInt();
        int stride = p.getInt();
        long size = p.getLong();
        if (fds == null || fds.length == 0) throw new IOException("SURFACE without a descriptor");
        if (slot < 0 || slot > 1 || stride != width * 4) throw new IOException("bad SURFACE " + slot + "/" + stride);
        MappedByteBuffer mapped;
        try (FileInputStream file = new FileInputStream(fds[0])) {
          mapped = file.getChannel().map(FileChannel.MapMode.READ_ONLY, 0, size);
        }
        synchronized (lock) {
          frames[slot] = mapped;
          bitmaps[slot] = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        }
        break;
      }
      case PRESENT: {
        int slot = p.getInt();
        draw(slot);
        sendInt(PRESENTED, slot);
        break;
      }
      case TITLE: {
        String title = new String(p.array(), p.position(), p.remaining(), StandardCharsets.UTF_8);
        ui.post(() -> setTitle(title));
        break;
      }
      case KEYBOARD: {
        boolean show = p.get() != 0;
        ui.post(() -> showKeyboard(show));
        break;
      }
      case QUIT:
        finishing = true;
        ui.post(this::finish);
        break;
      default:
        Log.w(TAG, "unknown message " + type);
    }
  }

  private void draw(int slot) {
    synchronized (lock) {
      MappedByteBuffer frame = slot >= 0 && slot < 2 ? frames[slot] : null;
      Bitmap bitmap = slot >= 0 && slot < 2 ? bitmaps[slot] : null;
      if (holder == null || frame == null || bitmap == null) return;
      frame.rewind();
      bitmap.copyPixelsFromBuffer(frame);
      Canvas canvas = Build.VERSION.SDK_INT >= 26 ? holder.lockHardwareCanvas() : holder.lockCanvas();
      if (canvas == null) return;
      try {
        canvas.drawBitmap(bitmap, 0, 0, null);
      } finally {
        holder.unlockCanvasAndPost(canvas);
      }
    }
  }

  private void maybeSendHello() {
    synchronized (lock) {
      if (helloSent || out == null || holder == null || widthPx <= 0) return;
      ByteBuffer p = payload(14);
      p.putShort((short) PROTOCOL_VERSION).putInt(widthPx).putInt(heightPx).putInt(densityMilli());
      send(HELLO, p);
      helloSent = true;
    }
  }

  private int densityMilli() {
    return Math.round(getResources().getDisplayMetrics().density * 1000);
  }

  private static ByteBuffer payload(int length) {
    return ByteBuffer.allocate(length).order(ByteOrder.LITTLE_ENDIAN);
  }

  private void sendInt(int type, int value) {
    send(type, payload(4).putInt(value));
  }

  private void sendByte(int type, boolean value) {
    send(type, payload(1).put((byte) (value ? 1 : 0)));
  }

  private void send(int type, ByteBuffer p) {
    byte[] body = p.array();
    ByteBuffer frame = ByteBuffer.allocate(6 + body.length).order(ByteOrder.LITTLE_ENDIAN);
    frame.putInt(2 + body.length).putShort((short) type).put(body);
    synchronized (lock) {
      if (out == null) return;
      try {
        out.write(frame.array());
      } catch (IOException e) {
        Log.w(TAG, "send failed: " + e.getMessage());
      }
    }
  }

  // ---------------------------------------------------------------------------
  // The surface
  // ---------------------------------------------------------------------------

  @Override
  public void surfaceCreated(SurfaceHolder created) {}

  @Override
  public void surfaceChanged(SurfaceHolder changed, int format, int width, int height) {
    synchronized (lock) {
      holder = changed;
      widthPx = width;
      heightPx = height;
      if (helloSent) {
        send(RESIZED, payload(12).putInt(width).putInt(height).putInt(densityMilli()));
      }
    }
    maybeSendHello();
  }

  @Override
  public void surfaceDestroyed(SurfaceHolder destroyed) {
    synchronized (lock) {
      holder = null;
      if (helloSent) send(SURFACE_LOST, payload(0));
    }
  }

  // ---------------------------------------------------------------------------
  // Input and lifecycle
  // ---------------------------------------------------------------------------

  private void pointer(int action, MotionEvent e, int index) {
    ByteBuffer p = payload(30);
    p.put((byte) action)
        .putInt(e.getPointerId(index))
        .putFloat(e.getX(index))
        .putFloat(e.getY(index))
        .putFloat(e.getPressure(index))
        .put((byte) e.getToolType(index))
        .putLong(e.getEventTime() * 1000000L)
        .putInt(e.getButtonState());
    send(POINTER, p);
  }

  boolean onTouch(MotionEvent e) {
    switch (e.getActionMasked()) {
      case MotionEvent.ACTION_DOWN:
      case MotionEvent.ACTION_POINTER_DOWN:
        pointer(ACTION_DOWN, e, e.getActionIndex());
        return true;
      case MotionEvent.ACTION_MOVE:
        for (int i = 0; i < e.getPointerCount(); i++) pointer(ACTION_MOVE, e, i);
        return true;
      case MotionEvent.ACTION_UP:
      case MotionEvent.ACTION_POINTER_UP:
        pointer(ACTION_UP, e, e.getActionIndex());
        return true;
      case MotionEvent.ACTION_CANCEL:
        for (int i = 0; i < e.getPointerCount(); i++) pointer(ACTION_CANCEL, e, i);
        return true;
      default:
        return false;
    }
  }

  boolean onGeneric(MotionEvent e) {
    if (!e.isFromSource(InputDevice.SOURCE_CLASS_POINTER)) return false;
    switch (e.getActionMasked()) {
      case MotionEvent.ACTION_HOVER_MOVE:
        pointer(ACTION_MOVE, e, 0);
        return true;
      case MotionEvent.ACTION_SCROLL:
        send(SCROLL, payload(16)
            .putFloat(e.getX())
            .putFloat(e.getY())
            .putFloat(e.getAxisValue(MotionEvent.AXIS_HSCROLL))
            .putFloat(e.getAxisValue(MotionEvent.AXIS_VSCROLL)));
        return true;
      default:
        return false;
    }
  }

  @Override
  public boolean dispatchKeyEvent(KeyEvent e) {
    int code = e.getKeyCode();
    if (code == KeyEvent.KEYCODE_BACK) {
      if (e.getAction() == KeyEvent.ACTION_UP) send(BACK, payload(0));
      return true;
    }
    if (code == KeyEvent.KEYCODE_VOLUME_UP
        || code == KeyEvent.KEYCODE_VOLUME_DOWN
        || code == KeyEvent.KEYCODE_VOLUME_MUTE) {
      return super.dispatchKeyEvent(e);
    }
    if (e.getAction() == KeyEvent.ACTION_MULTIPLE && code == KeyEvent.KEYCODE_UNKNOWN) {
      sendText(e.getCharacters());
      return true;
    }
    boolean down = e.getAction() == KeyEvent.ACTION_DOWN;
    ByteBuffer p = payload(21);
    p.put((byte) (down ? 1 : 0))
        .putInt(code)
        .putInt(e.getScanCode())
        .putInt(e.getMetaState())
        .putInt(e.getUnicodeChar(e.getMetaState()))
        .putInt(e.getRepeatCount());
    send(KEY, p);
    return true;
  }

  void sendText(CharSequence text) {
    if (text == null || text.length() == 0) return;
    send(TEXT, ByteBuffer.wrap(text.toString().getBytes(StandardCharsets.UTF_8)));
  }

  private void showKeyboard(boolean show) {
    InputMethodManager input = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
    if (input == null) return;
    if (show) {
      view.requestFocus();
      input.showSoftInput(view, 0);
    } else {
      input.hideSoftInputFromWindow(view.getWindowToken(), 0);
    }
  }

  @Override
  public void onWindowFocusChanged(boolean focused) {
    super.onWindowFocusChanged(focused);
    sendByte(FOCUS, focused);
  }

  @Override
  protected void onStart() {
    super.onStart();
    sendByte(VISIBILITY, true);
  }

  @Override
  protected void onStop() {
    sendByte(VISIBILITY, false);
    super.onStop();
  }

  @Override
  protected void onDestroy() {
    finishing = true;
    try {
      if (socket != null) socket.close();
      if (server != null) server.close();
    } catch (IOException ignored) {
      // Closing on the way out.
    }
    if (dart != null) dart.destroy();
    super.onDestroy();
  }

  /** The surface, plus what it takes to be a text editor for the IME. */
  private final class HostView extends SurfaceView {
    HostView(Context context) {
      super(context);
      setFocusable(true);
      setFocusableInTouchMode(true);
    }

    @Override
    public boolean onTouchEvent(MotionEvent e) {
      return onTouch(e);
    }

    @Override
    public boolean onGenericMotionEvent(MotionEvent e) {
      return onGeneric(e) || super.onGenericMotionEvent(e);
    }

    @Override
    public boolean onCheckIsTextEditor() {
      return true;
    }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo info) {
      info.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
      info.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN | EditorInfo.IME_ACTION_NONE;
      return new BaseInputConnection(this, false) {
        @Override
        public boolean commitText(CharSequence text, int newCursorPosition) {
          sendText(text);
          return true;
        }

        @Override
        public boolean deleteSurroundingText(int before, int after) {
          for (int i = 0; i < before; i++) {
            dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DEL));
            dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DEL));
          }
          return true;
        }
      };
    }
  }
}
