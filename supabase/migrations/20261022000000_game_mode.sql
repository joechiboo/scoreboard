-- 比賽模式：全場（預設）／半場 3v3 鬥牛
-- full：一支手機對一個籃框，進球依籃框記給隊伍；網頁點一下 +2
-- half：兩隊投同一個籃框，每球 1 分；網頁點一下 +1
-- 開新局時沿用上一場的模式，網頁按鈕可切換目前這場

-- ---------- games.mode ----------

alter table public.games
  add column mode text not null default 'full' check (mode in ('full', 'half'));

-- ---------- 開新局：沿用上一場的模式 ----------

drop function public.new_game(text, text);

create function public.new_game(
  p_team_a_name text default '主隊',
  p_team_b_name text default '客隊',
  p_mode        text default null -- null：沿用目前這場的模式
) returns public.games
language plpgsql
as $$
declare
  g         public.games;
  prev_mode text;
begin
  select mode into prev_mode from public.games where status = 'live' limit 1;

  update public.games
     set status = 'ended', ended_at = now()
   where status = 'live';

  insert into public.games (team_a_name, team_b_name, mode)
  values (p_team_a_name, p_team_b_name, coalesce(p_mode, prev_mode, 'full'))
  returning * into g;

  return g;
end;
$$;

grant execute on function public.new_game(text, text, text) to anon, authenticated;
