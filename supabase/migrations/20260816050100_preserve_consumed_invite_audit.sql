alter table kut.invitations
  drop constraint invitations_consumed_by_fkey,
  add constraint invitations_consumed_by_fkey
    foreign key (consumed_by) references auth.users(id) on delete restrict;
