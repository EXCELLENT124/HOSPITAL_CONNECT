-- Health Connect approval-document upgrade
-- Run this once in Supabase SQL Editor if advanced_features.sql was already applied.

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

create index if not exists professional_documents_org_idx
on public.professional_documents(organisation_id, created_at desc);

alter table public.professional_documents enable row level security;

drop policy if exists "members and admins view professional documents"
on public.professional_documents;
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

drop policy if exists "members upload professional documents"
on public.professional_documents;
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

drop policy if exists "members and admins read professional files"
on storage.objects;
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

drop policy if exists "members upload professional files"
on storage.objects;
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
