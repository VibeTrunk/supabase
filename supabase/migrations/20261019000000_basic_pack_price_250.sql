-- ADR-136: raise the basic three-card pack price to 250 KUT Coins.
-- Existing openings retain their recorded price_paid and ledger entries.

do $$
declare
  v_count integer;
begin
  select count(*) into v_count from kut.pack_definitions where slug = 'tfh-pack';
  if v_count <> 1 then
    raise exception 'expected exactly one tfh-pack definition, found %', v_count;
  end if;
end;
$$;

update kut.pack_definitions
set price = 250,
    updated_at = now()
where slug = 'tfh-pack';
