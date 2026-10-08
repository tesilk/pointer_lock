#ifndef POINTER_LOCK_WAYLAND_POINTER_LOCK_H_
#define POINTER_LOCK_WAYLAND_POINTER_LOCK_H_

#include <flutter_linux/flutter_linux.h>

bool wayland_pointer_lock_is_available(FlView* view);

bool wayland_pointer_lock_begin(FlView* view, FlEventChannel* channel, bool unlock_on_pointer_up);

void wayland_pointer_lock_end();

#endif  // POINTER_LOCK_WAYLAND_POINTER_LOCK_H_
