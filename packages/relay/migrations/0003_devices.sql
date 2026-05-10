-- Per-user device presence so iPhone can show a Mac connection chip
-- ("MacBook Air ●") and decide whether to queue or warn on reply.
-- Mac heartbeats here every ~60s while iPhone Sync is enabled. iPhone
-- reads via GET /v1/sync/devices.
CREATE TABLE IF NOT EXISTS devices (
  device_id        TEXT NOT NULL,
  user_id          TEXT NOT NULL,
  platform         TEXT NOT NULL,         -- 'mac' | 'ios'
  display_name     TEXT,
  device_class     TEXT,                  -- 'MacBook Air' | 'Mac mini' | 'iPhone' | ...
  app_version      TEXT,
  sync_enabled     INTEGER NOT NULL DEFAULT 0,
  last_seen_at     INTEGER NOT NULL,      -- ms epoch
  PRIMARY KEY (user_id, device_id),
  FOREIGN KEY (user_id) REFERENCES users(user_id)
);

CREATE INDEX IF NOT EXISTS idx_devices_user_last_seen ON devices(user_id, last_seen_at);
