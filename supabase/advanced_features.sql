-- Health Connect advanced workflow migration
-- Run once in the Supabase SQL Editor after schema.sql.

create table if not exists public.user_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Health Connect user',
  email text,
  suspended boolean not null default false,
  is_platform_admin boolean not null default false,
  created_at timestamptz not null default now()
);

insert into public.user_profiles (user_id, display_name, email)
select id, coalesce(raw_user_meta_data->>'name', 'Health Connect user'), email
from auth.users
on conflict (user_id) do update set
  display_name = excluded.display_name,
  email = excluded.email;

alter table public.organisations
  add column if not exists suspended boolean not null default false;

alter table public.case_documents
  add column if not exists category text not null default 'Other',
  add column if not exists uploader_name text,
  add column if not exists version integer not null default 1,
  add column if not exists replaced_document_id uuid references public.case_documents(id),
  add column if not exists is_current boolean not null default true,
  add column if not exists updated_at timestamptz not null default now();

create table if not exists public.case_tasks (
  id uuid primary key default gen_random_uuid(),
  case_id text not null references public.raf_cases(id) on delete cascade,
  title text not null check (char_length(title) between 2 and 240),
  description text not null default '',
  assigned_to uuid references auth.users(id),
  created_by uuid not null references auth.users(id),
  due_at timestamptz,
  priority text not null default 'medium'
    check (priority in ('low', 'medium', 'high', 'urgent')),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.task_comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.case_tasks(id) on delete cascade,
  author_id uuid not null references auth.users(id),
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);

create table if not exists public.document_history (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.case_documents(id) on delete cascade,
  case_id text not null references public.raf_cases(id) on delete cascade,
  actor_id uuid not null references auth.users(id),
  action text not null check (action in ('uploaded', 'renamed', 'categorised', 'replaced', 'downloaded')),
  detail text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  case_id text references public.raf_cases(id) on delete cascade,
  type text not null,
  title text not null,
  body text not null default '',
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.audit_logs (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users(id),
  action text not null,
  entity_type text not null,
  entity_id text,
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.professional_documents (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references public.organisations(id) on delete cascade,
  uploaded_by uuid not null references auth.users(id),
  uploader_name text,
  file_name text not null,
  storage_path text not null unique,
  category text not null default 'Professional approval',
  created_at timestamptz not null default now()
);

create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.user_profiles
    where user_id = auth.uid() and is_platform_admin and not suspended
  );
$$;

create or replace function public.is_case_participant(target_case text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.raf_cases c
    join public.memberships m
      on m.organisation_id in (c.hospital_id, c.assigned_lawyer_id)
    where c.id = target_case and m.user_id = auth.uid()
  ) or public.is_platform_admin();
$$;

create or replace function public.notify_case_participants(
  target_case text, notification_type text, notification_title text, notification_body text
) returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications (user_id, case_id, type, title, body)
  select distinct m.user_id, target_case, notification_type, notification_title, notification_body
  from public.raf_cases c
  join public.memberships m
    on m.organisation_id in (c.hospital_id, c.assigned_lawyer_id)
  where c.id = target_case and m.user_id <> auth.uid();
end;
$$;

create or replace function public.set_organisation_state(target_id uuid, approve boolean, suspend boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_platform_admin() then raise exception 'Administrator access required'; end if;
  update public.organisations set verified = approve, suspended = suspend where id = target_id;
  insert into public.audit_logs(actor_id, action, entity_type, entity_id, detail)
  values(auth.uid(), 'organisation_state_changed', 'organisation', target_id::text,
    jsonb_build_object('verified', approve, 'suspended', suspend));
end;
$$;

create or replace function public.set_user_suspended(target_id uuid, suspend boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_platform_admin() then raise exception 'Administrator access required'; end if;
  update public.user_profiles set suspended = suspend where user_id = target_id;
  insert into public.audit_logs(actor_id, action, entity_type, entity_id, detail)
  values(auth.uid(), 'user_suspension_changed', 'user', target_id::text,
    jsonb_build_object('suspended', suspend));
end;
$$;

create index if not exists case_tasks_case_idx on public.case_tasks(case_id);
create index if not exists case_tasks_assignee_idx on public.case_tasks(assigned_to);
create index if not exists task_comments_task_idx on public.task_comments(task_id);
create index if not exists notifications_user_idx on public.notifications(user_id, created_at desc);
create index if not exists document_history_case_idx on public.document_history(case_id, created_at desc);
create index if not exists professional_documents_org_idx on public.professional_documents(organisation_id, created_at desc);

alter table public.user_profiles enable row level security;
alter table public.case_tasks enable row level security;
alter table public.task_comments enable row level security;
alter table public.document_history enable row level security;
alter table public.notifications enable row level security;
alter table public.audit_logs enable row level security;
alter table public.professional_documents enable row level security;

create policy "users read relevant profiles" on public.user_profiles for select to authenticated
using (user_id = auth.uid() or public.is_platform_admin() or exists (
  select 1 from public.memberships mine join public.memberships theirs
    on mine.organisation_id = theirs.organisation_id
  where mine.user_id = auth.uid() and theirs.user_id = user_profiles.user_id
));
create policy "admins update profiles" on public.user_profiles for update to authenticated
using (public.is_platform_admin()) with check (public.is_platform_admin());

create policy "participants manage tasks" on public.case_tasks for all to authenticated
using (public.is_case_participant(case_id))
with check (public.is_case_participant(case_id));
create policy "participants manage task comments" on public.task_comments for all to authenticated
using (exists(select 1 from public.case_tasks t where t.id = task_id and public.is_case_participant(t.case_id)))
with check (author_id = auth.uid() and exists(select 1 from public.case_tasks t where t.id = task_id and public.is_case_participant(t.case_id)));
create policy "participants view document history" on public.document_history for select to authenticated
using (public.is_case_participant(case_id));
create policy "participants add document history" on public.document_history for insert to authenticated
with check (actor_id = auth.uid() and public.is_case_participant(case_id));
create policy "users read notifications" on public.notifications for select to authenticated
using (user_id = auth.uid());
create policy "users update notifications" on public.notifications for update to authenticated
using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "admins read audit logs" on public.audit_logs for select to authenticated
using (public.is_platform_admin());

create policy "members and admins view professional documents"
on public.professional_documents for select to authenticated
using (
  public.is_platform_admin()
  or exists (
    select 1 from public.memberships m
    where m.organisation_id = professional_documents.organisation_id
      and m.user_id = auth.uid()
  )
);

create policy "members upload professional documents"
on public.professional_documents for insert to authenticated
with check (
  uploaded_by = auth.uid()
  and exists (
    select 1 from public.memberships m
    where m.organisation_id = professional_documents.organisation_id
      and m.user_id = auth.uid()
  )
);

insert into storage.buckets (id, name, public)
values ('professional-documents', 'professional-documents', false)
on conflict (id) do nothing;

create policy "members and admins read professional files"
on storage.objects for select to authenticated
using (
  bucket_id = 'professional-documents'
  and (
    public.is_platform_admin()
    or exists (
      select 1 from public.memberships m
      where m.organisation_id::text = (storage.foldername(name))[1]
        and m.user_id = auth.uid()
    )
  )
);

create policy "members upload professional files"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'professional-documents'
  and exists (
    select 1 from public.memberships m
    where m.organisation_id::text = (storage.foldername(name))[1]
      and m.user_id = auth.uid()
  )
);

create policy "participants update documents" on public.case_documents for update to authenticated
using (public.is_case_participant(case_id)) with check (public.is_case_participant(case_id));
create policy "participants replace stored files" on storage.objects for update to authenticated
using (bucket_id = 'case-documents' and public.is_case_participant((storage.foldername(name))[1]));

-- After running this migration, make your first platform administrator:
-- update public.user_profiles set is_platform_admin = true where email = 'YOUR_EMAIL';
