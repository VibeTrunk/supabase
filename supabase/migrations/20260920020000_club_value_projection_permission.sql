-- Slice B compatibility follow-up: the owner-scoped projections execute this
-- immutable arithmetic helper as the authenticated caller.
revoke execute on function kut.duplicate_edition_contribution(bigint,integer) from public,anon;
grant execute on function kut.duplicate_edition_contribution(bigint,integer) to authenticated,service_role;
