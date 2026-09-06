-- Slice D compatibility follow-up: card_editions uses the established
-- pack_available_* column names.
create or replace function kut.set_card_want(p_edition_id uuid, p_wanted boolean)
returns jsonb language plpgsql security definer set search_path=kut,pg_catalog as $$
declare v_user_id uuid:=auth.uid(); v_count integer;
begin
  if v_user_id is null then raise exception 'authentication required' using errcode='42501'; end if;
  if p_edition_id is null or p_wanted is null then raise exception 'edition and wanted are required' using errcode='22023'; end if;
  perform 1 from kut.profiles where id=v_user_id and not is_disabled for update;
  if not found then raise exception 'active profile not found' using errcode='42501'; end if;
  perform 1 from kut.card_editions e join kut.players p on p.id=e.player_id
  where e.id=p_edition_id and p.is_active and p.is_collectible and
    (e.is_live or (e.issued_at is not null and e.issued_at<=now()
      and (e.pack_available_from is null or e.pack_available_from<=now())
      and (e.pack_available_until is null or e.pack_available_until>now())));
  if not found then raise exception 'edition is not selectable' using errcode='P0002'; end if;
  if p_wanted then
    select count(*) into v_count from kut.card_wants where user_id=v_user_id and state='active';
    if v_count>=100 and not exists(select 1 from kut.card_wants where user_id=v_user_id and edition_id=p_edition_id and state='active') then raise exception 'wanted-card limit reached' using errcode='P0001'; end if;
    insert into kut.card_wants(user_id,edition_id,state,fulfilled_at) values(v_user_id,p_edition_id,'active',null)
    on conflict(user_id,edition_id) do update set state='active',fulfilled_at=null;
  else delete from kut.card_wants where user_id=v_user_id and edition_id=p_edition_id; end if;
  return jsonb_build_object('edition_id',p_edition_id,'wanted',p_wanted);
end $$;
revoke all on function kut.set_card_want(uuid,boolean) from public,anon;
grant execute on function kut.set_card_want(uuid,boolean) to authenticated,service_role;
