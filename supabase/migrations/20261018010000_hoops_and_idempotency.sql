-- Phase 3 準備：辨識端（App）寫入自動進球
-- 1. client_id：App 自行產生，斷線重送時不會重複計分
-- 2. hoop / confidence：記錄是哪個籃框偵測到、辨識信心度
-- 3. games.sides_swapped：換場對調由 Web 控制，App 只回報籃框，隊伍由資料庫決定

-- ---------- score_events ----------

alter table public.score_events
  add column client_id  uuid not null default gen_random_uuid(),
  add column hoop       smallint check (hoop in (1, 2)),
  add column confidence real check (confidence between 0 and 1);

alter table public.score_events
  add constraint score_events_client_id_key unique (client_id),
  -- 自動進球一定要有籃框
  add constraint score_events_auto_has_hoop check (source = 'manual' or hoop is not null);

-- ---------- games ----------

-- false：1 號籃框 = A 隊、2 號籃框 = B 隊；true：對調
alter table public.games
  add column sides_swapped boolean not null default false;

-- ---------- 依籃框決定隊伍 ----------

-- App 只傳 hoop、不傳 team，由這裡依目前的換場狀態填入隊伍，
-- 避免 App 拿到舊的換場狀態而記錯隊
create function public.score_events_fill_team()
returns trigger
language plpgsql
as $$
declare
  swapped boolean;
begin
  if new.team is null and new.hoop is not null then
    select sides_swapped into swapped from public.games where id = new.game_id;
    new.team := case
      when (new.hoop = 1) <> coalesce(swapped, false) then 'A'
      else 'B'
    end;
  end if;
  return new;
end;
$$;

create trigger score_events_fill_team
  before insert on public.score_events
  for each row execute function public.score_events_fill_team();
