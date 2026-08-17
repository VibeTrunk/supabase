-- KUT is invite-only. Live ratings are visible only to enabled, authenticated
-- members through the application; anonymous callers have no database read path.
revoke select on kut.public_live_ratings from anon;
