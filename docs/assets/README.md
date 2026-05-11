# README screenshots

The main `README.md` references four screenshots. They don't exist yet — drop
real PNGs at these exact paths and the page fills in. No edits to `README.md`
needed.

| Path | What to capture | Composition tips |
|---|---|---|
| `hero.png` | Mac card stack on the left, iPhone showing the same paused card on the right. | Aspect ~16:9, ~1800x1000. Plain neutral background, no menu bar clutter. The two devices should be holding *the same* session — same project name, same waiting/question state. |
| `mac-card-stack.png` | The Mac window showing 2–3 stacked cards with at least one terminal-tail excerpt visible. | ~1200x800. Use a real `steer claude` session that's actually stopped. Make sure card titles are readable; trim any unnecessary chrome with the OS window border included. |
| `iphone-reply.png` | iPhone card detail with the reply dock open and at least one suggested chip showing. | ~1200x800 framed (let the device frame breathe). Use iPhone 17 Pro simulator or a real device. Avoid placeholder text in the reply input — let the chip suggestions do the talking. |
| `push-notification.png` | iOS lock-screen or banner notification from a Claude `Stop` hook, with the card title and project name visible. | ~1200x800. Lock screen looks better than banner-on-app because it sells the "you walked away" moment. |

## How to capture (Mac)

- macOS Tahoe screenshot keys: `Cmd+Shift+5` → **Capture Selected Window**.
- Hold `Option` while clicking to drop the window's drop shadow if you want a tighter frame.
- Save as PNG. Don't compress — GitHub will serve a Cache-Control'd CDN copy.

## How to capture (iPhone)

- Press **Volume Up + Side Button** simultaneously on a real device, or `Cmd+S` in the simulator.
- For lock-screen captures: trigger a real Steer push (have Mac inject a Stop event), then lock the phone before the banner times out. Or use Settings → Focus → trigger a debug push from Steer for Mac.

## What we're NOT doing

- **No mocked-up screenshots.** Every image in the README must come from the real Mac app or real iPhone build. Mock SVGs or AI-generated previews aren't allowed because they drift from the product the user actually downloads.
- **No marketing collages.** Apple's product pages get away with rendered hero shots because they own the camera pipeline; we don't. A clean device screenshot reads as more honest.

## Updating the download badge

`download-macos-badge.svg` is hand-written and renders at any size. If we ship a redesign, edit the SVG directly — don't replace it with a PNG.
