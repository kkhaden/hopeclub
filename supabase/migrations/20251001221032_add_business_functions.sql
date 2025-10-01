-- Functions for Hope Club business logic
-- Paste into a new migration (e.g. 20251001Txxxxxx_functions.sql)

-- ========== helper: ensure pgcrypto extension exists ==========
create extension if not exists pgcrypto;

-- ========== Indexes (performance) ==========
-- (safe to run even if they already exist)
create index if not exists idx_point_events_student_event_time on point_events (student_id, event_time);
create index if not exists idx_point_events_event_time on point_events (event_time);
create index if not exists idx_redemptions_student_redeemed_at on redemptions (student_id, redeemed_at);
create index if not exists idx_store_items_id_stock on store_items (id, stock);

-- ========== fn_award_points ==========
create or replace function fn_award_points(
  p_student_id uuid,
  p_category_id uuid,
  p_amount int,
  p_note text,
  p_actor uuid -- the acting user (auth.uid()) - optional but recommended
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_min int;
  v_max int;
  v_event_id uuid := gen_random_uuid();
begin
  -- Validate student exists
  perform 1 from students where id = p_student_id;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using (detail := p_student_id::text), sqlstate := 'P0001';
  end if;

  -- Validate category exists and get bounds
  select min_value, max_value into v_min, v_max
  from point_categories where id = p_category_id;

  if not found then
    raise exception 'CATEGORY_NOT_FOUND' using (detail := p_category_id::text), sqlstate := 'P0002';
  end if;

  if p_amount < v_min OR p_amount > v_max then
    raise exception 'AMOUNT_OUT_OF_RANGE' using (detail := format('amount=%s min=%s max=%s', p_amount, v_min, v_max)), sqlstate := 'P0003';
  end if;

  -- Insert point event and audit in one transaction (function is atomic)
  insert into point_events(id, student_id, category_id, delta, note, event_time, created_by, created_at)
  values (v_event_id, p_student_id, p_category_id, p_amount, p_note, now(), p_actor, now());

  insert into audit_logs(id, actor, action, target_id, meta, at)
  values (gen_random_uuid(), p_actor, 'award_points', p_student_id, jsonb_build_object('category_id', p_category_id, 'amount', p_amount, 'note', p_note, 'event_id', v_event_id), now());

  return v_event_id;
end;
$$;


-- ========== fn_student_balance ==========
create or replace function fn_student_balance(p_student_id uuid)
returns integer
language sql
stable
as $$
  select
    coalesce( (select sum(delta) from point_events where student_id = $1), 0 )
    -
    coalesce( (select sum(cost_at_tx) from redemptions where student_id = $1), 0 )
$$;


-- ========== fn_redeem_item ==========
create or replace function fn_redeem_item(
  p_student_id uuid,
  p_item_id uuid,
  p_actor uuid
)
returns uuid
language plpgsql
security invoker
as $$
declare
  v_stock int;
  v_cost int;
  v_redemption_id uuid := gen_random_uuid();
  v_balance int;
begin
  -- Lock the store item row to avoid race conditions
  select stock, cost into v_stock, v_cost
  from store_items
  where id = p_item_id
  for update;

  if not found then
    raise exception 'ITEM_NOT_FOUND' using (detail := p_item_id::text), sqlstate := 'P0101';
  end if;

  if v_stock <= 0 then
    raise exception 'OUT_OF_STOCK' using (detail := p_item_id::text), sqlstate := 'P0102';
  end if;

  -- compute balance using the fn_student_balance function
  v_balance := fn_student_balance(p_student_id);

  if v_balance < v_cost then
    raise exception 'INSUFFICIENT_POINTS' using (detail := format('balance=%s cost=%s', v_balance, v_cost)), sqlstate := 'P0103';
  end if;

  -- decrement stock
  update store_items set stock = stock - 1 where id = p_item_id;

  -- insert redemption record
  insert into redemptions(id, student_id, item_id, cost_at_tx, redeemed_at, created_by)
  values (v_redemption_id, p_student_id, p_item_id, v_cost, now(), p_actor);

  -- audit log
  insert into audit_logs(id, actor, action, target_id, meta, at)
  values (gen_random_uuid(), p_actor, 'redeem_item', p_item_id, jsonb_build_object('student_id', p_student_id, 'cost', v_cost, 'redemption_id', v_redemption_id), now());

  return v_redemption_id;
end;
$$;


-- ========== fn_points_calendar ==========
-- Returns one row per day within the requested date range with sum of deltas for that day
create or replace function fn_points_calendar(
  p_student_id uuid,
  p_start date,
  p_end date
)
returns table(day date, total int)
language sql
stable
as $$
  select d::date as day, coalesce(sum(pe.delta),0)::int as total
  from generate_series(p_start, p_end, interval '1 day') as d
  left join point_events pe
    on pe.student_id = p_student_id and date(pe.event_time) = d::date
  group by d
  order by d
$$;


-- ========== fn_list_recent_activity ==========
-- Returns a combined, ordered feed of recent activity across point_events, redemptions, and incidents
-- Each row is a jsonb with { type, ts, payload }
create or replace function fn_list_recent_activity(p_limit int default 50)
returns setof jsonb
language sql
stable
as $$
  with ev as (
    select jsonb_build_object(
      'type','point_event',
      'ts', event_time,
      'payload', to_jsonb(point_events.*) - 'created_by'
    ) as entry
    from point_events
  ), rd as (
    select jsonb_build_object(
      'type','redemption',
      'ts', redeemed_at,
      'payload', to_jsonb(redemptions.*) - 'created_by'
    ) as entry
    from redemptions
  ), inc as (
    select jsonb_build_object(
      'type','incident',
      'ts', created_at,
      'payload', to_jsonb(incidents.*) - 'created_by'
    ) as entry
    from incidents
  ), all_entries as (
    select entry ->> 'ts' as ts_text, (entry ->> 'ts')::timestamptz as ts, entry from (
      select * from ev
      union all
      select * from rd
      union all
      select * from inc
    ) s
  )
  select entry
  from all_entries
  order by ts desc
  limit p_limit;
$$;
