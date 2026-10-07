-- Web Push subscriptions (one per browser/device); a 404/410 from the push service deletes the row.
CREATE TABLE push_subscriptions(endpoint TEXT PRIMARY KEY, p256dh TEXT NOT NULL, auth TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (datetime('now')));
