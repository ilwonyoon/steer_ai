-- Phase 1 — terminal_excerpts has card-bound lifecycle.
--
-- The FK direction is `action_cards.terminal_excerpt_id →
-- terminal_excerpts.id` (cards point at their excerpt), so SQLite's
-- ON DELETE CASCADE on that edge would fire the WRONG way (deleting
-- an excerpt would null/delete the card). The relationship we
-- actually want is "excerpt lives as long as its parent card lives;
-- when the card goes, the excerpt goes."
--
-- Triggers express that directly. Three events delete a card row:
--   1. resolveActionCardsForSession sets state='done' (not DELETE).
--   2. resolveStaleDisconnectedCards same pattern.
--   3. Future cleanup paths may DELETE outright.
--
-- We cover (1) and (2) with an AFTER UPDATE trigger that fires when
-- a card transitions to state='done', and (3) with an AFTER DELETE
-- trigger. Together, no excerpt ever outlives its card.
--
-- Also: when a card row is replaced via the upsert path (rare —
-- new excerpt id on conflict), the previous excerpt would orphan.
-- Cover that with AFTER UPDATE OF terminal_excerpt_id.

-- Trigger order matters: we must null out the card's FK pointer
-- BEFORE deleting the excerpt, otherwise FOREIGN KEY constraint
-- failed fires (action_cards.terminal_excerpt_id still points at
-- the row we're about to delete). Doing both inside the same
-- trigger body is safe because SQLite evaluates each statement
-- atomically.

CREATE TRIGGER trg_action_cards_done_drops_excerpt
AFTER UPDATE OF state ON action_cards
WHEN NEW.state = 'done' AND OLD.state != 'done' AND OLD.terminal_excerpt_id IS NOT NULL
BEGIN
  UPDATE action_cards SET terminal_excerpt_id = NULL WHERE id = OLD.id;
  DELETE FROM terminal_excerpts WHERE id = OLD.terminal_excerpt_id;
END;

CREATE TRIGGER trg_action_cards_delete_drops_excerpt
AFTER DELETE ON action_cards
WHEN OLD.terminal_excerpt_id IS NOT NULL
BEGIN
  DELETE FROM terminal_excerpts WHERE id = OLD.terminal_excerpt_id;
END;

-- The swap case (UPDATE of terminal_excerpt_id itself) is naturally
-- safe — the card's FK already points at NEW by the time the
-- trigger fires, so deleting OLD doesn't violate.
CREATE TRIGGER trg_action_cards_swap_excerpt
AFTER UPDATE OF terminal_excerpt_id ON action_cards
WHEN OLD.terminal_excerpt_id IS NOT NULL
  AND OLD.terminal_excerpt_id != NEW.terminal_excerpt_id
BEGIN
  DELETE FROM terminal_excerpts WHERE id = OLD.terminal_excerpt_id;
END;

-- One-time cleanup: drop excerpts whose parent card is done or
-- gone. Two-step to avoid FK violation:
--   (a) null out terminal_excerpt_id on done cards that still
--       point at an excerpt, AND on cards that point at an excerpt
--       not in the "keep" set;
--   (b) delete excerpts not referenced by any *active* card.
UPDATE action_cards
SET terminal_excerpt_id = NULL
WHERE terminal_excerpt_id IS NOT NULL
  AND (state != 'active');

DELETE FROM terminal_excerpts
WHERE id NOT IN (
  SELECT terminal_excerpt_id FROM action_cards
  WHERE state = 'active' AND terminal_excerpt_id IS NOT NULL
);
