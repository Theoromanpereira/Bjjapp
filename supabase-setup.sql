-- Tatame · configuração do Supabase (rode no SQL Editor; é seguro rodar de novo)
create table if not exists public.user_data (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.user_data enable row level security;

drop policy if exists "own row" on public.user_data;
create policy "own row" on public.user_data
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Sem este GRANT toda leitura/gravação falha com 403 (permission denied),
-- porque tabelas criadas por SQL não ficam expostas à API automaticamente.
grant select, insert, update, delete on public.user_data to authenticated;
