# Steer Design System

## 1. Product Feel

Steer is an AI action queue, not a chat app first. The default screen should help the user answer the AI session that is most likely to be stuck, then move to the next one without hunting through terminal windows or long threads.

The primary interaction is a large card stack: one active AI request in front, with the backlog visible behind it. Opening a card leads to a Claude/Codex-style session detail where the user can read full context and send a precise instruction.

Reference mix:
- Primary interaction: Tinder-style card stack for one-at-a-time triage.
- Triage workflow: Gmail inbox plus Smart Reply for fast decision handling.
- Detail view: Claude/Codex-style assistant session for full context and response.
- Platform feel: iOS-native surfaces with Liquid Glass where available.
- Visual tone: Instagram DM for immediacy, lightness, and approachable messaging surfaces.
- Technical layer: Linear for status, priority, metadata, and calm precision.

Do not use dating-app aesthetics, social scoring, profile browsing, likes, matches, or playful swipe semantics. Steer borrows the one-card-at-a-time stack mechanic, not Tinder's content model.

## 2. Color Palette & Roles

### Core
- Canvas Light: `#FFFFFF`
- Canvas Dark: `#000000`
- Surface Light: `#F7F7F8`
- Surface Dark: `#111113`
- Elevated Light: `#FFFFFF`
- Elevated Dark: `#1C1C1F`
- Hairline Light: `#E5E5E7`
- Hairline Dark: `#2A2A2D`
- Text Primary Light: `#111111`
- Text Primary Dark: `#F5F5F7`
- Text Secondary Light: `#6B6B70`
- Text Secondary Dark: `#A1A1A8`
- Text Tertiary Light: `#9B9BA1`
- Text Tertiary Dark: `#6F6F76`

### Actions
- Primary Action Blue: `#0A84FF`
- Primary Action Pressed: `#006EDB`
- Quick Chip Fill Light: `#F1F1F3`
- Quick Chip Fill Dark: `#1F1F23`
- Incoming Bubble Light: `#F0F0F2`
- Incoming Bubble Dark: `#262629`
- Outgoing Bubble Light: `#0A84FF`
- Outgoing Bubble Dark: `#0A84FF`

### Session Status
- Running: `#34C759`
- Waiting: `#FFB020`
- Blocked: `#FF453A`
- Done: `#8E8E93`
- Idle: `#A1A1AA`
- Info: `#5E6AD2`

Use status colors in dots, pills, thin borders, and small icons. Do not flood the stack, background, or cards with saturated color.

## 3. Typography

Use the platform system font.

### iOS / macOS
- Primary: SF Pro Text / SF Pro Display
- Monospace: SF Mono for CLI snippets, command names, and file paths

### Web Fallback
- Primary: `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", "Segoe UI", sans-serif`
- Monospace: `"SF Mono", "Menlo", "Monaco", "Consolas", monospace`

### Type Scale
- Queue Title: 17pt / 17px, weight 600, line-height 1.25
- Card Title: 18pt / 18px, weight 650, line-height 1.25
- Card Summary: 15pt / 15px, weight 400, line-height 1.38
- Detail Message Body: 15pt / 15px, weight 400, line-height 1.38
- Session Name: 14pt / 14px, weight 600, line-height 1.25
- Metadata: 12pt / 12px, weight 400, line-height 1.25
- Status Pill: 11pt / 11px, weight 600, line-height 1.0
- Button / Chip: 14pt / 14px, weight 600, line-height 1.0
- Code / CLI: 12pt / 12px, weight 400, line-height 1.45

Avoid large marketing headings inside the product. This is a working surface.

## 4. Primary Screen: Action Card Stack

### App Shell
- Main pane: centered action card stack.
- Top bar: queue name, urgent/waiting count, filter/sort controls.
- Optional side rail on desktop: session filters, rooms, recent completions, search.
- Menu bar popover: urgent and waiting cards first.
- Mobile starts directly on the active stack, not a room list.

### Action Card
- Shows one AI session that may need user attention.
- Recommended desktop size: 520-680px wide, 560-720px tall.
- Recommended mobile size: 92vw wide, 68-76vh tall.
- Radius: 18-24pt.
- Elevation: subtle shadow plus hairline border.
- Background cards: offset 8-14px, scaled 96-98%, muted opacity.

Required content:
- Session badge: provider icon, provider name, project/session name, current state.
- Waiting age: e.g. `waiting 12m`.
- Category: `question`, `decision`, `blocker`, `completion`, `idle`.
- AI-generated summary in 3-6 lines.
- Why it needs attention.
- Suggested response chips above the input field.
- Bottom reply input for direct instruction.

The active card should communicate enough context to answer simple cases without opening detail. It should not attempt to display the full transcript.

### Stack Navigation
- Click/tap card: open detail.
- Arrow keys or swipe/trackpad: move through cards.
- `Enter`: reply to active card.
- `Space`: preview/open detail.
- `Cmd+K`: switch session, room, or command.

Use rotation and stack movement subtly. The interaction should feel fast and precise, not game-like.

## 5. Detail View: Session Thread

Opening a card shows the full session context in a Claude/Codex-style view.

### Layout
- Header: session name, provider, state, cwd/project, room, elapsed waiting time.
- Body: full message/transcript view with grouped agent reports and user instructions.
- Right pane on wide desktop: metadata, files mentioned, recent commands, delivery status.
- Bottom: reply composer with quick chips.

### Message Surfaces
- Agent messages use neutral incoming bubbles or compact cards.
- User instructions use outgoing blue bubbles.
- Structured blocker/decision messages may use small cards.
- Do not make every transcript line a heavy card.
- CLI snippets use SF Mono and compact code blocks.

### Composer
- Bottom-pinned input bar.
- Min height: 40pt; grows to 120pt before scrolling.
- Leading target control: selected session or `@session` mention.
- Trailing send button: circular blue button when text exists.
- Supports proactive instructions, not only replies to the active card.

### Quick Chips
- Horizontal chips above the input field.
- Height: 32-36pt.
- Radius: 16-18pt.
- Default fill: quick chip fill.
- Keep text short: `Proceed`, `Test first`, `Use option A`, `Explain more`, `Stop here`.
- Chips should be visually neutral before selection. Do not highlight the first chip by default.
- Selection, keyboard focus, or an explicit recommendation state may use a subtle blue outline.

### Liquid Glass Treatment
- Use native iOS/macOS Liquid Glass APIs in SwiftUI where available.
- Keep chips visually separate from the input field while preserving shared vertical grouping.
- Use interactive glass only for tappable chips, send buttons, and focusable input surfaces.
- Keep card glass subtle; content legibility is more important than translucency.
- Provide material-style fallback for OS versions without Liquid Glass.

### Provider Identity
- Show the origin of every CLI session visually.
- Use provider icons for Claude Code, Codex CLI, Gemini CLI, and future adapters when available.
- Pair the icon with text such as `Claude Code`, `Codex CLI`, or `Gemini CLI`; do not rely on icon recognition alone.
- If an icon is missing, use a compact letter fallback badge.
- Keep provider identity inside the session badge, not as a large decorative brand surface.

## 6. Rooms, Filters, And Routing

Rooms are a grouping model, not the v1 home screen. The default experience can be one unified queue, but users may later create multiple rooms and decide which CLI sessions belong there.

Use rooms for:
- Project grouping.
- Session filtering.
- Notification policy.
- Later invitation/routing controls.

Do not require the user to manage rooms before the product is useful.

## 7. Layout Principles

Base grid: 4pt with 8pt as the common spacing unit.

- Outer padding: 12-16pt mobile, 16-24px desktop.
- Card internal padding: 18-24pt.
- Card section gap: 12-18pt.
- Chip gap: 8pt.
- Detail message gap: 6-10pt within same sender, 14-18pt between state changes.
- Composer padding: 8-12pt.

The default screen should optimize for the next action, not for seeing every message at once. Density belongs in detail views and filters.

## 8. Depth & Elevation

Use mostly flat surfaces with a clear stack layer.

- Level 0: canvas.
- Level 1: detail surfaces, glass reply dock, side rail.
- Level 2: active action card.
- Level 3: background stack cards.
- Level 4: sheet/modal shadow only.

Avoid decorative gradients, glow effects, bokeh, and oversized dashboard panels. Depth should come from card ordering, spacing, hairlines, and state hierarchy.

## 9. Do's And Don'ts

### Do
- Make the default screen a stuck-AI action queue.
- Let the active card answer: what is waiting, why it matters, and what I can do.
- Put suggested chips directly above the reply input.
- Preserve Instagram DM's lightness in message surfaces and replies.
- Use Claude/Codex-style session detail for full context.
- Use Linear-like labels for technical state.
- Keep quick actions short and tappable.
- Support proactive instructions.
- Make room/session routing visible but secondary.
- Use SF Symbols or established icon libraries for common actions.

### Don't
- Do not build a Slack clone.
- Do not make the default UI a chat timeline.
- Do not build a terminal dashboard as the primary surface.
- Do not put Skip/Snooze/Done as dominant bottom actions on the main card.
- Do not use Tinder's dating language, social gestures, or playful match feedback.
- Do not use Instagram feed, story, reel, profile, or social engagement patterns.
- Do not use large hero text inside the app.
- Do not use purple/blue gradients as the dominant look.
- Do not put cards inside cards.
- Do not hide critical state behind color only.

## 10. Responsive Behavior

### Mobile
- Default to the card stack.
- Detail opens as a full-screen view or sheet.
- Composer is fixed above the keyboard in detail.
- Quick chips scroll horizontally.
- Touch targets must be at least 44x44pt.

### Desktop / Mac
- Default to a focused mobile-width utility window: 430-520px wide, centered on the display.
- Keep the main card stack portable to iOS by using the same single-column viewport and interaction model.
- Allow resizing into a wider desktop mode later, with optional side rail and split detail.
- Detail can open as a split view or separate focused pane.
- Keyboard-first navigation is important:
  - `Cmd+K` for session/room/command switcher.
  - Arrow keys to move through cards.
  - `Enter` to reply.
  - `@` in composer to target sessions.
- Menu bar popover should show urgent/waiting cards first.

## 11. Agent Prompt Guide

When generating Steer UI, use this prompt:

Build Steer as a stuck-AI action queue with an iOS-native Liquid Glass feel. The primary screen is a large Tinder-style card stack, with one waiting/blocker/decision card in front and the backlog visible behind it. Each card has suggested reply chips directly above a bottom input field; do not use Skip/Snooze/Done as the dominant bottom controls. Opening a card shows a Claude/Codex-style session detail with full context, transcript, metadata, chips above the composer, and a bottom input. Preserve Instagram DM's light, immediate feel in message surfaces, but do not make the app chat-first. Add Linear-style technical state with small pills for running, waiting, blocked, done, and idle. Keep chrome monochrome, reserve color for actions and status, and make the next user reply obvious.

Quick color reference:
- Canvas light/dark: `#FFFFFF` / `#000000`
- Surface light/dark: `#F7F7F8` / `#111113`
- Incoming bubble light/dark: `#F0F0F2` / `#262629`
- Outgoing/action blue: `#0A84FF`
- Running: `#34C759`
- Waiting: `#FFB020`
- Blocked: `#FF453A`
- Done/Idle: `#8E8E93`
