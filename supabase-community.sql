-- Tatame · Comunidades (rode no SQL Editor do Supabase; é seguro rodar de novo)
-- Privacidade: os dados de treino de cada pessoa continuam privados (user_data).
-- Para o ranking, só são compartilhados NOME, MINIATURA e os TOTAIS DA SEMANA
-- (treinos, finalizações aplicadas e sofridas) entre quem participa da mesma comunidade.

create table if not exists public.communities (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 40),
  photo text check (photo is null or char_length(photo) < 150000),
  code text not null unique,
  owner_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.community_members (
  community_id uuid not null references public.communities(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (community_id, user_id)
);
create index if not exists community_members_user_idx on public.community_members (user_id);

create table if not exists public.community_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  avatar text check (avatar is null or char_length(avatar) < 30000),
  updated_at timestamptz not null default now()
);

create table if not exists public.member_stats (
  user_id uuid not null references auth.users(id) on delete cascade,
  week_start date not null,
  trainings int not null default 0 check (trainings >= 0),
  applied int not null default 0 check (applied >= 0),
  suffered int not null default 0 check (suffered >= 0),
  updated_at timestamptz not null default now(),
  primary key (user_id, week_start)
);

alter table public.communities enable row level security;
alter table public.community_members enable row level security;
alter table public.community_profiles enable row level security;
alter table public.member_stats enable row level security;

-- communities / community_members: sem acesso direto; tudo passa pelas funções abaixo
revoke all on public.communities, public.community_members from anon, authenticated;

-- perfil público e totais: cada pessoa só escreve/lê a própria linha (os outros veem via função)
drop policy if exists "own profile" on public.community_profiles;
create policy "own profile" on public.community_profiles
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists "own stats" on public.member_stats;
create policy "own stats" on public.member_stats
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
grant select, insert, update, delete on public.community_profiles, public.member_stats to authenticated;

-- ---------- funções ----------
create or replace function public.gen_community_code() returns text
language plpgsql set search_path = public as $$
declare chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  loop
    c := '';
    for i in 1..8 loop c := c || substr(chars, 1 + floor(random() * length(chars))::int, 1); end loop;
    exit when not exists (select 1 from public.communities x where x.code = c);
  end loop;
  return c;
end $$;

create or replace function public.create_community(p_name text, p_photo text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); new_id uuid;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  if char_length(trim(coalesce(p_name, ''))) < 2 then raise exception 'invalid_name'; end if;
  if (select count(*) from public.community_members cm where cm.user_id = uid) >= 20 then raise exception 'too_many'; end if;
  insert into public.communities (name, photo, code, owner_id)
    values (left(trim(p_name), 40), p_photo, public.gen_community_code(), uid)
    returning id into new_id;
  insert into public.community_members (community_id, user_id) values (new_id, uid);
  return new_id;
end $$;

create or replace function public.join_community(p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); cid uuid;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  select c.id into cid from public.communities c
    where c.code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if cid is null then raise exception 'code_not_found'; end if;
  if exists (select 1 from public.community_members cm where cm.community_id = cid and cm.user_id = uid) then
    return cid;
  end if;
  if (select count(*) from public.community_members cm where cm.user_id = uid) >= 20 then raise exception 'too_many'; end if;
  if (select count(*) from public.community_members cm where cm.community_id = cid) >= 200 then raise exception 'community_full'; end if;
  insert into public.community_members (community_id, user_id) values (cid, uid) on conflict do nothing;
  return cid;
end $$;

create or replace function public.my_communities()
returns table (id uuid, name text, photo text, code text, owner_id uuid, member_count bigint, joined_at timestamptz)
language sql security definer stable set search_path = public as $$
  select c.id, c.name, c.photo, c.code, c.owner_id,
         (select count(*) from public.community_members x where x.community_id = c.id),
         m.joined_at
  from public.communities c
  join public.community_members m on m.community_id = c.id and m.user_id = auth.uid()
  order by m.joined_at;
$$;

create or replace function public.community_leaderboard(p_community uuid, p_week date)
returns table (user_id uuid, name text, avatar text, trainings int, applied int, suffered int, is_me boolean)
language plpgsql security definer stable set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if not exists (select 1 from public.community_members cm where cm.community_id = p_community and cm.user_id = auth.uid()) then
    raise exception 'not_member';
  end if;
  return query
    select m.user_id, coalesce(p.name, 'Atleta')::text, p.avatar,
           coalesce(s.trainings, 0), coalesce(s.applied, 0), coalesce(s.suffered, 0),
           (m.user_id = auth.uid())
    from public.community_members m
    left join public.community_profiles p on p.user_id = m.user_id
    left join public.member_stats s on s.user_id = m.user_id and s.week_start = p_week
    where m.community_id = p_community;
end $$;

create or replace function public.leave_community(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.community_members cm where cm.community_id = p_id and cm.user_id = auth.uid();
  if not exists (select 1 from public.community_members cm where cm.community_id = p_id) then
    delete from public.communities c where c.id = p_id;
  end if;
end $$;

-- só quem está logado chama as funções
revoke execute on function public.gen_community_code() from public, anon, authenticated;
revoke execute on function public.create_community(text, text) from public, anon;
revoke execute on function public.join_community(text) from public, anon;
revoke execute on function public.my_communities() from public, anon;
revoke execute on function public.community_leaderboard(uuid, date) from public, anon;
revoke execute on function public.leave_community(uuid) from public, anon;
grant execute on function public.create_community(text, text) to authenticated;
grant execute on function public.join_community(text) to authenticated;
grant execute on function public.my_communities() to authenticated;
grant execute on function public.community_leaderboard(uuid, date) to authenticated;
grant execute on function public.leave_community(uuid) to authenticated;
