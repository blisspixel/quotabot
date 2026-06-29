# quotabot app

Flutter desktop widget (Windows first; cross-platform design) for the quotabot
collector. See root README.md for usage, build, and architecture.

The app imports the collector package directly, renders the normalized quota
model with frameless UI (always on top, taskbar entry, notifications, an "Alert
webhook", and "Show account names" are configurable via menu), adaptive refresh,
compact/expanded views, history averages, and persisted preferences. Each card
carries a glance-layer forward-looking forecast on its binding window in plain
language ("about an hour of usage left", or "likely to run out before it
resets"), the same forecast `quotabot top` shows, only when there is a real burn
signal. Low-quota alerts fire once when a window crosses into red, naming where
to route next, and can POST to a webhook (loopback unless external is allowed). Account names auto-hide for
single-account providers and appear only when a provider has more than one
account on screen; the "Show account names" menu toggle applies on top (off
hides all). The header shows a dynamic radial "pool gauge" plus the "Quota"
wordmark, the gauge filling clockwise with the average remaining headroom across
visible providers and colored on the card scale. Time labels use
minute-resolution "as of HH:MM AM" format. Claude weekly shows reset times; Antigravity
shows "free tier". The OS/desktop application icon (app_icon.ico) is the custom
rune-style monochrome icon (light/dark friendly), separate from the in-app
header mark. The body is scrollable and the window height comes from a
deterministic content estimate capped at the screen height (no overflow banner
when many providers show); broad drag support. See root README.md for usage,
build (quotabot-gui for source; release exe is the default shortcut target), and
architecture.
