# pointer_lock

A Flutter plug-in that makes it possible to lock the mouse pointer to its current position
and receive movement deltas while the pointer is locked.

| Windows | macOS | Linux (x11) | Linux (Wayland) |        Web        |
|:-------:|:-----:|:-----------:|:---------------:|:-----------------:|
|   ✔️    |  ✔️   |     ✔️      |       ✔️        | Experimental️ (*) |

## Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  pointer_lock:
    git:
      url: https://github.com/helgoboss/pointer_lock.git
      ref: main
```

## Usage

## Use case 1: Lock pointer while dragging (via widget)

The idea is to lock the pointer when you press a mouse button and unlock it as soon as you release
it. This is useful for widgets such as knobs, drag fields and zoom controls.

This use case is so popular that we have a dedicated widget for it: `PointerLockDragArea`. 
See [drag_example.dart](example/lib/drag_example.dart) to learn more.

If the widget is too restrictive for you, use the stream approach below. The widget itself
is just a convenience. It also uses the stream under the hood.

## Use case 2: Lock and unlock pointer freely (via stream)

The idea is to lock the pointer on some arbitrary event, such as a key or button press,
and unlock it on another arbitrary event. This is useful for applications or games that
are mouse-controlled.

This is how it works:

1. Call `pointerLock.createSession()`.
2. When you are ready, listen to the resulting stream. This will lock the pointer.
3. Process pointer movement events emitted from the stream.
4. When you are done, cancel the stream. This will unlock the pointer

See [free_example.dart](example/lib/free_example.dart) to learn more.

## Platform-specific considerations

### Windows

On Windows, two modes are available: **capture** and **clip**. They differ in the implementation.

Mode **capture** is the recommended mode. It uses the `SetCapture` technique.

Mode **clip** uses the `ClipCursor` technique. This technique comes with the danger of 
stealing raw input focus from other parts of the application. This should be only used if you are
sure that the rest of your Windows application doesn't rely on raw input (`WM_INPUT` messages).

Use whatever works best for you!

### Linux

On X11, the implementation is based on the GDK functions `gdk_pointer_grab` and `gdk_device_warp`: the pointer is
grabbed, and every motion event that reaches Dart asks the native side for the delta, which then warps the pointer back
to where it was locked.

That approach can't work on Wayland:

- Core Wayland has no request that lets a client move the pointer, so the warp can't put it back. (The newer staging
  `pointer-warp-v1` protocol adds one, but GTK 3 doesn't use it, and the protocol itself says it is no reliable way to
  lock the pointer.)
- A grab is not a confinement: the compositor keeps moving the pointer, out of the window if the mouse goes there.
- The warp is asynchronous (motion event → Dart → native warp), so a fast move leaves the window before the warp
  lands, the window stops receiving motion, and the lock is lost.

So on Wayland the plug-in locks natively instead: it asks the compositor to lock the pointer with the
`pointer-constraints-unstable-v1` protocol and reads the deltas from `relative-pointer-unstable-v1`. The native side
drives the session and sends the deltas over the event channel, as on macOS. This brings a few behaviours:

- The session stream ends when the compositor releases the lock, for example when the window loses focus.
- Deltas are only sent once the compositor confirms the lock, so motion before it isn't counted twice (once as a
  pointer move, once as a delta).
- A session that can't lock (for example on a seat without a pointer) reports a `PlatformException` on the stream and
  ends.
- Tested compositor: KWin 6.7.

The Wayland path needs the `wayland-client` development package at build time (`libwayland-dev` on Debian and Ubuntu);
without it, the plug-in builds with the X11 path only. On X11, or on a compositor that lacks either protocol, the GDK
path above is used.

### Web (*)

Experimental web support has landed thanks to a contribution by @damywise.

Known issues:

- Successfully tested on Chrome only.
- On macOS, I observed a an issue in drag mode where releasing the mouse button without dragging
  would leave the pointer locked (#4).

**Further contributions to improve web support are very welcome!**

## Development

### Linux

#### Wayland bindings

The protocol bindings in `linux/include/wayland/` and `linux/wayland/` are generated from the protocol XML in
`linux/protocols/` (copied from wayland-protocols) by `tool/generate_wayland_protocols.sh`, which needs
`wayland-scanner`. They are checked in so that apps using the plug-in build without it; re-run the script after
updating an XML.

#### Room for improvement

There's room for improvement for the Linux platform:

- The Wayland lock is one-shot: once the compositor releases it (for example when the window loses focus), the session
  ends instead of resuming when the window gets focus back. A persistent lock could resume, at the cost of tracking
  the lock across focus changes.
