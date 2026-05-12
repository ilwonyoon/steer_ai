-- 0005_aps_environment: per-device APNS environment ("development" or
-- "production") so relay can route the right token to the right Apple
-- endpoint instead of relying on the global APNS_USE_SANDBOX var.
-- Phase B2 of docs/SYNC_STABILITY_AND_COST_PLAN.md.
ALTER TABLE devices ADD COLUMN aps_environment TEXT;
