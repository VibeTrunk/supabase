-- Midweek Madness: archetypes are frozen when a tournament opens, not at the
-- lock. BUILD_SPEC §44.2; ADR-099.
--
-- The lock read each card's archetype live from kut.players, so a member could
-- change their own Player's archetype on Wednesday afternoon (the 14-day
-- cooldown allows one change every other week) and reshape every squad that
-- had picked that Player: a Goalkeeper turning Speedster leaves those squads
-- keeperless with no time to react. Now:
--
--   * kut.midweek_archetype_snapshots holds each Player's archetype per
--     tournament, written by an AFTER INSERT trigger on kut.midweek_tournaments,
--     so every way a tournament is created (the worker's open step, tests,
--     admin SQL) snapshots the whole roster in the same statement.
--   * kut._mm_field reads the snapshot, falling back to the live archetype for
--     a Player created after the tournament opened (it has no row). Only the
--     archetype comes from the snapshot: OVR, ownership, injuries and opt-outs
--     are read as before.
--   * kut.midweek_archetypes is the members' read of the snapshots, for the
--     picker, gated on kut.is_active_member() (ADR-079).
--   * The tournament open when this is applied gets its snapshot here, as the
--     roster stands at the push.
--
-- An archetype change still applies everywhere else at once (card faces, the
-- rating rebuild); in Midweek Madness it applies from the next tournament.
--
-- Tier: data-changing (ADR-032). The backfill writes rows (into the new table
-- only), and the lock now reads a different source. Fresh backup first.
--
-- Rollback DDL:
--   -- re-create kut._mm_field from 20261005000000_midweek_engine.sql section 4,
--   -- then:
--   drop view kut.midweek_archetypes;
--   drop trigger midweek_tournament_archetype_snapshot on kut.midweek_tournaments;
--   drop function kut._mm_snapshot_archetypes();
--   drop table kut.midweek_archetype_snapshots;

-- 1. The snapshot -----------------------------------------------------------------
create table kut.midweek_archetype_snapshots (
  tournament_id uuid not null references kut.midweek_tournaments(id) on delete cascade,
  player_id uuid not null references kut.players(id) on delete cascade,
  archetype text not null check (archetype in
    ('all_rounder','speedster','finisher','playmaker','defender','tank','goalkeeper')),
  primary key (tournament_id, player_id)
);

comment on table kut.midweek_archetype_snapshots is
  'ADR-099: each Player''s archetype as it stood when the Midweek tournament opened. '
  'The lock plays these, so a change after the open applies from the next tournament.';

alter table kut.midweek_archetype_snapshots enable row level security;
revoke all on kut.midweek_archetype_snapshots from public, anon, authenticated;
grant select on kut.midweek_archetype_snapshots to service_role;

create function kut._mm_snapshot_archetypes()
returns trigger language plpgsql security definer set search_path = kut, pg_catalog as $$
begin
  insert into kut.midweek_archetype_snapshots (tournament_id, player_id, archetype)
  select new.id, player.id, player.archetype
  from kut.players player;
  return null;
end $$;
revoke all on function kut._mm_snapshot_archetypes() from public, anon, authenticated;

create trigger midweek_tournament_archetype_snapshot
  after insert on kut.midweek_tournaments
  for each row execute function kut._mm_snapshot_archetypes();

-- The week open now. It opened before this snapshot existed, so it gets the
-- roster as it stands at the push.
insert into kut.midweek_archetype_snapshots (tournament_id, player_id, archetype)
select tournament.id, player.id, player.archetype
from kut.midweek_tournaments tournament
cross join kut.players player
where tournament.status = 'open';

-- 2. The field reads the snapshot ---------------------------------------------------
-- Identical to 20261005000000_midweek_engine.sql section 4 except that a card's
-- archetype is the tournament's snapshot, or the live one for a Player without
-- a row (created after the open, or a null p_tournament_id).
create or replace function kut._mm_field(p_tournament_id uuid, p_as_of timestamptz)
returns jsonb language plpgsql stable security definer set search_path = kut, pg_catalog as $$
declare v_entrants jsonb; v_warnings jsonb;
begin
  with members as (
    select profile.id as user_id, profile.display_name
    from kut.profiles profile
    where not profile.is_disabled
      and not exists (
        select 1 from kut.midweek_opt_outs opt_out
        where opt_out.user_id = profile.id and opt_out.opted_out_at <= p_as_of)
  ),
  cards as (
    select card.owner_id as user_id, card.id as card_id, edition.player_id,
      coalesce(edition.snapshot_ovr, state.live_ovr, 30) as ovr,
      coalesce(snapshot.archetype, player.archetype) as archetype,
      edition.is_live and kut._active_injury_period(player.id) is not null as injured
    from kut.user_cards card
    join members on members.user_id = card.owner_id
    join kut.card_editions edition on edition.id = card.edition_id
    join kut.players player on player.id = edition.player_id
    left join kut.midweek_archetype_snapshots snapshot
      on snapshot.tournament_id = p_tournament_id and snapshot.player_id = player.id
    left join kut.seasons active_season on active_season.is_active
    left join kut.player_season_state state on state.player_id = player.id and state.season_id = active_season.id
    where card.burned_at is null
  ),
  saved as (
    select squad.user_id, squad_card.slot, squad_card.card_id,
      exists (select 1 from cards where cards.card_id = squad_card.card_id and cards.user_id = squad.user_id) as kept
    from kut.midweek_squads squad
    join kut.midweek_squad_cards squad_card on squad_card.squad_id = squad.id
    where squad.tournament_id = p_tournament_id
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'userId', members.user_id,
      'saved', coalesce((
        select jsonb_agg(jsonb_build_object('cardId', cards.card_id, 'playerId', cards.player_id, 'ovr', cards.ovr,
          'archetype', cards.archetype, 'injured', cards.injured) order by saved.slot)
        from saved join cards on cards.card_id = saved.card_id
        where saved.user_id = members.user_id and saved.kept), '[]'::jsonb),
      'owned', (
        select jsonb_agg(jsonb_build_object('cardId', cards.card_id, 'playerId', cards.player_id, 'ovr', cards.ovr,
          'archetype', cards.archetype, 'injured', cards.injured) order by cards.card_id)
        from cards where cards.user_id = members.user_id)
    ) order by members.user_id), '[]'::jsonb),
    (select coalesce(jsonb_agg(jsonb_build_object('level', 'warning', 'message', format(
        case when exists (select 1 from saved kept where kept.user_id = lost.user_id and kept.kept)
          then '%s: the card saved in slot %s is no longer theirs, so a trialist plays'
          else '%s: the card saved in slot %s is no longer theirs, and none is left, so an auto squad plays' end,
        member.display_name, lost.slot)) order by member.display_name, lost.slot), '[]'::jsonb)
      from saved lost
      join members member on member.user_id = lost.user_id
      where not lost.kept and exists (select 1 from cards where cards.user_id = lost.user_id))
  into v_entrants, v_warnings
  from members
  where exists (select 1 from cards where cards.user_id = members.user_id);

  return jsonb_build_object('entrants', v_entrants, 'warnings', v_warnings);
end $$;
revoke all on function kut._mm_field(uuid, timestamptz) from public, anon, authenticated;

-- 3. The members' read, for the picker ------------------------------------------------
-- Archetypes are on every card already, so every snapshot row is readable by an
-- active member, like the other Midweek projections.
create view kut.midweek_archetypes
with (security_invoker = false, security_barrier = true)
as
select snapshot.tournament_id, snapshot.player_id, snapshot.archetype
from kut.midweek_archetype_snapshots snapshot
where kut.is_active_member();

comment on view kut.midweek_archetypes is
  'ADR-099: each Player''s archetype as frozen when the Midweek tournament opened, which the lock plays. Gated on kut.is_active_member() (ADR-079).';
revoke all on kut.midweek_archetypes from public, anon;
grant select on kut.midweek_archetypes to authenticated, service_role;
