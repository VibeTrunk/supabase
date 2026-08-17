-- KUT owns this schema in the shared VibeTrunk Supabase project.
-- Tables and RLS policies arrive in the Phase 1A migrations.
create schema if not exists kut;

comment on schema kut is
  'Kelderklasse Ultimate Team application data.';
