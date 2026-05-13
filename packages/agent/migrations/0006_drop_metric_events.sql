-- Phase 3 — drop metric_events.
--
-- recordMetric was the original instrumentation hook for the
-- never-shipped analytics dashboard. Nothing in production reads
-- the rows. Every state transition + transcript append wrote a
-- row, so an idle DB still grew it forever.
--
-- recordMetric and every call site are removed in the same PR;
-- the table goes here. ~6KB on the dogfood DB, but more
-- importantly one less write per state transition and one less
-- thing to teach future contributors about.

DROP TABLE metric_events;
