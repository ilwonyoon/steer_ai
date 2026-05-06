# Steer Design System

## 1. Visual Theme & Atmosphere

Steer is an AI operations room that feels as immediate as Instagram DM and as precise as Linear. The product should not look like a developer dashboard first. It should feel like a fast, personal messaging app where AI CLI sessions report progress, ask questions, and receive instructions without making the user return to a terminal.

The interface is compact, quiet, and message-first. The chat stream carries the product. Chrome should stay mostly monochrome so that session state, urgency, and user actions are easy to scan. Use Linear-style status language for technical metadata, but keep the interaction model close to mobile messaging: room list, unread counts, bubbles/cards, quick replies, and a composer that can target a session.

Reference mix:
- Primary: Instagram DM for light, immediate, mobile-first messaging.
- Secondary: Telegram for multi-room structure and flexible chat organization.
- Technical layer: Linear for status, priority, dense metadata, and calm precision.
- Optional Mac interaction: Raycast for command-style routing and session switching.

Do not copy Instagram feed, stories, reels, profile grids, or brand gradient behavior. Steer borrows DM ergonomics, not social media content patterns.

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
- Incoming Bubble Light: `#F0F0F2`
- Incoming Bubble Dark: `#262629`
- Outgoing Bubble Light: `#0A84FF`
- Outgoing Bubble Dark: `#0A84FF`
- Composer Fill Light: `#F1F1F3`
- Composer Fill Dark: `#1F1F23`

### Session Status
- Running: `#34C759`
- Waiting: `#FFB020`
- Blocked: `#FF453A`
- Done: `#8E8E93`
- Idle: `#A1A1AA`
- Info: `#5E6AD2`

Use status colors sparingly in pills, dots, thin borders, and small icons. Do not flood cards or backgrounds with saturated color.

## 3. Typography Rules

Use the platform system font.

### iOS / macOS
- Primary: SF Pro Text / SF Pro Display
- Monospace: SF Mono for CLI snippets, command names, and file paths

### Web Fallback
- Primary: `-apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", "Segoe UI", sans-serif`
- Monospace: `"SF Mono", "Menlo", "Monaco", "Consolas", monospace`

### Type Scale
- Screen Title: 17pt / 17px, weight 600, line-height 1.25
- Room Name: 16pt / 16px, weight 600, line-height 1.25
- Sender Name: 14pt / 14px, weight 600, line-height 1.25
- Message Body: 15pt / 15px, weight 400, line-height 1.38
- Message Summary: 14pt / 14px, weight 400, line-height 1.35
- Metadata: 12pt / 12px, weight 400, line-height 1.25
- Status Pill: 11pt / 11px, weight 600, line-height 1.0
- Button: 14pt / 14px, weight 600, line-height 1.0
- Code / CLI: 12pt / 12px, weight 400, line-height 1.45

Avoid large marketing-style headings inside the product. This is a working surface, not a landing page.

## 4. Component Stylings

### App Shell
- Left rail or sheet: room list with unread badges and session counts.
- Main pane: selected room message stream.
- Optional right/detail pane on desktop: selected session details, transcript, metrics.
- Mobile should use a familiar messaging hierarchy: room list -> room -> session detail.

### Room Row
- Height: 56-64pt.
- Leading: room icon or stacked session avatars.
- Title: room name, semibold.
- Subtitle: latest report or active session summary.
- Trailing: timestamp, unread count, and small status aggregate.
- Pressed: subtle gray fill.

### Message Bubbles And Cards
- User instructions use outgoing blue bubbles aligned right.
- Agent reports use incoming neutral bubbles/cards aligned left.
- Decision/blocker messages may expand into compact cards with options.
- Keep normal reports lightweight. Do not card every single message if a bubble is enough.
- Radius: 18-20pt for simple bubbles, 12pt for structured decision cards.
- Max width: 76% on mobile, 640px on desktop.

### Session Badge
- Compact label showing session display name, agent, and state.
- Example: `brief-app · waiting`
- Use a 6-8px status dot plus small text. Do not rely on color alone.

### Status Pills
- Running: green dot, label `running`
- Waiting: amber dot, label `waiting`
- Blocked: red dot, label `blocked`
- Done: gray dot, label `done`
- Idle: gray outline dot, label `idle`
- Pill background should be a 10-14% tint of the status color.

### Quick Reply / Quick Instruction
- Use horizontal chips below a message.
- Height: 32-36pt.
- Radius: 16-18pt.
- Default fill: surface.
- Primary recommended option may use blue text or a subtle blue tint.
- Chips should contain short action text, not long explanations.

### Composer
- Rounded input bar pinned to the bottom of the room.
- Fill: composer fill.
- Min height: 40pt; grows up to 120pt before scrolling.
- Leading target control: selected session or `@` mention affordance.
- Trailing send button: circular blue button when text exists; muted icon when empty.
- Support `@session` routing. The mention token should be visually distinct but quiet.

### Notifications
- Use urgency levels:
  - Silent: progress reports, no push.
  - Normal: completion or low-risk question.
  - Urgent: blocker, waiting decision, failed injection.
- Notification copy should be short and action-oriented.

## 5. Layout Principles

Base grid: 4pt with 8pt as the common spacing unit.

- Outer page padding: 12-16pt mobile, 16-24px desktop.
- Room list row padding: 12-16pt horizontal.
- Message vertical gap: 6-10pt within same sender, 14-18pt between sender/state changes.
- Message inner padding: 10-14pt vertical, 12-16pt horizontal.
- Quick action gap: 8pt.
- Composer padding: 8-12pt.

Use dense but breathable layouts. The user should see several active sessions and recent reports without the UI becoming a project-management table.

## 6. Depth & Elevation

Use nearly flat surfaces.

- Level 0: canvas.
- Level 1: subtle surface fill for room rows, composer, incoming bubbles.
- Level 2: hairline border for structured cards and panels.
- Level 3: sheet/modal shadow only.

Avoid decorative gradients, glow effects, and oversized cards. Depth should come from spacing, hairlines, and state hierarchy.

## 7. Do's And Don'ts

### Do
- Make the default experience feel like a messaging app.
- Keep chrome monochrome and let status colors carry meaning.
- Use Linear-like labels for technical state.
- Let reports be easy to skim.
- Keep quick actions short and tappable.
- Support proactive instructions, not only replies.
- Make room/session routing visible but not heavy.
- Use SF Symbols or established icon libraries for common actions.

### Don't
- Do not build a Slack clone.
- Do not build a terminal dashboard as the primary surface.
- Do not use Instagram feed, story, reel, profile, or social engagement patterns.
- Do not use large hero text inside the app.
- Do not use purple/blue gradients as the dominant look.
- Do not put cards inside cards.
- Do not make every message a heavy card.
- Do not hide critical state behind color only.

## 8. Responsive Behavior

### Mobile
- Default to room list -> room detail navigation.
- Composer is fixed above the keyboard.
- Quick actions wrap horizontally or scroll as chips.
- Touch targets must be at least 44x44pt.

### Desktop / Mac
- Use a two-pane layout by default: room list + message stream.
- Add optional session detail pane when width allows.
- Keyboard-first navigation is important:
  - `Cmd+K` for room/session switcher.
  - `@` in composer to target sessions.
  - Arrow keys to move between quick actions.
- Menu bar popover should show urgent/waiting items first.

## 9. Agent Prompt Guide

When generating Steer UI, use this prompt:

Build Steer as an AI operations messaging app. Use Instagram DM as the primary interaction model: compact room list, lightweight bubbles, unread badges, quick replies, and a bottom composer. Add Linear-style technical state with small status pills for running, waiting, blocked, done, and idle. Use Telegram-like multi-room flexibility, but keep v1 focused on a default unified room. Avoid Slack/Discord density unless explicitly building advanced room/session management. Keep chrome monochrome, reserve color for actions and status, and make reports/instructions fast to scan.

Quick color reference:
- Canvas light/dark: `#FFFFFF` / `#000000`
- Surface light/dark: `#F7F7F8` / `#111113`
- Incoming bubble light/dark: `#F0F0F2` / `#262629`
- Outgoing/action blue: `#0A84FF`
- Running: `#34C759`
- Waiting: `#FFB020`
- Blocked: `#FF453A`
- Done/Idle: `#8E8E93`

