-- ADR-056: Club Value v3. Per edition, copies contribute 100%, 20%, 5%, 0%.
-- Data-changing rule/projection migration; no wallets, cards, or ledger rows
-- are rewritten. Rollback restores the two ADR-041/044 view bodies and drops
-- the two private breakdown views plus this helper.

create or replace function kut.duplicate_edition_contribution(p_discard_value bigint, p_copy_count integer)
returns bigint
language sql
immutable
strict
set search_path = kut, pg_catalog
as $$
  select case when p_copy_count >= 1 then p_discard_value else 0 end
       + case when p_copy_count >= 2 then floor(p_discard_value * 20 / 100.0)::bigint else 0 end
       + case when p_copy_count >= 3 then floor(p_discard_value * 5 / 100.0)::bigint else 0 end
$$;
revoke execute on function kut.duplicate_edition_contribution(bigint,integer) from public, anon;
grant execute on function kut.duplicate_edition_contribution(bigint,integer) to authenticated, service_role;

create view kut.my_club_value_editions
with (security_invoker = false, security_barrier = true)
as
with resolved as (
  select c.owner_id, c.edition_id, e.player_id, e.title, e.edition_type, e.is_live,
    case when e.is_live then coalesce(s.live_ovr,30) else e.snapshot_ovr end as ovr,
    round(10 * power(1.08::numeric,
      (case when e.is_live then coalesce(s.live_ovr,30) else e.snapshot_ovr end) - 30)
      * case when e.is_live then 1 else e.special_discard_multiplier end)::bigint as discard_value,
    count(*)::integer as copy_count
  from kut.user_cards c
  join kut.card_editions e on e.id=c.edition_id
  left join kut.seasons active on active.is_active
  left join kut.player_season_state s on s.player_id=e.player_id and s.season_id=active.id
  where c.burned_at is null
  group by c.owner_id,c.edition_id,e.player_id,e.title,e.edition_type,e.is_live,e.snapshot_ovr,
    e.special_discard_multiplier,s.live_ovr
)
select edition_id, player_id, title as edition_title, edition_type, is_live, ovr,
  discard_value, copy_count,
  kut.duplicate_edition_contribution(discard_value,copy_count) as club_value_contribution
from resolved where owner_id=auth.uid();

create view kut.my_club_value_copies
with (security_invoker = false, security_barrier = true)
as
with ranked as (
  select c.id as card_id,c.owner_id,c.edition_id,c.acquired_at,e.title as edition_title,
    p.display_name,p.slug as player_slug,
    case when e.is_live then coalesce(s.live_ovr,30) else e.snapshot_ovr end as ovr,
    round(10 * power(1.08::numeric,
      (case when e.is_live then coalesce(s.live_ovr,30) else e.snapshot_ovr end)-30)
      * case when e.is_live then 1 else e.special_discard_multiplier end)::bigint as discard_value,
    row_number() over(partition by c.owner_id,c.edition_id order by c.acquired_at,c.id)::integer as copy_position,
    count(*) over(partition by c.owner_id,c.edition_id)::integer as copy_count
  from kut.user_cards c
  join kut.card_editions e on e.id=c.edition_id
  join kut.players p on p.id=e.player_id
  left join kut.seasons active on active.is_active
  left join kut.player_season_state s on s.player_id=e.player_id and s.season_id=active.id
  where c.burned_at is null
)
select card_id,edition_id,edition_title,display_name,player_slug,ovr,discard_value,
  copy_position,copy_count,
  case copy_position when 1 then 100 when 2 then 20 when 3 then 5 else 0 end::integer as weight_percent,
  case copy_position when 1 then discard_value when 2 then floor(discard_value*20/100.0)::bigint
    when 3 then floor(discard_value*5/100.0)::bigint else 0 end as club_value_contribution,
  (discard_value
    + kut.duplicate_edition_contribution(discard_value,copy_count-1)
    - kut.duplicate_edition_contribution(discard_value,copy_count))::bigint as club_value_change_if_discarded
from ranked where owner_id=auth.uid();

drop view kut.my_club_value;
create view kut.my_club_value
with (security_invoker = false, security_barrier = true)
as
with owned as (
  select coalesce(sum(club_value_contribution),0)::bigint as owned_cards_value,
    coalesce(sum(copy_count),0)::integer as card_count,
    count(distinct player_id)::integer as unique_player_count
  from kut.my_club_value_editions
)
select profile.display_name,coalesce(wallet.balance,0)::bigint as wallet_balance,
  owned.card_count,owned.unique_player_count,owned.owned_cards_value,
  4::integer as personal_card_weight,personal.player_name as personal_card_player_name,
  personal.slug as personal_card_player_slug,coalesce(personal.live_ovr,0)::integer as personal_card_ovr,
  coalesce(personal.base_value,0)::bigint as personal_card_base_value,
  (coalesce(personal.base_value,0)*4)::bigint as personal_card_bonus,
  (coalesce(wallet.balance,0)+owned.owned_cards_value+coalesce(personal.base_value,0)*4)::bigint as club_value
from kut.profiles profile
cross join owned
left join kut.wallets wallet on wallet.user_id=profile.id
left join lateral (
  select p.display_name as player_name,p.slug,coalesce(s.live_ovr,30) as live_ovr,
    round(10*power(1.08::numeric,coalesce(s.live_ovr,30)-30))::bigint as base_value
  from kut.players p left join kut.seasons active on active.is_active
  left join kut.player_season_state s on s.player_id=p.id and s.season_id=active.id
  where p.id=profile.player_id and p.is_active
) personal on true
where profile.id=auth.uid() and not profile.is_disabled;

create or replace view kut.club_value_leaderboard
with (security_invoker = false, security_barrier = true)
as
with resolved as (
  select c.owner_id,c.edition_id,e.player_id,
    round(10*power(1.08::numeric,(case when e.is_live then coalesce(s.live_ovr,30) else e.snapshot_ovr end)-30)
      * case when e.is_live then 1 else e.special_discard_multiplier end)::bigint as discard_value,
    count(*)::integer as copy_count
  from kut.user_cards c join kut.card_editions e on e.id=c.edition_id
  left join kut.seasons active on active.is_active
  left join kut.player_season_state s on s.player_id=e.player_id and s.season_id=active.id
  where c.burned_at is null group by c.owner_id,c.edition_id,e.player_id,e.is_live,e.snapshot_ovr,e.special_discard_multiplier,s.live_ovr
), owned as (
  select owner_id,sum(kut.duplicate_edition_contribution(discard_value,copy_count))::bigint as owned_cards_value,
    sum(copy_count)::integer as card_count,count(distinct player_id)::integer as unique_player_count
  from resolved group by owner_id
), totals as (
  select p.id,p.display_name,p.club_name,coalesce(w.balance,0)::bigint wallet_balance,
    coalesce(o.card_count,0)::integer card_count,coalesce(o.unique_player_count,0)::integer unique_player_count,
    coalesce(o.owned_cards_value,0)::bigint owned_cards_value,
    (coalesce(personal.base_value,0)*4)::bigint personal_card_bonus
  from kut.profiles p left join kut.wallets w on w.user_id=p.id left join owned o on o.owner_id=p.id
  left join lateral (
    select round(10*power(1.08::numeric,coalesce(s.live_ovr,30)-30))::bigint base_value
    from kut.players pl left join kut.seasons active on active.is_active
    left join kut.player_season_state s on s.player_id=pl.id and s.season_id=active.id
    where pl.id=p.player_id and pl.is_active
  ) personal on true where not p.is_disabled and p.role='user'
)
select rank() over(order by (wallet_balance+owned_cards_value+personal_card_bonus) desc,display_name)::integer rank,
  display_name,coalesce(nullif(btrim(club_name),''),display_name||'''s Club') club_name,
  (wallet_balance+owned_cards_value+personal_card_bonus)::bigint club_value,
  card_count,unique_player_count,id=auth.uid() is_current_user
from totals;

revoke all on kut.my_club_value_editions,kut.my_club_value_copies,kut.my_club_value,kut.club_value_leaderboard from public;
grant select on kut.my_club_value_editions,kut.my_club_value_copies,kut.my_club_value,kut.club_value_leaderboard to authenticated,service_role;
