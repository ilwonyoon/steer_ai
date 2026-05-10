-- 0004_apns_token: hex-encoded APNS device token for iOS push fanout.
-- Updated by the iOS client every time Apple hands it a new token
-- (after first authorization, after restore-from-backup, or after
-- an app reinstall). Mac devices leave it NULL.

ALTER TABLE devices ADD COLUMN apns_token TEXT;
