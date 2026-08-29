-- August 2026, complete month: adds the two remaining Friday sessions
-- (21.08, 28.08) and every player who has now reached 2+ appearances across
-- the full seven-session month. Same one-time migration/seed approach as
-- 20260818000000_initial_tfh_roster_and_august_sessions.sql (BUILD_SPEC.md
-- Part 137 — a script is acceptable for roster import while there is still no
-- admin import UI). Idempotent: every statement is guarded with
-- `on conflict ... do nothing`, so re-applying is safe.
--
-- New since the initial import (which covered 03/07/10/14/17 Aug):
--   * Steffen and Serhat each appeared once on 17.08 and again on 21.08.
--   * Stephen appeared once on 17.08 and again on 28.08.
--   * Maarten is new to the sheets entirely (21.08 + 28.08).
-- All four were on the initial import's single-appearance exclusion list (or
-- absent); they now join the roster with their full history. Their 17.08
-- attendance rows (Steffen, Serhat, Stephen), dropped as single-appearance
-- back then, are backfilled below against the existing 17.08 session.
--
-- Still excluded as single-appearance across the whole month: Bader (03.08);
-- Souhail, Meral, Maikel, Nick, Xander, Zak (all 07.08); Jurie (14.08);
-- Cormac and Peter (both 28.08). Re-add any of them with their full
-- attendance history once they attend a second session.

insert into kut.players (slug, display_name)
values
  ('steffen', 'Steffen'),
  ('serhat', 'Serhat'),
  ('stephen', 'Stephen'),
  ('maarten', 'Maarten')
on conflict (slug) do nothing;

-- Every player needs a Live Card edition to be visible/collectible; identical
-- pattern to the initial import and
-- 20260816070000_wallet_starter_and_attendance_rewards.sql.
insert into kut.card_editions (player_id, edition_type, title, is_live)
select id, 'live', display_name || ' Live', true
from kut.players
on conflict do nothing;

-- The two remaining August Fridays. Session ids continue the
-- a0…0001–0005 sequence used by the initial import.
insert into kut.match_sessions (id, season_id, session_date, session_type, status, published_at)
values
  ('a0000000-0000-4000-8000-000000000006', 'a0000000-0000-4000-8000-000000000000', date '2026-08-21', 'friday', 'published', now()),
  ('a0000000-0000-4000-8000-000000000007', 'a0000000-0000-4000-8000-000000000000', date '2026-08-28', 'friday', 'published', now())
on conflict (id) do nothing;

-- No goals were recorded on the source attendance sheets, so every row
-- defaults to 0; correct individual entries later via the admin correction
-- flow if goals are recalled.

-- 17.08.2026 (session …0005) already exists from the initial import, but
-- these three attendees were dropped then as single-appearance players. They
-- have qualified since, so their real 17.08 attendance is recorded now.
insert into kut.attendance (session_id, player_id, goals)
select 'a0000000-0000-4000-8000-000000000005', p.id, 0
from kut.players p
where p.slug in ('steffen', 'serhat', 'stephen')
on conflict (session_id, player_id) do nothing;

-- Friday 21.08.2026
insert into kut.attendance (session_id, player_id, goals)
select 'a0000000-0000-4000-8000-000000000006', p.id, 0
from kut.players p
where p.slug in (
  'alex', 'teize', 'oussama', 'freek', 'omar', 'serhat', 'cedric',
  'maarten', 'steffen', 'erik', 'muaad', 'djanco', 'leihko', 'quinten'
)
on conflict (session_id, player_id) do nothing;

-- Friday 28.08.2026 (Cormac and Peter attended but are single-appearance and
-- stay out of the roster, matching the initial import's treatment of one-off
-- names).
insert into kut.attendance (session_id, player_id, goals)
select 'a0000000-0000-4000-8000-000000000007', p.id, 0
from kut.players p
where p.slug in (
  'oussama', 'freek', 'alex', 'teize', 'omar', 'cedric', 'vitaly',
  'leihko', 'maarten', 'quinten', 'stephen'
)
on conflict (session_id, player_id) do nothing;

-- Recompute every player's season state from the now-complete published
-- August history, using the same canonical core the initial import used
-- (BUILD_SPEC.md Part 10). kut._rebuild_season_core already exists from
-- 20260818000000_initial_tfh_roster_and_august_sessions.sql.
select kut._rebuild_season_core('a0000000-0000-4000-8000-000000000000');
