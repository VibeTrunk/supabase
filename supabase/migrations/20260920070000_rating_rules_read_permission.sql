-- Slice E follow-up: the authenticated Admin attendance screen needs the
-- stored season cutover to explain whether a date opens member reports.
revoke all on kut.season_rating_rules from public, anon;
grant select on kut.season_rating_rules to authenticated, service_role;
