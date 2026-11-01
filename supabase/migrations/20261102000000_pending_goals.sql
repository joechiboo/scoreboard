-- 半場自動進球待確認（接在 20261022000000_game_mode.sql 之後）
-- 半場兩隊投同一個籃框，App 只知道「進球了」不知道是哪隊：
-- 自動進球先記為待確認（pending、沒有隊伍），由計分板選隊伍後才計分。
-- 自動進球沒帶分數時由這裡決定：全場 2 分、半場 1 分。

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
