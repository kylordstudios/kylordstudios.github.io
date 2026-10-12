-- Kylord Studios Gold Pass: database setup for the Supabase project "kylord-gold-pass".
-- Run once in Supabase → SQL Editor (or as a migration).
create extension if not exists pgcrypto with schema extensions;

create table public.gp_players (
  pid uuid primary key default gen_random_uuid(),
  tag text not null check (char_length(tag) between 3 and 16),
  av text not null default 'vanguard' check (char_length(av) <= 32),
  joined timestamptz not null default now(),
  wins int not null default 0,
  games int not null default 0,
  last_seen timestamptz not null default now()
);
create unique index gp_players_tag_lower on public.gp_players (lower(tag));

create table public.gp_secrets (
  pid uuid primary key references public.gp_players(pid) on delete cascade,
  secret_hash text not null
);

create table public.gp_requests (
  from_pid uuid not null references public.gp_players(pid) on delete cascade,
  to_pid uuid not null references public.gp_players(pid) on delete cascade,
  created timestamptz not null default now(),
  primary key (from_pid, to_pid),
  check (from_pid <> to_pid)
);
create index gp_requests_to on public.gp_requests (to_pid);

alter table public.gp_players enable row level security;
alter table public.gp_secrets enable row level security;
alter table public.gp_requests enable row level security;
revoke all on public.gp_players, public.gp_secrets, public.gp_requests from anon, authenticated;

create or replace function public.gp_auth(p_pid uuid, p_secret text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.gp_secrets s where s.pid = p_pid
    and s.secret_hash = encode(extensions.digest(p_secret, 'sha256'), 'hex'));
$$;

create or replace function public.gp_clean_tag(t text) returns text
language sql immutable set search_path = '' as $$
  select left(btrim(regexp_replace(coalesce(t, ''), '[^A-Za-z0-9_ .-]', '', 'g')), 16);
$$;

create or replace function public.gp_profile_json(p_pid uuid) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object('pid', p.pid, 'tag', p.tag, 'av', p.av, 'joined', p.joined, 'wins', p.wins, 'games', p.games)
  from public.gp_players p where p.pid = p_pid;
$$;

create or replace function public.gp_register(p_tag text, p_av text) returns json
language plpgsql volatile security definer set search_path = '' as $$
declare t text := public.gp_clean_tag(p_tag); new_pid uuid; sec text;
begin
  if char_length(t) < 3 then raise exception 'Pick a gamertag of 3 to 16 letters or numbers'; end if;
  if exists (select 1 from public.gp_players where lower(tag) = lower(t)) then raise exception 'That gamertag is taken. Try another.'; end if;
  insert into public.gp_players(tag, av) values (t, left(coalesce(p_av, 'vanguard'), 32)) returning pid into new_pid;
  sec := encode(extensions.gen_random_bytes(24), 'hex');
  insert into public.gp_secrets(pid, secret_hash) values (new_pid, encode(extensions.digest(sec, 'sha256'), 'hex'));
  return json_build_object('profile', public.gp_profile_json(new_pid), 'secret', sec);
end $$;

create or replace function public.gp_login(p_pid uuid, p_secret text) returns json
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not public.gp_auth(p_pid, p_secret) then raise exception 'Gold Pass not found'; end if;
  update public.gp_players set last_seen = now() where pid = p_pid;
  return public.gp_profile_json(p_pid);
end $$;

create or replace function public.gp_update(p_pid uuid, p_secret text, p_tag text, p_av text) returns json
language plpgsql volatile security definer set search_path = '' as $$
declare t text := public.gp_clean_tag(p_tag);
begin
  if not public.gp_auth(p_pid, p_secret) then raise exception 'Gold Pass not found'; end if;
  if char_length(t) < 3 then raise exception 'Pick a gamertag of 3 to 16 letters or numbers'; end if;
  if exists (select 1 from public.gp_players where lower(tag) = lower(t) and pid <> p_pid) then raise exception 'That gamertag is taken. Try another.'; end if;
  update public.gp_players set tag = t, av = left(coalesce(p_av, av), 32) where pid = p_pid;
  return public.gp_profile_json(p_pid);
end $$;

create or replace function public.gp_friends(p_pid uuid, p_secret text) returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.gp_auth(p_pid, p_secret) then raise exception 'Gold Pass not found'; end if;
  return coalesce((
    select json_agg(json_build_object('pid', p.pid, 'tag', p.tag, 'av', p.av, 'wins', p.wins,
      'state', case when o.from_pid is not null and i.from_pid is not null then 'friend' when o.from_pid is not null then 'outgoing' else 'incoming' end) order by lower(p.tag))
    from public.gp_players p
    left join public.gp_requests o on o.from_pid = p_pid and o.to_pid = p.pid
    left join public.gp_requests i on i.from_pid = p.pid and i.to_pid = p_pid
    where o.from_pid is not null or i.from_pid is not null), '[]'::json);
end $$;

create or replace function public.gp_add_friend(p_pid uuid, p_secret text, p_to uuid, p_tag text) returns json
language plpgsql volatile security definer set search_path = '' as $$
declare target uuid := p_to;
begin
  if not public.gp_auth(p_pid, p_secret) then raise exception 'Gold Pass not found'; end if;
  if target is null then select pid into target from public.gp_players where lower(tag) = lower(public.gp_clean_tag(p_tag)); end if;
  if target is null or not exists (select 1 from public.gp_players where pid = target) then raise exception 'No Gold Pass member has that gamertag'; end if;
  if target = p_pid then raise exception 'That is you!'; end if;
  if (select count(*) from public.gp_requests where from_pid = p_pid) >= 200 then raise exception 'Your friends list is full'; end if;
  insert into public.gp_requests(from_pid, to_pid) values (p_pid, target) on conflict do nothing;
  return public.gp_profile_json(target);
end $$;

create or replace function public.gp_remove_friend(p_pid uuid, p_secret text, p_other uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not public.gp_auth(p_pid, p_secret) then raise exception 'Gold Pass not found'; end if;
  delete from public.gp_requests where (from_pid = p_pid and to_pid = p_other) or (from_pid = p_other and to_pid = p_pid);
end $$;

create or replace function public.gp_result(p_pid uuid, p_secret text, p_won boolean) returns json
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not public.gp_auth(p_pid, p_secret) then raise exception 'Gold Pass not found'; end if;
  update public.gp_players set games = games + 1, wins = wins + case when p_won then 1 else 0 end, last_seen = now() where pid = p_pid;
  return public.gp_profile_json(p_pid);
end $$;

revoke all on function public.gp_auth(uuid, text), public.gp_profile_json(uuid), public.gp_clean_tag(text) from public, anon, authenticated;
revoke all on function public.gp_register(text, text), public.gp_login(uuid, text), public.gp_update(uuid, text, text, text),
  public.gp_friends(uuid, text), public.gp_add_friend(uuid, text, uuid, text), public.gp_remove_friend(uuid, text, uuid),
  public.gp_result(uuid, text, boolean) from public;
grant execute on function public.gp_register(text, text), public.gp_login(uuid, text), public.gp_update(uuid, text, text, text),
  public.gp_friends(uuid, text), public.gp_add_friend(uuid, text, uuid, text), public.gp_remove_friend(uuid, text, uuid),
  public.gp_result(uuid, text, boolean) to anon, authenticated;
