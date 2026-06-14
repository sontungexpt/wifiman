# Flow

## Startup

```
main.vala
  └─ Application.run ()
       └─ Application.activate ()
            └─ new MainWindow (application)
                 ├─ new NetworkManagerService ()
                 │    ├─ new NM.Client ()
                 │    ├─ connect_client_signals ()
                 │    ├─ connect_wifi_device ()  ← for each existing wifi device
                 │    └─ connect_active_connection ()  ← for each existing active connection
                 ├─ new WifiViewModel (nm_service)
                 │    ├─ connect service.changed → schedule_rebuild ()
                 │    ├─ connect service.scan_started → scanning = true
                 │    ├─ connect service.scan_finished → scanning = false, schedule_rebuild ()
                 │    ├─ rebuild ()  ← initial snapshot (read-only, _started == false)
                 │    │               └─ refresh_runtime_details ()  ← sets connectivity state
                 │    ├─ start_background_scan ()
                 │    ├─ freshness_timer_id = Timeout.add_seconds (5, tick_freshness)
                 │    └─ _started = true
                 └─ manager.scan.begin ()
```

Key: the initial `rebuild()` runs before `_started = true`, so `try_auto_connect_all()` is skipped. No connection state is modified on startup.

## Scan cycle

```
User clicks refresh  OR  background_timer fires  OR  NM signal received
       │
       ▼
  scan.begin ()
       │
       ├─ service.request_scan ()
       │    ├─ scan_started ()  ← emitted
       │    ├─ device.request_scan_async ()  ← NM scan (read-only)
       │    └─ scan_finished ()  ← emitted
       │
       ▼
  schedule_rebuild ()
       │  (120ms debounce)
       ▼
  rebuild ()
       ├─ networks_by_ssid.remove_all ()
       ├─ iterate devices → get_access_points () → add_or_update_access_point ()
       ├─ apply_saved_connections ()
       ├─ apply_active_connections ()
       ├─ refresh_runtime_details ()
       ├─ update_scan_freshness ()  ← stores timestamp, calls apply_freshness()
       ├─ rebuild_items ()  ← rebuilds ListStore from networks_by_ssid
       │    ├─ sort connected networks
       │    ├─ sort available networks
       │    └─ append_section () for Connected + Available
       │
       └─ try_auto_connect_all ()  ← guarded by _started && auto_reconnect_enabled && !has_active_wifi_connection()
            └─ for each saved + visible + not-connected network:
                 └─ try_auto_connect.begin (network)
                      ├─ checks cooldowns
                      ├─ calls service.connect_network ()
                      └─ on error: clears auto-connecting state
```

Scanning is read-only. It never modifies NM connection state — only reads AP lists and active connections.

## UI update flow

```
NM signal  →  service.changed  →  WifiViewModel.schedule_rebuild ()
                                      │ (120ms debounce)
                                      ▼
                                  rebuild ()
                                      │
                                      ▼
                                  rebuild_items ()
                                      │
                                      ▼
                                  items.items_changed  →  MainWindow.render_networks ()
                                      │
                                      ├─ clear hero container + listbox
                                      ├─ iterate items ListStore
                                      │    ├─ HEADER → section row
                                      │    ├─ NETWORK + is_connected → hero row
                                      │    └─ NETWORK + !is_connected → list row
                                      └─ update visibility flags
```

## Auto-connect safety

```
try_auto_connect_all () / try_auto_connect ()
       │
       ├─ !_started?  →  return  (startup guard)
       ├─ !auto_reconnect_enabled?  →  return  (toggle guard)
       ├─ has_active_wifi_connection ()?  →  return  (active connection guard)
       │    ├─ iterates NM active connections
       │    └─ returns true if any wifi is ACTIVATED or ACTIVATING
       ├─ network.is_connected?  →  return
       ├─ network.saved_connection == null?  →  return
        ├─ network.access_point == null?  →  return
        ├─ auto_connect_cooldown active?  →  return  (20s timer)
        ├─ disconnect_cooldown active?  →  return  (30s timer)
        └─ auto_connect_failures.contains (ssid)?  →  return
               │
               ▼
         service.connect_network ()
              │
              └─ client.activate_connection_async ()
```

Auto-connect only reaches NM when:
- App has started (`_started`)
- Feature is enabled (`auto_reconnect_enabled`)
- No wifi connection is active (`has_active_wifi_connection()`)
- Individual network passes its own checks (including not in `auto_connect_failures`)

## Signal flow

```
NM signal changes
       │
       ▼
  service.changed
       │
       └─ schedule_rebuild ()  →  rebuild ()
                                     │
                                     ├─ refresh_runtime_details ()  ← sets connectivity state too
                                     ├─ update_scan_freshness ()
                                     ├─ rebuild_items ()
                                     └─ try_auto_connect_all ()

                                     (every 5s)
                                         │
                                    tick_freshness ()
                                         │
                                    apply_freshness ()
                                         │
                                    notify_property ("scan-freshness")
```

The 5-second freshness timer is independent of rebuilds — it re-formats the stored `freshest_scan` timestamp so the label updates in real time between scans.

Connectivity state is refreshed inside `rebuild()` via `refresh_runtime_details()`, so the separate `changed → update_connectivity_state()` signal handler was redundant and removed.

## User actions

```
User clicks "Connect" (open network)
  └─ activate_network ()
       └─ connect_network.begin ()
            └─ manager.connect_network ()
                 └─ service.connect_network ()
                      └─ client.add_and_activate_connection_async ()

User clicks "Connect" (secured, dialog)
  └─ show_connect_dialog ()
       ├─ _connect_dialog_active = true
       ├─ password_entry.activate  →  manager.connect_network.begin (password)
       │    └─ async callback:
       │         ├─ !_connect_dialog_active?  →  return  (dialog was closed)
       │         ├─ success → dialog.destroy ()
       │         └─ error → show error, re-enable button
       ├─ connect.clicked  →  same flow
       ├─ close_request:
       │    ├─ _connect_dialog_active = false
       │    ├─ manager.cancel_manual_connect ()
       │    │    ├─ _manual_connecting = false
       │    │    └─ Source.remove (_manual_connect_timeout_id)
       │    ├─ dialog.destroy ()
       │    └─ return true  (prevents default hide-only behavior)
       └─ cancel.clicked  →  dialog.close ()  →  close_request fires

User clicks "Connect" (secured, dialog)
  └─ dialog "Connect" → manager.connect_network.begin (password)
       ├─ _manual_connecting = true
       ├─ _manual_connect_timeout_id = Timeout.add (120s, clear flags)
       └─ service.connect_network ()
├─ existing saved + has password?  →  delete_async (old saved connection)
│                                    + create_connection
│                                    + add_and_activate_connection_async
            ├─ existing saved + no password?   →  activate_connection_async (existing)
            └─ new?                            →  create_connection
                                                   + add_and_activate_connection_async

User clicks "Network details" (hero row or right-click menu)
  └─ show_network_actions () → manager.refresh_network_details (network)
       │  (ensures IP/gateway/DNS are populated before the dialog reads them)
       └─ detail dialog opens with current runtime data

User clicks "Reconnect"
  └─ show_network_actions () → manager.reconnect_network.begin ()
       ├─ service.disconnect_network ()
       │    └─ client.deactivate_connection_async ()
       └─ service.connect_network ()
            └─ client.activate_connection_async ()

User clicks "Disconnect"
  └─ show_network_actions ()
       ├─ manager.record_disconnect (ssid)  ← sets 30s cooldown
       └─ manager.disconnect_network.begin ()
            └─ service.disconnect_network ()
                 └─ client.deactivate_connection_async ()

User clicks "Forget"
  └─ show_network_actions () → manager.forget_network.begin ()
       └─ service.forget_network ()
            └─ connection.delete_async ()

User toggles Wi-Fi
  └─ wifi_switch.notify["active"]
       └─ manager.wireless_enabled = value
            └─ service.wireless_enabled = value  ← NM property
            └─ rebuild ()  ← re-reads devices (wireless may have changed)

User clicks refresh
  └─ manager.scan.begin ()
       └─ service.request_scan ()
            └─ device.request_scan_async ()

User types in search
  └─ ((Gtk.Editable) search_entry).changed
       └─ queue_search_update ()  ← 120ms debounce
            └─ manager.set_search_text ()
                 └─ rebuild_items ()  ← filters existing data, no NM call
```

## Dialog close flow (connect dialog)

```
User closes dialog (X button, Esc, or Cancel)
       │
       ▼
  close_request fires
       │
       ├─ _connect_dialog_active = false  ← guards async callback
       ├─ manager.cancel_manual_connect ()
       │    ├─ _manual_connecting = false
       │    ├─ _manual_connecting_ssid = ""
       │    └─ Source.remove (_manual_connect_timeout_id)
       ├─ dialog.destroy ()  ← frees GtkWindow resources
       │                     (not just hide — avoids hidden window leak)
       └─ return true  ← prevents default hide-only handler
```

Key: `manager.cancel_manual_connect()` is always called (the old
`!connect_initiated` guard was removed). This ensures the `_manual_connecting`
flag is cleared even when the async operation has already returned (e.g. the
user enters a password, the D-Bus call succeeds quickly, the 1.5s auto-close
timer fires, and the dialog closes before the Idle handler sets
`_manual_connecting`). The Idle handler's `_connect_attempt_id` check prevents
it from re-setting the flag after cancel cleared it.

The `_connect_dialog_active` flag is checked in the async callback
before touching dialog widgets. If the dialog was already closed, the
callback returns early — no crash on destroyed widgets.

## Connection failure flow

```
NM ActiveConnection enters DEACTIVATED state
       │
       ▼
  service.state_changed signal fires
       │
       ├─ state == DEACTIVATED && type == 802-11-wireless?
       │    └─ resolve_ssid_from_active () → ssid string
       │         └─ connection_failed (ssid, reason)  ← emitted
       │
       ▼
  WifiViewModel.on_connection_failed ()
       │
       ├─ auto_connect_failures.insert (ssid, true)
       │    (always tracked — stops auto-connect retries)
       │
       ├─ _manual_connecting && ssid == _manual_connecting_ssid?
       │    │  YES → clear flags, emit connect_failed (network, message)
       │    │       → shows password dialog (either new or inline error)
       │    │  NO  → auto-connect failure, no dialog (user clicks network
       │    │         to see "Failed" state and initiate manual reconnect)
       │    ▼
       └─ rebuild () → try_auto_connect_all () skips failed SSIDs
            because auto_connect_failures.contains (ssid) returns true
```

All connection failures are now tracked in `auto_connect_failures`,
which prevents endless auto-connect retry loops. Manual-connect failures
additionally show a password dialog. To reset a failed SSID, the user
must explicitly initiate a connection (via `connect_network()`, which
calls `auto_connect_failures.remove(ssid)`).

## Manual connect guard

```
WifiViewModel.connect_network ()
       │
       ├─ _manual_connecting = false         ← clear flags first so stale
       ├─ _manual_connecting_ssid = ""          DEACTIVATED from the old AC
       ├─ auto_connect_failures.remove (ssid)   (fired during the async yield
       ├─ Source.remove (timeout)               below) are ignored
       │
       ├─ yield service.connect_network ()
       │    ├─ on error → throw (flags stay false)
       │    └─ on success → fall through to Idle
       │
       └─ int my_attempt = ++_connect_attempt_id;
          Idle.add (() => {
               if (my_attempt != _connect_attempt_id)  ← if cancel was called
                   return REMOVE                          between yield and Idle,
                                                          skip flag-setting
               _manual_connecting = true        ← set on idle so all pending
               _manual_connecting_ssid = ssid     DEACTIVATED signals from the
               Timeout.add (120s, clear flags)    superseded AC are already
               return REMOVE                      dispatched (and ignored)
            })
               │
               ├─ on subsequent DEACTIVATED:
               │    on_connection_failed () checks _manual_connecting + SSID match
               │    → emits connect_failed signal
               │
               └─ try_auto_connect_all () no longer returns early when
                    _manual_connecting is true (other networks can still
                    auto-connect). The specific SSID is already covered by
                    is_connecting / auto_connecting flags.
```

The manual connect guard prevents the user's password-based connection from
racing against stale DEACTIVATED signals. It does NOT block auto-connect for
other networks. When the dialog is dismissed, `cancel_manual_connect()`
increments `_connect_attempt_id`, which invalidates any pending Idle handler.

All connection-mutating calls go through `NetworkManagerService` methods which are only reachable from explicit user UI actions or auto-connect logic.
