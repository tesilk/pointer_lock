#include "wayland_pointer_lock.h"

#include <gtk/gtk.h>

#if defined(POINTER_LOCK_HAS_WAYLAND) && defined(GDK_WINDOWING_WAYLAND)

#include <gdk/gdkwayland.h>

#include <cstring>

#include "wayland/pointer-constraints-unstable-v1-client-protocol.h"
#include "wayland/relative-pointer-unstable-v1-client-protocol.h"

namespace
{
struct WaylandGlobals
{
    bool has_queried_registry = false;
    zwp_pointer_constraints_v1* pointer_constraints = nullptr;
    zwp_relative_pointer_manager_v1* relative_pointer_manager = nullptr;
};

struct WaylandPointerLockSession
{
    FlEventChannel* channel = nullptr;
    GtkWidget* view = nullptr;
    zwp_locked_pointer_v1* locked_pointer = nullptr;
    zwp_relative_pointer_v1* relative_pointer = nullptr;
    bool is_locked = false;
    gulong button_release_hook_id = 0;
};

WaylandGlobals globals;
WaylandPointerLockSession session;

void handle_registry_global(void*, wl_registry* registry, uint32_t name, const char* interface, uint32_t)
{
    if (strcmp(interface, zwp_pointer_constraints_v1_interface.name) == 0)
    {
        globals.pointer_constraints = static_cast<zwp_pointer_constraints_v1*>(
            wl_registry_bind(registry, name, &zwp_pointer_constraints_v1_interface, 1));
    }
    else if (strcmp(interface, zwp_relative_pointer_manager_v1_interface.name) == 0)
    {
        globals.relative_pointer_manager = static_cast<zwp_relative_pointer_manager_v1*>(
            wl_registry_bind(registry, name, &zwp_relative_pointer_manager_v1_interface, 1));
    }
}

void handle_registry_global_remove(void*, wl_registry*, uint32_t)
{
}

const wl_registry_listener registry_listener = {handle_registry_global, handle_registry_global_remove};

void end_session_stream()
{
    g_autoptr(FlEventChannel) channel = FL_EVENT_CHANNEL(g_object_ref(session.channel));
    wayland_pointer_lock_end();
    fl_event_channel_send_end_of_stream(channel, nullptr, nullptr);
}

void handle_locked(void*, zwp_locked_pointer_v1*)
{
    session.is_locked = true;
}

void handle_unlocked(void*, zwp_locked_pointer_v1*)
{
    end_session_stream();
}

const zwp_locked_pointer_v1_listener locked_pointer_listener = {handle_locked, handle_unlocked};

void handle_relative_motion(void*, zwp_relative_pointer_v1*, uint32_t, uint32_t, wl_fixed_t dx, wl_fixed_t dy,
                            wl_fixed_t, wl_fixed_t)
{
    // Until the compositor confirms the lock, the pointer still moves on screen, so the motion is no delta.
    if (!session.is_locked)
    {
        return;
    }
    double delta[] = {wl_fixed_to_double(dx), wl_fixed_to_double(dy)};
    g_autoptr(FlValue) event = fl_value_new_float_list(delta, 2);
    fl_event_channel_send(session.channel, event, nullptr, nullptr);
}

const zwp_relative_pointer_v1_listener relative_pointer_listener = {handle_relative_motion};

guint button_release_signal_id()
{
    return g_signal_lookup("button-release-event", GTK_TYPE_WIDGET);
}

// FlView handles buttons on an inner widget that stops the emission, so only a hook sees the release before Flutter.
gboolean end_session_on_button_release(GSignalInvocationHint*, guint, const GValue* param_values, gpointer)
{
    GtkWidget* widget = GTK_WIDGET(g_value_get_object(&param_values[0]));
    if (widget != session.view && !gtk_widget_is_ancestor(widget, session.view))
    {
        return TRUE;
    }
    // Returning FALSE removes the hook.
    session.button_release_hook_id = 0;
    end_session_stream();
    return FALSE;
}
}  // namespace

bool wayland_pointer_lock_is_available(FlView* view)
{
    if (view == nullptr)
    {
        return false;
    }
    GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(view));
    if (!GDK_IS_WAYLAND_DISPLAY(display))
    {
        return false;
    }
    if (!globals.has_queried_registry)
    {
        globals.has_queried_registry = true;
        wl_display* wayland_display = gdk_wayland_display_get_wl_display(display);
        // A private queue keeps the roundtrip from dispatching GDK's pending events out of turn.
        wl_event_queue* registry_queue = wl_display_create_queue(wayland_display);
        wl_registry* registry = wl_display_get_registry(wayland_display);
        wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(registry), registry_queue);
        wl_registry_add_listener(registry, &registry_listener, nullptr);
        // The registry announces its globals as events; one roundtrip delivers all of them.
        wl_display_roundtrip_queue(wayland_display, registry_queue);
        wl_registry_destroy(registry);
        // Objects made from these inherit their queue, and only GDK dispatches the default one.
        if (globals.pointer_constraints != nullptr)
        {
            wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(globals.pointer_constraints), nullptr);
        }
        if (globals.relative_pointer_manager != nullptr)
        {
            wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(globals.relative_pointer_manager), nullptr);
        }
        wl_event_queue_destroy(registry_queue);
    }
    return globals.pointer_constraints != nullptr && globals.relative_pointer_manager != nullptr;
}

bool wayland_pointer_lock_begin(FlView* view, FlEventChannel* channel, bool unlock_on_pointer_up)
{
    wayland_pointer_lock_end();
    if (!wayland_pointer_lock_is_available(view))
    {
        return false;
    }
    GtkWidget* view_widget = GTK_WIDGET(view);
    GdkWindow* toplevel_window = gtk_widget_get_window(gtk_widget_get_toplevel(view_widget));
    GdkDevice* pointer_device = gdk_seat_get_pointer(gdk_display_get_default_seat(gtk_widget_get_display(view_widget)));
    if (toplevel_window == nullptr || pointer_device == nullptr)
    {
        return false;
    }
    wl_surface* surface = gdk_wayland_window_get_wl_surface(toplevel_window);
    wl_pointer* pointer = gdk_wayland_device_get_wl_pointer(pointer_device);
    if (surface == nullptr || pointer == nullptr)
    {
        return false;
    }
    session.channel = FL_EVENT_CHANNEL(g_object_ref(channel));
    session.view = GTK_WIDGET(g_object_ref(view_widget));
    session.locked_pointer = zwp_pointer_constraints_v1_lock_pointer(
        globals.pointer_constraints, surface, pointer, nullptr, ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_ONESHOT);
    zwp_locked_pointer_v1_add_listener(session.locked_pointer, &locked_pointer_listener, nullptr);
    session.relative_pointer =
        zwp_relative_pointer_manager_v1_get_relative_pointer(globals.relative_pointer_manager, pointer);
    zwp_relative_pointer_v1_add_listener(session.relative_pointer, &relative_pointer_listener, nullptr);
    if (unlock_on_pointer_up)
    {
        session.button_release_hook_id = g_signal_add_emission_hook(
            button_release_signal_id(), 0, end_session_on_button_release, nullptr, nullptr);
    }
    return true;
}

void wayland_pointer_lock_end()
{
    if (session.button_release_hook_id != 0)
    {
        g_signal_remove_emission_hook(button_release_signal_id(), session.button_release_hook_id);
    }
    if (session.relative_pointer != nullptr)
    {
        zwp_relative_pointer_v1_destroy(session.relative_pointer);
    }
    if (session.locked_pointer != nullptr)
    {
        zwp_locked_pointer_v1_destroy(session.locked_pointer);
    }
    if (session.view != nullptr)
    {
        g_object_unref(session.view);
    }
    if (session.channel != nullptr)
    {
        g_object_unref(session.channel);
    }
    session = {};
}

#else

bool wayland_pointer_lock_is_available(FlView*)
{
    return false;
}

bool wayland_pointer_lock_begin(FlView*, FlEventChannel*, bool)
{
    return false;
}

void wayland_pointer_lock_end()
{
}

#endif
