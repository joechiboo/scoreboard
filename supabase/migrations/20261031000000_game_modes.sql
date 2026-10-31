-- 比賽模式：全場（兩個籃框各對應一隊）／半場（兩隊投同一個籃框）
-- 半場時 App 只知道「進球了」不知道是哪隊：自動進球先記為待確認（pending），
-- 由計分板選隊伍後才計分。自動進球分數：全場 2 分、半場 1 分（3x3 弧內）。

-- ---------- games ----------

alter table public.games
  add column mode text not null default 'full' check (mode in ('full', 'half'));

-- ---------- score_events ----------

alter table public.score_events
  alter column team drop not null,
  add column pending boolean not null default false;

-- 待確認的事件沒有隊伍；確認後一定有隊伍
alter table public.score_events
  add constraint score_events_pending_team check (pending = (team is null));

-- ---------- 自動進球：依模式決定隊伍與分數 ----------

create or replace function public.score_events_fill_team()
returns trigger
language plpgsql
as $$
declare
  v_mode    text;
  v_swapped boolean;
begin
  if new.source = 'auto' then
    select mode, sides_swapped into v_mode, v_swapped from public.games where id = new.game_id;

    if new.points is null then
      new.points := case when v_mode = 'half' then 1 else 2 end;
    end if;

    if new.team is null and new.hoop is not null then
      if v_mode = 'half' then
        new.pending := true;
      else
        new.team := case
          when (new.hoop = 1) <> coalesce(v_swapped, false) then 'A'
          else 'B'
        end;
      end if;
    end if;
  end if;
  return new;
end;
$$;

-- ---------- 撤銷：只撤銷已計分的事件，待確認的由計分板處理 ----------

create or replace function public.undo_last(p_game_id uuid)
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
      where game_id = p_game_id and not undone and not pending
      order by id desc
      limit 1
      for update skip locked
   )
  returning * into e;

  return e;
end;
$$;

-- ---------- 開新局：加上模式 ----------

drop function public.new_game(text, text);

create function public.new_game(
  p_team_a_name text default '主隊',
  p_team_b_name text default '客隊',
  p_mode        text default 'full'
) returns public.games
language plpgsql
as $$
declare
  g public.games;
begin
  update public.games
     set status = 'ended', ended_at = now()
   where status = 'live';

  insert into public.games (team_a_name, team_b_name, mode)
  values (p_team_a_name, p_team_b_name, p_mode)
  returning * into g;

  return g;
end;
$$;

grant execute on function public.new_game(text, text, text) to anon, authenticated;
