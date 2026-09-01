-- Tester feedback round 2, ADR-044. One migration, five parts:
--
--   A. Bibs reward copy fix (#7) -- the notification body said "for washing the
--      bibs after the session"; the actual ritual is bringing the (clean) bibs
--      TO the session, which is the person we already register in
--      match_sessions.bibs_washed_by. create or replace kut.grant_bibs_reward
--      with the corrected format() string, plus a one-shot backfill of the
--      already-sent 'bibs_bonus' notification rows. No change to the column
--      name, wallet_ledger.reason, user_notifications.event_type, the
--      bibs_rewards guard table, or the 100-coin amount.
--
--   B. kut.set_own_club_name(text) (idea 04) -- a member self-service RPC that
--      writes the dormant kut.profiles.club_name column (added 20260816010000,
--      never used until now). Mirrors kut.set_own_player_photo. Blank/whitespace
--      resets to NULL (-> the synthesised default). Not enforced unique.
--
--   C. kut.club_value_leaderboard -- surface the custom club name:
--      coalesce(nullif(btrim(club_name), ''), display_name || '''s Club').
--      Body is otherwise the 20260910000000_club_value_v2.sql body verbatim;
--      club_value / rank maths unchanged. my_club_value is NOT touched.
--
--   D. kut.published_sessions (idea 12) -- a thin additive view over published
--      match_sessions with attendee + goal counts, for a new member-facing
--      /sessions list. security_invoker = true is safe: members already have
--      RLS select on published sessions and their attendance
--      (20260816010000_phase_1a_roster_and_ratings.sql, "users read published
--      sessions" / "users read published attendance").
--
-- Tier: data-changing (ADR-032) because of the user_notifications backfill in
-- part A. Fresh backup immediately before the hosted push. Parts B/C/D are
-- additive (new function, create-or-replace view, new view).
--
-- Rollback DDL:
--   -- A: restore the 20260907000000_bibs_bonus.sql body of kut.grant_bibs_reward
--   --    (only the format() string differs) and reverse the backfill:
--   --    update kut.user_notifications set body = replace(body,
--   --      'for bringing the bibs to the session on',
--   --      'for washing the bibs after the session on')
--   --    where event_type = 'bibs_bonus'
--   --      and body like '%for bringing the bibs to the session on%';
--   -- B: drop function kut.set_own_club_name(text);
--   -- C: restore the 20260910000000_club_value_v2.sql body of
--   --    kut.club_value_leaderboard (synthesised club_name, no club_name in the
--   --    club_totals CTE).
--   -- D: drop view kut.published_sessions;


-- ---------------------------------------------------------------------------
-- A. Bibs reward copy fix
-- ---------------------------------------------------------------------------

-- Byte-identical to 20260907000000_bibs_bonus.sql section 5 except the
-- user_notifications body string ("washing the bibs after" -> "bringing the
-- bibs to").
create or replace function kut.grant_bibs_reward(p_session_id uuid)
returns integer
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_washer_player_id uuid;
  v_session_date date;
  v_user_id uuid;
  v_ledger_id uuid := gen_random_uuid();
  -- Canonical amount: BUILD_SPEC.md Part 145 (BIBS_COIN_BONUS). Mirrored by
  -- ECONOMY.bibsCoinBonus in src/game/economy.ts. See ADR-037.
  v_amount constant bigint := 100;
begin
  select bibs_washed_by, session_date
  into v_washer_player_id, v_session_date
  from kut.match_sessions
  where id = p_session_id and status = 'published';

  if v_washer_player_id is null then
    return 0;
  end if;

  select id into v_user_id
  from kut.profiles
  where player_id = v_washer_player_id and not is_disabled;

  if v_user_id is null then
    return 0;
  end if;

  insert into kut.bibs_rewards (session_id, player_id, user_id, ledger_id)
  values (p_session_id, v_washer_player_id, v_user_id, v_ledger_id)
  on conflict (session_id, player_id) do nothing;

  if not found then
    return 0;
  end if;

  insert into kut.wallets (user_id, balance) values (v_user_id, 0)
  on conflict (user_id) do nothing;
  insert into kut.wallet_ledger (id, user_id, amount, reason, reference_type, reference_id, idempotency_key)
  values (
    v_ledger_id, v_user_id, v_amount, 'bibs_bonus', 'match_session', p_session_id,
    'bibs:' || p_session_id::text || ':' || v_washer_player_id::text
  );
  update kut.wallets set balance = balance + v_amount, updated_at = now() where user_id = v_user_id;

  insert into kut.user_notifications (user_id, event_type, title, body, reference_type, reference_id)
  values (
    v_user_id, 'bibs_bonus', 'Bibs bonus',
    format('You received %s KUT Coins for bringing the bibs to the session on %s.',
           v_amount, to_char(v_session_date, 'DD Mon YYYY')),
    'match_session', p_session_id
  )
  on conflict (user_id, event_type, reference_type, reference_id)
    where reference_type is not null and reference_id is not null do nothing;

  return 1;
end;
$$;

revoke execute on function kut.grant_bibs_reward(uuid) from public, anon, authenticated;

-- One-shot backfill of already-sent rows. Scoped to the exact substring so it
-- is idempotent and reversible; touches no other event_type.
update kut.user_notifications
   set body = replace(body,
         'for washing the bibs after the session on',
         'for bringing the bibs to the session on')
 where event_type = 'bibs_bonus'
   and body like '%for washing the bibs after the session on%';


-- ---------------------------------------------------------------------------
-- B. kut.set_own_club_name -- member self-service club rename
-- ---------------------------------------------------------------------------

-- Blank or whitespace-only input resets club_name to NULL, which the
-- leaderboard renders as the synthesised "<display_name>'s Club" default.
-- Not enforced unique (it is a display label; the member's own name
-- disambiguates rows).
create or replace function kut.set_own_club_name(p_club_name text)
returns jsonb
language plpgsql
security definer
set search_path = kut, pg_catalog
as $$
declare
  v_name text := nullif(btrim(p_club_name), '');
  v_updated integer;
begin
  if v_name is not null then
    if char_length(v_name) > 80 then
      raise exception 'club name must be 80 characters or fewer' using errcode = '22023';
    end if;
    if v_name ~ '[[:cntrl:]]' then
      raise exception 'club name contains invalid characters' using errcode = '22023';
    end if;
  end if;

  update kut.profiles
  set club_name = v_name, updated_at = now()
  where id = auth.uid() and is_disabled = false;

  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    raise exception 'no active profile for this account' using errcode = 'P0001';
  end if;

  return jsonb_build_object('club_name', v_name);
end;
$$;

revoke execute on function kut.set_own_club_name(text) from public, anon;
grant  execute on function kut.set_own_club_name(text) to authenticated;


-- ---------------------------------------------------------------------------
-- C. kut.club_value_leaderboard -- render the custom club name
-- ---------------------------------------------------------------------------

-- Body is 20260910000000_club_value_v2.sql verbatim except: club_name is
-- carried through the club_totals CTE, and the final projection coalesces it
-- with the old synthesised default. club_value / rank arithmetic is unchanged.
create or replace view kut.club_value_leaderboard
with (security_invoker = false, security_barrier = true)
as
with owned as (
  select
    card.owner_id,
    edition.player_id,
    round(
      10 * power(1.08::numeric, coalesce(edition.snapshot_ovr, state.live_ovr, 30) - 30)
      * case when edition.is_live then 1 else coalesce(edition.special_discard_multiplier, 1) end
    )::bigint as discard_value
  from kut.user_cards card
  join kut.card_editions edition on edition.id = card.edition_id
  left join kut.seasons active_season on active_season.is_active
  left join kut.player_season_state state
    on state.player_id = edition.player_id and state.season_id = active_season.id
  where card.burned_at is null
), club_totals as (
  select
    profile.id,
    profile.display_name,
    profile.club_name,
    coalesce(wallet.balance, 0)::bigint as wallet_balance,
    count(owned.discard_value)::integer as card_count,
    count(distinct owned.player_id)::integer as unique_player_count,
    coalesce(sum(owned.discard_value), 0)::bigint as owned_cards_value,
    (coalesce(personal.base_value, 0) * 4)::bigint as personal_card_bonus
  from kut.profiles profile
  left join kut.wallets wallet on wallet.user_id = profile.id
  left join owned on owned.owner_id = profile.id
  left join lateral (
    select round(10 * power(1.08::numeric, coalesce(pstate.live_ovr, 30) - 30))::bigint as base_value
    from kut.players player
    left join kut.seasons s on s.is_active
    left join kut.player_season_state pstate
      on pstate.player_id = player.id and pstate.season_id = s.id
    where player.id = profile.player_id and player.is_active
  ) personal on true
  where not profile.is_disabled and profile.role = 'user'
  group by profile.id, profile.display_name, profile.club_name, wallet.balance, personal.base_value
)
select
  rank() over (
    order by (wallet_balance + owned_cards_value + personal_card_bonus) desc, display_name asc
  )::integer as rank,
  display_name,
  coalesce(nullif(btrim(club_name), ''), display_name || '''s Club') as club_name,
  (wallet_balance + owned_cards_value + personal_card_bonus)::bigint as club_value,
  card_count,
  unique_player_count,
  id = auth.uid() as is_current_user
from club_totals;

revoke all on kut.club_value_leaderboard from public;
grant select on kut.club_value_leaderboard to authenticated, service_role;


-- ---------------------------------------------------------------------------
-- D. kut.published_sessions -- member-facing published-session list
-- ---------------------------------------------------------------------------

create view kut.published_sessions
with (security_invoker = true, security_barrier = true)
as
select
  s.id,
  s.session_date,
  s.session_type,
  s.published_at,
  s.bibs_washed_by,
  count(a.player_id)::integer        as attendee_count,
  coalesce(sum(a.goals), 0)::integer as goal_count
from kut.match_sessions s
left join kut.attendance a on a.session_id = s.id
where s.status = 'published'
group by s.id;

grant select on kut.published_sessions to authenticated, service_role;
