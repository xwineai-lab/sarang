-- ============================================================
-- 오만시간 · 프랑크푸르트 사랑의 교회 공동기도 — Supabase DB 스키마 백업
-- 파일: schema.sql
-- 추출일: 2026-06-08
-- 프로젝트: sarang (ref: vwcsyilkhfmdyqxavsqz)
--
-- 이 파일 하나로 빈 Supabase 프로젝트에 전체 구조(테이블·RLS·집계 RPC·구역 시드)를
-- 그대로 재구축할 수 있습니다. 라이브 DB에서 직접 추출한 실제 정의입니다.
--
-- ※ 개인정보 보호: 사용자 데이터(profiles, prayer_sessions의 "행")는 포함하지 않습니다.
--   구조(테이블/정책)만 담았습니다. 캠페인·부서·구역 시드만 포함합니다.
--
-- 사용법: Supabase 대시보드 > SQL Editor > New query 에 전체 붙여넣고 Run.
--   "Success. No rows returned" 이 나오면 성공입니다.
-- ============================================================


-- ────────────────────────────────────────────────────────────
-- (선택) 처음부터 다시 만들 때, 기존 객체를 지우려면 아래 주석을 해제하세요.
-- 주의: 데이터가 모두 삭제됩니다. 빈 프로젝트라면 건너뛰어도 됩니다.
-- ────────────────────────────────────────────────────────────
-- drop table if exists prayer_sessions cascade;
-- drop table if exists profiles        cascade;
-- drop table if exists groups          cascade;
-- drop table if exists departments     cascade;
-- drop table if exists campaigns       cascade;


-- ════════════════════════════════════════════════════════════
-- 1) 테이블
-- ════════════════════════════════════════════════════════════

create table if not exists campaigns (
  id          bigint  generated always as identity primary key,
  name        text    not null,
  goal_hours  integer not null default 50000,
  started_at  timestamptz default now(),
  is_active   boolean default true
);

create table if not exists departments (
  id   bigint generated always as identity primary key,
  name text   not null unique
);

create table if not exists groups (
  id      bigint generated always as identity primary key,
  name    text   not null,
  kind    text   not null,                 -- zone(선교지) / village(마을) / class(반)
  dept_id bigint references departments(id) on delete cascade,
  unique (name, dept_id)
);

create table if not exists profiles (
  id           uuid    primary key default auth.uid()
                       references auth.users(id) on delete cascade,
  display_name text,
  is_anonymous boolean default true,
  group_id     bigint  references groups(id),
  created_at   timestamptz default now()
);

create table if not exists prayer_sessions (
  id         bigint  generated always as identity primary key,
  user_id    uuid    not null default auth.uid()
                     references auth.users(id) on delete cascade,
  group_id   bigint  references groups(id),
  minutes    integer not null check (minutes >= 0 and minutes <= 1440),
  started_at timestamptz,
  ended_at   timestamptz default now(),
  created_at timestamptz default now()
);


-- ════════════════════════════════════════════════════════════
-- 2) RLS (Row Level Security) — 개인정보는 본인만, 합계는 RPC로만 공개
-- ════════════════════════════════════════════════════════════

alter table campaigns       enable row level security;
alter table departments     enable row level security;
alter table groups          enable row level security;
alter table profiles        enable row level security;
alter table prayer_sessions enable row level security;

-- 공개 읽기 (집계의 기준이 되는 메타데이터)
create policy "read campaigns"   on campaigns   for select using (true);
create policy "read departments" on departments for select using (true);
create policy "read groups"      on groups      for select using (true);

-- 기도 기록: 본인 것만 등록/조회 (수정·삭제 정책 없음 = 불가)
create policy "insert own session" on prayer_sessions
  for insert with check (auth.uid() = user_id);
create policy "select own session" on prayer_sessions
  for select using (auth.uid() = user_id);

-- 프로필: 본인 것만 등록/조회/수정
create policy "own profile upsert" on profiles
  for insert with check (auth.uid() = id);
create policy "own profile select" on profiles
  for select using (auth.uid() = id);
create policy "own profile update" on profiles
  for update using (auth.uid() = id);


-- ════════════════════════════════════════════════════════════
-- 3) 집계 RPC (SECURITY DEFINER — 개인정보 노출 없이 합계만 제공)
-- ════════════════════════════════════════════════════════════

create or replace function public.get_progress()
  returns json
  language sql
  security definer
  set search_path to 'public'
as $function$
  select json_build_object(
    'goal_hours',  coalesce((select goal_hours from campaigns where is_active limit 1), 50000),
    'total_hours', coalesce((select sum(minutes) from prayer_sessions), 0) / 60.0
  );
$function$;

create or replace function public.group_rankings()
  returns table(group_id bigint, group_name text, dept_name text, hours numeric)
  language sql
  security definer
  set search_path to 'public'
as $function$
  select g.id, g.name, d.name, coalesce(sum(s.minutes),0)/60.0 as hours
  from groups g
  join departments d on d.id = g.dept_id
  left join prayer_sessions s on s.group_id = g.id
  group by g.id, g.name, d.name
  order by hours desc;
$function$;

create or replace function public.dept_totals()
  returns table(dept_name text, hours numeric)
  language sql
  security definer
  set search_path to 'public'
as $function$
  select d.name, coalesce(sum(s.minutes),0)/60.0 as hours
  from departments d
  left join groups g on g.dept_id = d.id
  left join prayer_sessions s on s.group_id = g.id
  group by d.name
  order by hours desc;
$function$;

grant execute on function public.get_progress()  to anon, authenticated;
grant execute on function public.group_rankings() to anon, authenticated;
grant execute on function public.dept_totals()    to anon, authenticated;


-- ════════════════════════════════════════════════════════════
-- 4) 시드 데이터 (캠페인 1 · 부서 3 · 구역 36)
-- ════════════════════════════════════════════════════════════

insert into campaigns (name, goal_hours, is_active)
values ('5만 시간 기도운동', 50000, true);

insert into departments (name) values ('장년부'), ('청년부'), ('청소년부');

-- 장년부 — 선교지 구역 26개 (실제 명칭)
insert into groups (name, kind, dept_id)
select v.name, 'zone', (select id from departments where name = '장년부')
from (values
  ('코소보'),('그리스'),('세네갈'),('독일열방'),('우크라이나'),('영국'),
  ('이스라엘'),('요르단'),('알바니아'),('오픈도어스'),('카메룬'),('케냐'),
  ('태국'),('이집트'),('초록우산'),('루마니아'),('툴루즈'),('프랑크푸르트'),
  ('남아공'),('불가리아'),('리옹'),('밀알'),('쇼니'),('슬로베니아'),
  ('우간다'),('에벤에셀')
) as v(name);

-- 청년부 — 마을 6개  ※ 예시 명칭. 실제 마을 이름으로 교체 권장.
insert into groups (name, kind, dept_id)
select v.name, 'village', (select id from departments where name = '청년부')
from (values
  ('1마을'),('2마을'),('3마을'),('4마을'),('5마을'),('6마을')
) as v(name);

-- 청소년부 — 반 4개  ※ 예시 명칭. 실제 반 이름으로 교체 권장.
insert into groups (name, kind, dept_id)
select v.name, 'class', (select id from departments where name = '청소년부')
from (values
  ('중등 1반'),('중등 2반'),('고등 1반'),('고등 2반')
) as v(name);


-- ════════════════════════════════════════════════════════════
-- 5) SQL로는 복구되지 않는 대시보드 설정 (수동 확인 필요)
--    아래는 Supabase 대시보드에서 직접 켜야 하는 항목입니다 (백업 인수인계 문서 기준).
-- ════════════════════════════════════════════════════════════
-- [Authentication > Providers]
--   - Email           : 사용(ON)
--   - Anonymous       : 사용(ON)   ← 이게 꺼져 있으면 앱이 데모 모드로만 동작
-- [Authentication > URL Configuration]
--   - Site URL        : https://sarang-9dm8.onrender.com
--   - Redirect URLs   : https://sarang-9dm8.onrender.com/**
-- (이메일 "기록 지키기" 정식 운영 시: 커스텀 SMTP(Resend 등) 연결 권장 — 기본 메일은 시간당 2~3통 한도)
--
-- 끝.
