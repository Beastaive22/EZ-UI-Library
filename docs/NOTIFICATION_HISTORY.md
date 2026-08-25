# NotificationHistory — Bell + Log

A bell button in the window header with an unread badge, plus a slide-out panel containing every notification the session produced (including error notifications).

```lua
local NotifHistory = loadstring(game:HttpGet("https://raw.githubusercontent.com/Beastaive22/EZ-UI-Library/main/addons/NotificationHistory.lua"))()
NotifHistory:Bind(EZ, Window)
```

---

## API

| Method | Description |
|---|---|
| `Bind(library, window, opts?)` | Attach. Opts: `MaxEntries` (`50`), `ShowTimestamp` (`true` — relative age like `5m`). Rebinding to a **new** window re-attaches cleanly; same-window rebinding is a no-op |
| `GetEntries()` | Captured entries (`{title, content, type, time}`, newest first) |
| `GetUnreadCount()` | Unread counter |
| `MarkAllRead()` | Reset badge without opening |
| `Clear()` | Wipe history + badge |
| `Destroy()` | Unhook, remove bell/panel, clear state |

---

## Behaviour notes

- Capture is automatic — it hooks `EZ:Notify`, so **nothing extra to call** per notification
- Badge shows up to `99+`; opening the panel marks everything read
- Panel slides in flush with the window's right edge and matches the rounded corners
- The header search bar shifts left automatically to make room for the bell (mobile collapse target stays correct)
- Entries render with a type-tinted icon (the accent colour identifies the type via the icon — no accent bars); empty state included
