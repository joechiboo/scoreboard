-- Phase 1：單一共用比賽的計分板
-- games：比賽（同時只會有一場 live）
-- score_events：加分事件，只新增不刪除；撤銷以 undone 標記
-- game_scores：由事件算出的比分

-- ---------- 資料表 ----------

create table public.games (
  id          uuid primary key default gen_random_uuid(),
  team_a_name text not null default '主隊',
  team_b_name text not null default '客隊',
  status      text not null default 'live' check (status in ('live', 'ended')),
  created_at  timestamptz not null default now(),
  ended_at    timestamptz
);

-- 同時只允許一場 live 比賽
create unique index games_one_live on public.games ((true)) where status = 'live';

create table public.score_events (
  id         bigint generated always as identity primary key,
  game_id    uuid not null references public.games (id) on delete cascade,
  team       char(1) not null check (team in ('A', 'B')),
  points     int not null check (points between -3 and 3 and points <> 0),
  source     text not null default 'manual' check (source in ('manual', 'auto')),
  undone     boolean not null default false,
  created_at timestamptz not null default now()
);

create index score_events_game_id on public.score_events (game_id, id);

-- ---------- 比分 view ----------

create view public.game_scores
with (security_invoker = true) as
select
  g.id as game_id,
  coalesce(sum(e.points) filter (where e.team = 'A' and not e.undone), 0)::int as score_a,
  coalesce(sum(e.points) filter (where e.team = 'B' and not e.undone), 0)::int as score_b
from public.games g
left join public.score_events e on e.game_id = g.id
group by g.id;

-- ---------- RPC ----------

-- 開新局：結束目前 live 的比賽並建立新的一場（同一個 transaction）
create function public.new_game(
  p_team_a_name text default '主隊',
  p_team_b_name text default '客隊'
) returns public.games
language plpgsql
as $$
declare
  g public.games;
begin
  update public.games
     set status = 'ended', ended_at = now()
   where status = 'live';

  insert into public.games (team_a_name, team_b_name)
  values (p_team_a_name, p_team_b_name)
  returning * into g;

  return g;
end;
$$;

-- 撤銷：把該場最後一筆未撤銷的事件標成 undone，回傳被撤銷的事件（沒有則回傳 null）
create function public.undo_last(p_game_id uuid)
returns public.score_events
language plpgsql
as $$
declare
  e public.score_events;
begin
  update public.score_events
     set undone = true
   where id = (
     select id from public.score_events
      where game_id = p_game_id and not undone
      order by id desc
      limit 1
      for update skip locked
   )
  returning * into e;

  return e;
end;
$$;

-- ---------- RLS ----------
-- Phase 1 無登入：anon 可讀、可新增事件、可更新（撤銷／改分），不可刪除

alter table public.games enable row level security;
alter table public.score_events enable row level security;

create policy "games read"   on public.games for select to anon, authenticated using (true);
create policy "games insert" on public.games for insert to anon, authenticated with check (true);
create policy "games update" on public.games for update to anon, authenticated using (true) with check (true);

create policy "events read"   on public.score_events for select to anon, authenticated using (true);
create policy "events insert" on public.score_events for insert to anon, authenticated with check (true);
create policy "events update" on public.score_events for update to anon, authenticated using (true) with check (true);

grant select, insert, update on public.games, public.score_events to anon, authenticated;
grant select on public.game_scores to anon, authenticated;
grant execute on function public.new_game(text, text), public.undo_last(uuid) to anon, authenticated;

-- ---------- Realtime ----------

alter publication supabase_realtime add table public.games, public.score_events;

-- ---------- 初始資料 ----------

insert into public.games default values;
