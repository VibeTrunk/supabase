-- TFH Chronicle read projections (ADR-049).
-- Additive tier: computed views only, no data change.
-- Rollback: drop view kut.chronicle_tier_changes; drop view kut.chronicle_weeks;

create view kut.chronicle_weeks
with (security_invoker = true, security_barrier = true)
as
select
  date_trunc('week', session.session_date)::date as week_start,
  (date_trunc('week', session.session_date)::date + 6) as week_end,
  count(distinct session.id)::integer as session_count,
  count(attendance.player_id)::integer as appearance_count,
  count(distinct attendance.player_id)::integer as attendee_count,
  coalesce(sum(attendance.goals), 0)::integer as goal_count
from kut.match_sessions session
left join kut.attendance attendance on attendance.session_id = session.id
where session.status = 'published'
group by date_trunc('week', session.session_date)::date;

revoke all on kut.chronicle_weeks from public;
grant select on kut.chronicle_weeks to authenticated, service_role;

create view kut.chronicle_tier_changes
with (security_invoker = true, security_barrier = true)
as
with snapshots as (
  select
    snapshot.player_id,
    snapshot.season_id,
    snapshot.week_start,
    snapshot.live_ovr,
    snapshot.rarity_tier as to_tier,
    lag(snapshot.rarity_tier) over (
      partition by snapshot.player_id, snapshot.season_id
      order by snapshot.week_start
    ) as from_tier
  from kut.player_rating_snapshots snapshot
)
select
  snapshots.week_start,
  snapshots.player_id,
  player.slug,
  player.display_name,
  player.photo_path,
  snapshots.from_tier,
  snapshots.to_tier,
  snapshots.live_ovr
from snapshots
join kut.players player on player.id = snapshots.player_id
where snapshots.from_tier is not null
  and snapshots.from_tier <> snapshots.to_tier;

revoke all on kut.chronicle_tier_changes from public;
grant select on kut.chronicle_tier_changes to authenticated, service_role;
