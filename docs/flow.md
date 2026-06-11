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
                 │    ├─ connect service.changed → update_connectivity_state ()
                 │    ├─ connect service.scan_started → scanning = true
                 │    ├─ connect service.scan_finished → scanning = false, schedule_rebuild ()
                 │    ├─ rebuild ()  ← initial snapshot (read-only, _started == false)
                 │    ├─ update_connectivity_state ()
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
       └─ disconnect_cooldown active?  →  return  (30s timer)
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
- Individual network passes its own checks

## Signal flow

```
NM signal changes
       │
       ▼
  service.changed
       │
       ├─ schedule_rebuild ()  →  rebuild ()  →  update_scan_freshness ()
       │                                              │
       │                                         (every 5s)
       │                                              │
       └─ update_connectivity_state ()           tick_freshness ()
                                                     │
                                                apply_freshness ()
                                                     │
                                                notify_property ("scan-freshness")
```

The 5-second freshness timer is independent of rebuilds — it re-formats the stored `freshest_scan` timestamp so the label updates in real time between scans.

## User actions

```
User clicks "Connect" (open network)
  └─ activate_network ()
       └─ connect_network.begin ()
            └─ manager.connect_network ()
                 └─ service.user_connect ()
                      └─ client.add_and_activate_connection_async ()

User clicks "Connect" (secured, dialog)
  └─ show_connect_dialog ()
       └─ dialog "Connect" → manager.connect_network.begin (password)
            └─ service.user_connect ()
                 ├─ client.activate_connection_async ()  ← if saved
                 └─ client.add_and_activate_connection_async ()  ← if new

User clicks "Reconnect"
  └─ show_network_actions () → manager.reconnect_network.begin ()
       ├─ service.user_disconnect ()
       │    └─ client.deactivate_connection_async ()
       └─ service.user_connect ()
            └─ client.activate_connection_async ()

User clicks "Disconnect"
  └─ show_network_actions ()
       ├─ manager.record_disconnect (ssid)  ← sets 30s cooldown
       └─ manager.disconnect_network.begin ()
            └─ service.user_disconnect ()
                 └─ client.deactivate_connection_async ()

User clicks "Forget"
  └─ show_network_actions () → manager.forget_network.begin ()
       └─ service.user_forget ()
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
  └─ search_entry.search_changed
       └─ queue_search_update ()  ← 120ms debounce
            └─ manager.set_search_text ()
                 └─ rebuild_items ()  ← filters existing data, no NM call
```

All connection-mutating calls go through `NetworkManagerService.user_*` methods, which are only reachable from explicit user UI actions.
