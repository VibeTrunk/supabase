-- Slice E compatibility follow-up: the RPC intent is `submit`; persisted report
-- state is the past-tense `submitted` used by readers and finalization.
create function kut.normalize_session_report_status()
returns trigger language plpgsql set search_path=kut,pg_catalog as $$
begin
  if new.status='submit' then new.status:='submitted'; end if;
  return new;
end $$;
create trigger session_reports_normalize_status before insert or update of status on kut.session_reports
for each row execute function kut.normalize_session_report_status();
