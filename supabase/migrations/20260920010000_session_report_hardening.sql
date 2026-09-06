-- Slice E follow-up kept in the same review unit as ADR-059.
-- New seasons must receive an explicit cutover row, including transactional test
-- and future-season fixtures. Service finalization may invoke the shared rebuild.

create function kut.initialize_season_rating_rules()
returns trigger language plpgsql security definer set search_path=kut,pg_catalog as $$
begin
  insert into kut.season_rating_rules(season_id,v2_starts_week)
  values(new.id,date_trunc('week',greatest(new.starts_on,current_date))::date+7)
  on conflict(season_id) do nothing;
  return new;
end $$;
create trigger seasons_initialize_rating_rules after insert on kut.seasons
for each row execute function kut.initialize_season_rating_rules();
revoke execute on function kut.initialize_season_rating_rules() from public,anon,authenticated;

create or replace function kut.rebuild_season(p_season_id uuid)
returns integer language plpgsql security definer set search_path=kut,pg_catalog as $$
begin
  if not kut.is_admin() and coalesce(auth.role(),'')<>'service_role' then
    raise exception 'admin or service access required' using errcode='42501';
  end if;
  return kut._rebuild_season_core(p_season_id);
end $$;
revoke execute on function kut.rebuild_season(uuid) from public,anon;
grant execute on function kut.rebuild_season(uuid) to authenticated,service_role;
