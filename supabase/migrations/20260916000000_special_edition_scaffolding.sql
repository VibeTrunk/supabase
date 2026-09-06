-- ADR-055: complete the frozen Special-edition storage contract without
-- issuing an edition or card. Packs and starter grants remain Live-only.
-- Additive locally; activation must first confirm the preflight below returns
-- no incomplete historical Special rows.

do $$
begin
  if exists (select 1 from kut.card_editions where not is_live) then
    raise exception 'Special scaffolding requires zero existing Special editions';
  end if;
end $$;

alter table kut.card_editions
  add column snapshot_archetype text,
  add column snapshot_rarity_tier text,
  add column description text,
  add column artwork_key text,
  add column artwork_version integer;

alter table kut.card_editions
  add constraint card_editions_snapshot_archetype_check
    check (snapshot_archetype is null or snapshot_archetype in
      ('all_rounder','speedster','finisher','playmaker','defender','tank','goalkeeper')),
  add constraint card_editions_snapshot_rarity_check
    check (snapshot_rarity_tier is null or snapshot_rarity_tier in
      ('common','bronze','silver','gold','holo','elite')),
  add constraint card_editions_description_check
    check (description is null or char_length(btrim(description)) between 1 and 500),
  add constraint card_editions_artwork_key_check
    check (artwork_key is null or artwork_key ~ '^[a-z0-9][a-z0-9/_-]{0,119}$'),
  add constraint card_editions_artwork_version_check
    check (artwork_version is null or artwork_version > 0),
  add constraint card_editions_availability_interval_check
    check (pack_available_until is null or pack_available_from is null or pack_available_until > pack_available_from),
  add constraint card_editions_supply_check
    check (max_supply is null or minted_count <= max_supply);

alter table kut.card_editions drop constraint if exists card_editions_snapshot_ovr_check;

alter table kut.card_editions
  add constraint card_editions_snapshot_ovr_check check (snapshot_ovr is null or snapshot_ovr between 30 and 95);

alter table kut.card_editions drop constraint if exists card_editions_check;

alter table kut.card_editions add constraint card_editions_kind_contract_check check (
  (is_live and edition_type = 'live'
    and snapshot_ovr is null and snapshot_pac is null and snapshot_sho is null
    and snapshot_pas is null and snapshot_dri is null and snapshot_def is null and snapshot_phy is null
    and snapshot_archetype is null and snapshot_rarity_tier is null
    and description is null and artwork_key is null and artwork_version is null
    and special_discard_multiplier is null and pack_available_from is null
    and pack_available_until is null and max_supply is null and pack_weight is null and issued_at is null)
  or
  (not is_live and edition_type <> 'live'
    and snapshot_ovr is not null and snapshot_pac is not null and snapshot_sho is not null
    and snapshot_pas is not null and snapshot_dri is not null and snapshot_def is not null and snapshot_phy is not null
    and snapshot_archetype is not null and snapshot_rarity_tier is not null
    and description is not null and artwork_key is not null and artwork_version is not null
    and special_discard_multiplier is not null and issued_at is not null)
);

create or replace function kut.protect_frozen_card_edition()
returns trigger
language plpgsql
set search_path = kut, pg_catalog
as $$
begin
  if old.player_id is distinct from new.player_id
    or old.edition_type is distinct from new.edition_type
    or old.is_live is distinct from new.is_live then
    raise exception 'card edition identity is immutable' using errcode = 'P0001';
  end if;

  if not old.is_live and (
    old.title is distinct from new.title or old.snapshot_ovr is distinct from new.snapshot_ovr
    or old.snapshot_pac is distinct from new.snapshot_pac or old.snapshot_sho is distinct from new.snapshot_sho
    or old.snapshot_pas is distinct from new.snapshot_pas or old.snapshot_dri is distinct from new.snapshot_dri
    or old.snapshot_def is distinct from new.snapshot_def or old.snapshot_phy is distinct from new.snapshot_phy
    or old.snapshot_archetype is distinct from new.snapshot_archetype
    or old.snapshot_rarity_tier is distinct from new.snapshot_rarity_tier
    or old.description is distinct from new.description or old.artwork_key is distinct from new.artwork_key
    or old.artwork_version is distinct from new.artwork_version
    or old.special_discard_multiplier is distinct from new.special_discard_multiplier
    or old.issued_at is distinct from new.issued_at or old.metadata is distinct from new.metadata
  ) then
    raise exception 'frozen Special edition fields are immutable' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger card_editions_protect_frozen
before update on kut.card_editions
for each row execute function kut.protect_frozen_card_edition();

revoke execute on function kut.protect_frozen_card_edition() from public, anon, authenticated;

comment on table kut.card_editions is
  'Live editions resolve current season state. Specials require complete immutable snapshots. ADR-055 issued zero Specials.';
