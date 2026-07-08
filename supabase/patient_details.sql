-- Health Connect patient-detail upgrade
-- Run once after patient_login.sql.

alter table public.raf_cases
  add column if not exists patient_phone text,
  add column if not exists patient_id_number text,
  add column if not exists patient_date_of_birth date,
  add column if not exists patient_address text,
  add column if not exists emergency_contact_name text,
  add column if not exists emergency_contact_phone text,
  add column if not exists accident_date date,
  add column if not exists accident_description text;

create index if not exists raf_cases_patient_phone_idx
on public.raf_cases(patient_phone);

create index if not exists raf_cases_patient_id_number_idx
on public.raf_cases(patient_id_number);
