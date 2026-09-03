-- =============================================================================
-- Petrio — fuel station management platform
-- Initial schema: Appwrite -> Supabase (Postgres)
--
-- Conventions
--   money   : bigint, whole Rwandan Francs. Never float.
--   volume  : numeric(12,3) litres
--   meter   : numeric(12,3)
--   tenancy : company_id denormalized onto every tenant table so RLS is a
--             single predicate rather than a join chain.
--   derived : anything computable from other rows is a view, not a column.
-- =============================================================================

create extension if not exists "pgcrypto";
create extension if not exists "citext";
create extension if not exists "btree_gist";


-- =============================================================================
-- 1. ENUMS
-- =============================================================================

create type app_role            as enum ('owner', 'manager', 'pompiste');
create type fuel_type           as enum ('pms', 'ago');
create type shift_slot          as enum ('morning', 'afternoon', 'evening', 'night');
create type shift_status        as enum ('open', 'submitted', 'approved', 'rejected');
create type payment_kind        as enum ('bank_card', 'fuel_card', 'bon');
create type stock_movement_kind as enum ('delivery', 'sale', 'adjustment');
create type situation_status    as enum ('draft', 'approved', 'corrected');
create type settlement_method   as enum ('cash', 'momo', 'bank_transfer', 'bank_card', 'other');


-- =============================================================================
-- 2. SHARED TRIGGER FUNCTIONS
-- =============================================================================

create or replace function set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;


-- =============================================================================
-- 3. TENANCY
-- =============================================================================

create table companies (
  id          uuid primary key default gen_random_uuid(),
  name        text        not null,
  owner_id    uuid        not null references auth.users(id) on delete restrict,
  archived    boolean     not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index companies_owner_idx on companies (owner_id);

create trigger companies_set_updated_at
  before update on companies
  for each row execute function set_updated_at();


create table stations (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid          not null references companies(id) on delete restrict,
  name             text          not null,
  address          text,
  momo_fee_percent numeric(6,4)  not null default 0
                     check (momo_fee_percent >= 0 and momo_fee_percent <= 100),
  archived         boolean       not null default false,
  created_at       timestamptz   not null default now(),
  updated_at       timestamptz   not null default now(),
  unique (company_id, name)
);

create index stations_company_idx on stations (company_id);

create trigger stations_set_updated_at
  before update on stations
  for each row execute function set_updated_at();


-- profiles.id == auth.users.id
-- role / company_id / station_id are ALSO mirrored into JWT app_metadata,
-- which is what the RLS helpers read. app_metadata is server-controlled;
-- user_metadata is user-writable and is never a security boundary.
create table profiles (
  id                   uuid primary key references auth.users(id) on delete cascade,
  company_id           uuid        references companies(id) on delete restrict,
  station_id           uuid        references stations(id)  on delete restrict,
  role                 app_role    not null default 'pompiste',
  name                 text        not null,
  email                citext      not null unique,
  active               boolean     not null default true,
  must_change_password boolean     not null default true,
  created_by           uuid        references auth.users(id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  -- owners are company-wide; managers and pompistes are station-scoped
  constraint profiles_station_scope_ck
    check (role = 'owner' or station_id is not null)
);

create index profiles_company_idx on profiles (company_id);
create index profiles_station_idx on profiles (station_id);
create index profiles_role_idx    on profiles (role);

create trigger profiles_set_updated_at
  before update on profiles
  for each row execute function set_updated_at();


-- Auto-create a profile row when a Supabase auth user is created.
-- Reads seed values out of raw_app_meta_data (server-controlled).
-- A user created without a station in app_metadata is provisioned as an
-- unassigned 'owner' rather than a station-less pompiste, which would
-- violate profiles_station_scope_ck. Managers and pompistes must be created
-- with company_id and station_id already set in app_metadata.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid := nullif(new.raw_app_meta_data ->> 'company_id', '')::uuid;
  v_station uuid := nullif(new.raw_app_meta_data ->> 'station_id', '')::uuid;
  v_role    app_role;
begin
  v_role := coalesce(nullif(new.raw_app_meta_data ->> 'role', ''), 'pompiste')::app_role;

  if v_role <> 'owner' and v_station is null then
    v_role := 'owner';
  end if;

  insert into profiles (id, company_id, station_id, role, name, email)
  values (
    new.id,
    v_company,
    v_station,
    v_role,
    coalesce(nullif(new.raw_user_meta_data ->> 'name', ''), split_part(new.email, '@', 1)),
    new.email
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();


-- =============================================================================
-- 4. EQUIPMENT
-- =============================================================================

create table tanks (
  id                        uuid primary key default gen_random_uuid(),
  company_id                uuid          not null references companies(id) on delete restrict,
  station_id                uuid          not null references stations(id)  on delete restrict,
  label                     text          not null,
  fuel_type                 fuel_type     not null,
  capacity_litres           numeric(12,3) check (capacity_litres > 0),
  low_threshold_litres      numeric(12,3) check (low_threshold_litres >= 0),
  critical_threshold_litres numeric(12,3) check (critical_threshold_litres >= 0),
  active                    boolean       not null default true,
  created_at                timestamptz   not null default now(),
  unique (station_id, label),
  -- referenced as a composite FK target by nozzles, to pin fuel_type
  unique (id, fuel_type),
  constraint tanks_threshold_order_ck
    check (
      low_threshold_litres is null
      or critical_threshold_litres is null
      or critical_threshold_litres <= low_threshold_litres
    )
);

create index tanks_station_idx on tanks (station_id);


create table pumps (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid        not null references companies(id) on delete restrict,
  station_id uuid        not null references stations(id)  on delete restrict,
  label      text        not null,
  active     boolean     not null default true,
  created_at timestamptz not null default now(),
  unique (station_id, label)
);

create index pumps_station_idx on pumps (station_id);


-- Dynamic nozzle count. Adding a nozzle is an INSERT, not a migration.
-- Replaces the hardcoded pms1..pms4 / ago1..ago4 columns.
create table nozzles (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid        not null references companies(id) on delete restrict,
  station_id uuid        not null references stations(id)  on delete restrict,
  pump_id    uuid        not null references pumps(id)     on delete restrict,
  tank_id    uuid        not null,
  fuel_type  fuel_type   not null,
  label      text        not null,
  active     boolean     not null default true,
  created_at timestamptz not null default now(),
  unique (pump_id, label),
  -- a nozzle can only draw from a tank holding the same fuel type
  foreign key (tank_id, fuel_type) references tanks (id, fuel_type) on delete restrict
);

create index nozzles_station_idx on nozzles (station_id);
create index nozzles_pump_idx    on nozzles (pump_id);
create index nozzles_tank_idx    on nozzles (tank_id);


-- Historical shifts resolve the price effective on their log_date,
-- not whatever the price happens to be today.
create table fuel_prices (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid        not null references companies(id) on delete restrict,
  station_id     uuid        not null references stations(id)  on delete restrict,
  fuel_type      fuel_type   not null,
  price          bigint      not null check (price > 0),
  effective_from date        not null,
  effective_to   date,
  created_by     uuid        references profiles(id) on delete set null,
  created_at     timestamptz not null default now(),
  constraint fuel_prices_range_ck
    check (effective_to is null or effective_to >= effective_from),
  -- no two overlapping price periods for the same station + fuel type
  constraint fuel_prices_no_overlap
    exclude using gist (
      station_id with =,
      fuel_type  with =,
      daterange(effective_from, effective_to, '[]') with &&
    )
);

create index fuel_prices_lookup_idx
  on fuel_prices (station_id, fuel_type, effective_from desc);


create table devices (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid        not null references companies(id) on delete restrict,
  station_id         uuid        not null references stations(id)  on delete restrict,
  device_fingerprint text        not null,
  label              text,
  assigned_to        uuid        references profiles(id) on delete set null,
  active             boolean     not null default true,
  last_seen_at       timestamptz,
  created_at         timestamptz not null default now(),
  unique (station_id, device_fingerprint)
);

create index devices_station_idx on devices (station_id);


create table customers (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid        not null references companies(id) on delete restrict,
  name         text        not null,
  plate        text,
  phone        text,
  credit_limit bigint      check (credit_limit >= 0),
  active       boolean     not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (company_id, name)
);

create index customers_company_idx on customers (company_id);
create index customers_plate_idx   on customers (company_id, plate);

create trigger customers_set_updated_at
  before update on customers
  for each row execute function set_updated_at();


-- =============================================================================
-- 5. SHIFTS  — the spine of the model
--
-- One row per pompiste per slot. Replaces shiftKey and the implicit
-- logDate + email join that previously linked index / payments / stock.
-- =============================================================================

create table shifts (
  id               uuid primary key default gen_random_uuid(),
  company_id       uuid         not null references companies(id) on delete restrict,
  station_id       uuid         not null references stations(id)  on delete restrict,
  log_date         date         not null,
  shift            shift_slot   not null,
  pompiste_id      uuid         not null references profiles(id)  on delete restrict,
  label            text,
  status           shift_status not null default 'open',
  start_time       timestamptz,
  end_time         timestamptz,
  device_id        uuid         references devices(id) on delete set null,
  submitted_at     timestamptz,
  approved_by      uuid         references profiles(id) on delete set null,
  approved_at      timestamptz,
  rejection_reason text,
  created_at       timestamptz  not null default now(),
  updated_at       timestamptz  not null default now(),

  unique (station_id, log_date, shift, pompiste_id),
  constraint shifts_time_order_ck
    check (end_time is null or start_time is null or end_time >= start_time),
  constraint shifts_approved_by_ck
    check (status <> 'approved' or approved_by is not null),
  constraint shifts_rejected_reason_ck
    check (status <> 'rejected' or nullif(btrim(rejection_reason), '') is not null)
);

create index shifts_station_date_idx  on shifts (station_id, log_date desc);
create index shifts_pompiste_date_idx on shifts (pompiste_id, log_date desc);
create index shifts_open_idx          on shifts (status) where status <> 'approved';

create trigger shifts_set_updated_at
  before update on shifts
  for each row execute function set_updated_at();


-- =============================================================================
-- 6. NOZZLE READINGS  (+ handover reconciliation)
--
-- expected_opening is filled from the previous shift's closing on the same
-- nozzle. opening_reading is what the pompiste actually typed. The variance
-- between them is surfaced at approval time instead of quietly becoming a
-- stock discrepancy weeks later.
-- =============================================================================

create table nozzle_readings (
  id                      uuid primary key default gen_random_uuid(),
  company_id              uuid          not null references companies(id) on delete restrict,
  station_id              uuid          not null references stations(id)  on delete restrict,
  shift_id                uuid          not null references shifts(id)    on delete cascade,
  nozzle_id               uuid          not null references nozzles(id)   on delete restrict,

  expected_opening        numeric(12,3),
  opening_reading         numeric(12,3) not null check (opening_reading >= 0),
  closing_reading         numeric(12,3)          check (closing_reading >= 0),
  opening_variance        numeric(12,3)
                            generated always as (opening_reading - expected_opening) stored,
  opening_override_reason text,

  meter_rollover          boolean       not null default false,
  meter_max               numeric(12,3),

  litres_sold             numeric(12,3)
                            generated always as (closing_reading - opening_reading) stored,

  recorded_by             uuid        references profiles(id) on delete set null,
  device_id               uuid        references devices(id)  on delete set null,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),

  unique (shift_id, nozzle_id),

  -- meters run forward; a rollover is the documented exception
  constraint nozzle_readings_forward_ck
    check (closing_reading is null or meter_rollover or closing_reading >= opening_reading),

  -- any disagreement with the previous shift's closing must be explained
  constraint nozzle_readings_override_reason_ck
    check (
      expected_opening is null
      or opening_reading = expected_opening
      or nullif(btrim(opening_override_reason), '') is not null
    ),

  constraint nozzle_readings_rollover_max_ck
    check (not meter_rollover or meter_max is not null)
);

create index nozzle_readings_shift_idx  on nozzle_readings (shift_id);
create index nozzle_readings_nozzle_idx on nozzle_readings (nozzle_id, created_at desc);
create index nozzle_readings_variance_idx
  on nozzle_readings (station_id, created_at desc)
  where opening_variance is distinct from 0;

create trigger nozzle_readings_set_updated_at
  before update on nozzle_readings
  for each row execute function set_updated_at();


-- Populate expected_opening from the most recent prior closing on this nozzle.
create or replace function fill_expected_opening()
returns trigger
language plpgsql
as $$
declare
  prev numeric(12,3);
begin
  if new.expected_opening is null then
    select nr.closing_reading
      into prev
      from nozzle_readings nr
      join shifts s on s.id = nr.shift_id
     where nr.nozzle_id = new.nozzle_id
       and nr.closing_reading is not null
       and nr.id <> new.id
     order by s.log_date desc, s.start_time desc nulls last, nr.created_at desc
     limit 1;

    new.expected_opening := prev;   -- null on the first ever reading
  end if;
  return new;
end;
$$;

create trigger nozzle_readings_fill_expected_opening
  before insert on nozzle_readings
  for each row execute function fill_expected_opening();


-- Two pompistes on the same slot must not both claim the same nozzle,
-- or the same litres get counted twice in the daily rollup.
create or replace function prevent_duplicate_nozzle_claim()
returns trigger
language plpgsql
as $$
declare
  clash int;
begin
  select count(*)
    into clash
    from nozzle_readings nr
    join shifts other on other.id = nr.shift_id
    join shifts mine  on mine.id  = new.shift_id
   where nr.nozzle_id  = new.nozzle_id
     and nr.id        <> new.id
     and other.id     <> mine.id
     and other.station_id = mine.station_id
     and other.log_date   = mine.log_date
     and other.shift      = mine.shift;

  if clash > 0 then
    raise exception
      'nozzle % is already claimed by another pompiste in this shift slot',
      new.nozzle_id
      using errcode = 'unique_violation';
  end if;
  return new;
end;
$$;

create trigger nozzle_readings_no_duplicate_claim
  before insert or update on nozzle_readings
  for each row execute function prevent_duplicate_nozzle_claim();


-- =============================================================================
-- 7. PAYMENTS
--
-- Only human-entered values are stored. totalCash, totalPayments,
-- gainPayments, totalFiche, totalLoans are all derived in views.
-- =============================================================================

create table payments (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid        not null references companies(id) on delete restrict,
  station_id  uuid        not null references stations(id)  on delete restrict,
  shift_id    uuid        not null references shifts(id)    on delete cascade,
  momo        bigint      not null default 0 check (momo >= 0),
  momo_loss   bigint      not null default 0 check (momo_loss >= 0),
  cash_5000   integer     not null default 0 check (cash_5000 >= 0),
  cash_2000   integer     not null default 0 check (cash_2000 >= 0),
  cash_1000   integer     not null default 0 check (cash_1000 >= 0),
  cash_500    integer     not null default 0 check (cash_500  >= 0),
  recorded_by uuid        references profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (shift_id)
);

create index payments_station_idx on payments (station_id);

create trigger payments_set_updated_at
  before update on payments
  for each row execute function set_updated_at();


-- Replaces payments.listBC / payments.listSFC arrays and the bare `bon` total.
-- Loans and fiche are NOT here: they have their own lifecycle and their own
-- tables, and duplicating them was the original denormalization bug.
create table payment_lines (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid         not null references companies(id) on delete restrict,
  station_id uuid         not null references stations(id)  on delete restrict,
  payment_id uuid         not null references payments(id)  on delete cascade,
  kind       payment_kind not null,
  amount     bigint       not null check (amount > 0),
  reference  text,
  created_at timestamptz  not null default now()
);

create index payment_lines_payment_idx on payment_lines (payment_id, kind);


-- =============================================================================
-- 8. CREDIT — loans and fiche
-- =============================================================================

create table loans (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid        not null references companies(id) on delete restrict,
  station_id   uuid        not null references stations(id)  on delete restrict,
  shift_id     uuid        references shifts(id) on delete set null,
  log_date     date        not null,
  customer_id  uuid        references customers(id) on delete restrict,
  employee_id  uuid        references profiles(id)  on delete restrict,
  plate        text,
  company_name text,
  amount       bigint      not null check (amount > 0),
  created_by   uuid        references profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint loans_party_ck
    check (customer_id is not null or employee_id is not null or plate is not null)
);

create index loans_station_date_idx on loans (station_id, log_date desc);
create index loans_shift_idx        on loans (shift_id);
create index loans_customer_idx     on loans (customer_id);

create trigger loans_set_updated_at
  before update on loans
  for each row execute function set_updated_at();


-- Partial repayment is the normal case, so settlement is a ledger,
-- not a boolean. `settled` becomes outstanding = 0, computed in v_loans_outstanding.
create table loan_settlements (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid              not null references companies(id) on delete restrict,
  station_id  uuid              not null references stations(id)  on delete restrict,
  loan_id     uuid              not null references loans(id)     on delete cascade,
  shift_id    uuid              references shifts(id) on delete set null,
  amount      bigint            not null check (amount > 0),
  method      settlement_method not null default 'cash',
  settled_at  timestamptz       not null default now(),
  recorded_by uuid              references profiles(id) on delete set null,
  note        text
);

create index loan_settlements_loan_idx  on loan_settlements (loan_id);
create index loan_settlements_shift_idx on loan_settlements (shift_id);


-- A settlement may never exceed what remains outstanding on the loan.
create or replace function check_settlement_not_overpaid()
returns trigger
language plpgsql
as $$
declare
  loan_amount bigint;
  already     bigint;
begin
  select amount into loan_amount from loans where id = new.loan_id;

  select coalesce(sum(amount), 0)
    into already
    from loan_settlements
   where loan_id = new.loan_id
     and id <> new.id;

  if already + new.amount > loan_amount then
    raise exception
      'settlement of % exceeds outstanding balance % on loan %',
      new.amount, loan_amount - already, new.loan_id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger loan_settlements_not_overpaid
  before insert or update on loan_settlements
  for each row execute function check_settlement_not_overpaid();


create table fiche (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid        not null references companies(id) on delete restrict,
  station_id   uuid        not null references stations(id)  on delete restrict,
  shift_id     uuid        references shifts(id) on delete set null,
  log_date     date        not null,
  customer_id  uuid        references customers(id) on delete restrict,
  employee_id  uuid        references profiles(id)  on delete restrict,
  plate        text,
  company_name text,
  amount       bigint      not null check (amount > 0),
  created_by   uuid        references profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index fiche_station_date_idx on fiche (station_id, log_date desc);
create index fiche_shift_idx        on fiche (shift_id);

create trigger fiche_set_updated_at
  before update on fiche
  for each row execute function set_updated_at();


-- =============================================================================
-- 9. STOCK
--
-- Append-only ledger. Theoretical stock is the running sum and is never a
-- stored column. Replaces stockPms / stockAgo / stock entirely.
-- =============================================================================

create table stock_movements (
  id                uuid                not null default gen_random_uuid(),
  company_id        uuid                not null references companies(id) on delete restrict,
  station_id        uuid                not null references stations(id)  on delete restrict,
  tank_id           uuid                not null references tanks(id)     on delete restrict,
  shift_id          uuid                references shifts(id) on delete set null,
  kind              stock_movement_kind not null,
  litres            numeric(12,3)       not null check (litres <> 0),
  supplier          text,
  delivery_ref      text,
  delivery_note     text,
  adjustment_reason text,
  recorded_at       timestamptz         not null default now(),
  recorded_by       uuid                references profiles(id) on delete set null,
  primary key (id),

  -- deliveries add, sales subtract, adjustments go either way
  constraint stock_movements_sign_ck
    check (
      (kind = 'delivery' and litres > 0)
      or (kind = 'sale' and litres < 0)
      or kind = 'adjustment'
    ),
  constraint stock_movements_adjustment_reason_ck
    check (kind <> 'adjustment' or nullif(btrim(adjustment_reason), '') is not null)
);

create index stock_movements_tank_idx    on stock_movements (tank_id, recorded_at desc);
create index stock_movements_station_idx on stock_movements (station_id, recorded_at desc);
create index stock_movements_shift_idx   on stock_movements (shift_id);

-- one auto-generated sale movement per shift per tank
create unique index stock_movements_sale_per_reading_idx
  on stock_movements (shift_id, tank_id)
  where kind = 'sale';

-- Exactly one opening balance per tank. Re-running the migration load must
-- not silently double the stock on hand.
create unique index stock_movements_opening_balance_idx
  on stock_movements (tank_id)
  where kind = 'adjustment' and adjustment_reason = 'migration opening balance';


-- Sales draw down stock automatically from metered litres, so the ledger
-- can never silently disagree with the readings.
create or replace function sync_sale_movement()
returns trigger
language plpgsql
as $$
declare
  v_tank_id uuid;
begin
  select tank_id into v_tank_id from nozzles where id = new.nozzle_id;

  delete from stock_movements
   where shift_id = new.shift_id
     and tank_id  = v_tank_id
     and kind     = 'sale';

  if new.closing_reading is not null then
    insert into stock_movements (
      company_id, station_id, tank_id, shift_id, kind, litres,
      delivery_note, recorded_by
    )
    select
      new.company_id, new.station_id, v_tank_id, new.shift_id, 'sale',
      -sum(nr.litres_sold),
      'auto: metered sales',
      new.recorded_by
      from nozzle_readings nr
      join nozzles n on n.id = nr.nozzle_id
     where nr.shift_id = new.shift_id
       and n.tank_id   = v_tank_id
       and nr.litres_sold is not null
    having sum(nr.litres_sold) > 0;
  end if;

  return new;
end;
$$;

create trigger nozzle_readings_sync_stock
  after insert or update of closing_reading on nozzle_readings
  for each row execute function sync_sale_movement();


create table tank_dips (
  id              uuid          primary key default gen_random_uuid(),
  company_id      uuid          not null references companies(id) on delete restrict,
  station_id      uuid          not null references stations(id)  on delete restrict,
  tank_id         uuid          not null references tanks(id)     on delete restrict,
  shift_id        uuid          references shifts(id) on delete set null,
  log_date        date          not null,
  physical_litres numeric(12,3) not null check (physical_litres >= 0),
  recorded_by     uuid          references profiles(id) on delete set null,
  created_at      timestamptz   not null default now(),
  unique (tank_id, log_date, shift_id)
);

create index tank_dips_tank_idx on tank_dips (tank_id, log_date desc);


-- =============================================================================
-- 10. SITUATIONS  — the snapshot tier
--
-- Draft days are read from v_situation_live. On approval the numbers are
-- frozen here and never recomputed. A later price correction cannot silently
-- rewrite a closed day; amending requires an explicit corrected row.
-- =============================================================================

create table situations (
  id                uuid            primary key default gen_random_uuid(),
  company_id        uuid            not null references companies(id) on delete restrict,
  station_id        uuid            not null references stations(id)  on delete restrict,
  log_date          date            not null,
  status            situation_status not null default 'draft',

  pms_price         bigint        not null,
  ago_price         bigint        not null,
  vente_litres_pms  numeric(12,3) not null,
  vente_litres_ago  numeric(12,3) not null,
  total_pms         bigint        not null,
  total_ago         bigint        not null,
  total_vente       bigint        not null,

  momo              bigint        not null,
  momo_loss         bigint        not null,
  bank_card         bigint        not null,
  sp_fuel_card      bigint        not null,
  total_fiche       bigint        not null,
  bon               bigint        not null,
  total_cash        bigint        not null,
  total_loans       bigint        not null,
  total_payments    bigint        not null,
  gain_payments     bigint        not null,

  gain_fuel_pms     numeric(12,3),
  gain_fuel_ago     numeric(12,3),

  approved_by       uuid          references profiles(id) on delete set null,
  approved_at       timestamptz,
  corrects_id       uuid          references situations(id) on delete set null,
  correction_reason text,
  created_at        timestamptz   not null default now(),
  updated_at        timestamptz   not null default now(),

  constraint situations_approved_by_ck
    check (status <> 'approved' or approved_by is not null),
  constraint situations_correction_ck
    check (corrects_id is null or nullif(btrim(correction_reason), '') is not null)
);

-- one live report per station per day; superseded rows are marked 'corrected'
create unique index situations_station_date_idx
  on situations (station_id, log_date)
  where status <> 'corrected';

create trigger situations_set_updated_at
  before update on situations
  for each row execute function set_updated_at();


-- An approved report is immutable. The only permitted transition is
-- approved -> corrected, which is how a correction supersedes it.
create or replace function protect_approved_situation()
returns trigger
language plpgsql
as $$
begin
  if old.status = 'approved' then
    if new.status = 'corrected'
       and new.log_date        is not distinct from old.log_date
       and new.station_id      is not distinct from old.station_id
       and new.total_vente     is not distinct from old.total_vente
       and new.total_payments  is not distinct from old.total_payments then
      return new;
    end if;

    raise exception
      'situation % is approved and immutable; create a correcting row instead',
      old.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger situations_protect_approved
  before update on situations
  for each row execute function protect_approved_situation();


-- =============================================================================
-- 11. AUDIT
-- =============================================================================

create table audit_log (
  id           bigint generated always as identity primary key,
  company_id   uuid,
  station_id   uuid,
  actor_id     uuid        references profiles(id) on delete set null,
  action       text        not null,
  entity_table text        not null,
  entity_id    uuid,
  before       jsonb,
  after        jsonb,
  occurred_at  timestamptz not null default now()
);

create index audit_log_entity_idx  on audit_log (entity_table, entity_id, occurred_at desc);
create index audit_log_company_idx on audit_log (company_id, occurred_at desc);


-- =============================================================================
-- 12. VIEWS  — the live tier
-- =============================================================================

-- Price in effect for a station + fuel type on a given date.
create or replace function price_on(
  p_station_id uuid,
  p_fuel_type  fuel_type,
  p_date       date
)
returns bigint
language sql
stable
as $$
  select fp.price
    from fuel_prices fp
   where fp.station_id = p_station_id
     and fp.fuel_type  = p_fuel_type
     and fp.effective_from <= p_date
     and (fp.effective_to is null or fp.effective_to >= p_date)
   order by fp.effective_from desc, fp.created_at desc, fp.id
   limit 1;
$$;


-- Replaces the `index` and `dailyReports` collections.
create or replace view v_shift_sales as
select
  s.id                as shift_id,
  s.company_id,
  s.station_id,
  s.log_date,
  s.shift,
  s.pompiste_id,
  s.status,
  coalesce(sum(nr.litres_sold) filter (where n.fuel_type = 'pms'), 0)::numeric(12,3)
                      as vente_litres_pms,
  coalesce(sum(nr.litres_sold) filter (where n.fuel_type = 'ago'), 0)::numeric(12,3)
                      as vente_litres_ago,
  price_on(s.station_id, 'pms', s.log_date) as pms_price,
  price_on(s.station_id, 'ago', s.log_date) as ago_price,
  round(coalesce(sum(nr.litres_sold) filter (where n.fuel_type = 'pms'), 0)
        * coalesce(price_on(s.station_id, 'pms', s.log_date), 0))::bigint
                      as total_pms,
  round(coalesce(sum(nr.litres_sold) filter (where n.fuel_type = 'ago'), 0)
        * coalesce(price_on(s.station_id, 'ago', s.log_date), 0))::bigint
                      as total_ago,
  (round(coalesce(sum(nr.litres_sold) filter (where n.fuel_type = 'pms'), 0)
         * coalesce(price_on(s.station_id, 'pms', s.log_date), 0))
   + round(coalesce(sum(nr.litres_sold) filter (where n.fuel_type = 'ago'), 0)
         * coalesce(price_on(s.station_id, 'ago', s.log_date), 0)))::bigint
                      as total_vente
from shifts s
left join nozzle_readings nr on nr.shift_id = s.id
left join nozzles n          on n.id = nr.nozzle_id
group by s.id;


create or replace view v_shift_payments as
select
  s.id       as shift_id,
  s.company_id,
  s.station_id,
  s.log_date,
  s.shift,
  s.pompiste_id,
  coalesce(p.momo, 0)      as momo,
  coalesce(p.momo_loss, 0) as momo_loss,
  round(coalesce(p.momo, 0) * coalesce(st.momo_fee_percent, 0) / 100)::bigint
                           as momo_fee_expected,
  (coalesce(p.momo_loss, 0)
   - round(coalesce(p.momo, 0) * coalesce(st.momo_fee_percent, 0) / 100))::bigint
                           as momo_unexplained_loss,
  (coalesce(p.cash_5000, 0) * 5000
   + coalesce(p.cash_2000, 0) * 2000
   + coalesce(p.cash_1000, 0) * 1000
   + coalesce(p.cash_500,  0) * 500)::bigint
                           as total_cash,
  coalesce(pl.bank_card, 0) as bank_card,
  coalesce(pl.fuel_card, 0) as sp_fuel_card,
  coalesce(pl.bon, 0)       as bon,
  coalesce(lo.total_loans, 0) as total_loans,
  coalesce(fi.total_fiche, 0) as total_fiche,
  (
    (coalesce(p.cash_5000, 0) * 5000
     + coalesce(p.cash_2000, 0) * 2000
     + coalesce(p.cash_1000, 0) * 1000
     + coalesce(p.cash_500,  0) * 500)
    + coalesce(p.momo, 0) - coalesce(p.momo_loss, 0)
    + coalesce(pl.bank_card, 0)
    + coalesce(pl.fuel_card, 0)
    + coalesce(pl.bon, 0)
    + coalesce(lo.total_loans, 0)
    + coalesce(fi.total_fiche, 0)
  )::bigint                as total_payments,
  (
    (coalesce(p.cash_5000, 0) * 5000
     + coalesce(p.cash_2000, 0) * 2000
     + coalesce(p.cash_1000, 0) * 1000
     + coalesce(p.cash_500,  0) * 500)
    + coalesce(p.momo, 0) - coalesce(p.momo_loss, 0)
    + coalesce(pl.bank_card, 0)
    + coalesce(pl.fuel_card, 0)
    + coalesce(pl.bon, 0)
    + coalesce(lo.total_loans, 0)
    + coalesce(fi.total_fiche, 0)
    - coalesce(vs.total_vente, 0)
  )::bigint                as gain_payments
from shifts s
join stations st       on st.id = s.station_id
left join payments p   on p.shift_id = s.id
left join v_shift_sales vs on vs.shift_id = s.id
left join lateral (
  select
    sum(amount) filter (where kind = 'bank_card') as bank_card,
    sum(amount) filter (where kind = 'fuel_card') as fuel_card,
    sum(amount) filter (where kind = 'bon')       as bon
  from payment_lines
  where payment_id = p.id
) pl on true
left join lateral (
  select sum(amount) as total_loans from loans where shift_id = s.id
) lo on true
left join lateral (
  select sum(amount) as total_fiche from fiche where shift_id = s.id
) fi on true;


-- Replaces the theory / physical / gain columns on stockPms and stockAgo.
create or replace view v_tank_stock as
select
  t.id         as tank_id,
  t.company_id,
  t.station_id,
  t.label,
  t.fuel_type,
  t.capacity_litres,
  coalesce(m.theory_litres, 0)::numeric(12,3) as theory_litres,
  d.physical_litres,
  (d.physical_litres - coalesce(m.theory_litres, 0))::numeric(12,3) as gain_fuel,
  d.log_date   as last_dip_date,
  case
    when t.critical_threshold_litres is not null
     and coalesce(m.theory_litres, 0) <= t.critical_threshold_litres then 'critical'
    when t.low_threshold_litres is not null
     and coalesce(m.theory_litres, 0) <= t.low_threshold_litres      then 'low'
    else 'ok'
  end as stock_status
from tanks t
left join lateral (
  select sum(litres) as theory_litres
  from stock_movements
  where tank_id = t.id
) m on true
left join lateral (
  select physical_litres, log_date
  from tank_dips
  where tank_id = t.id
  order by log_date desc, created_at desc
  limit 1
) d on true;


-- What a manager reviews before approving. On approval this is materialized
-- into `situations` and frozen.
create or replace view v_situation_live as
select
  vs.company_id,
  vs.station_id,
  vs.log_date,
  price_on(vs.station_id, 'pms', vs.log_date) as pms_price,
  price_on(vs.station_id, 'ago', vs.log_date) as ago_price,
  sum(vs.vente_litres_pms)::numeric(12,3)     as vente_litres_pms,
  sum(vs.vente_litres_ago)::numeric(12,3)     as vente_litres_ago,
  sum(vs.total_pms)::bigint                   as total_pms,
  sum(vs.total_ago)::bigint                   as total_ago,
  sum(vs.total_vente)::bigint                 as total_vente,
  sum(vp.momo)::bigint                        as momo,
  sum(vp.momo_loss)::bigint                   as momo_loss,
  sum(vp.bank_card)::bigint                   as bank_card,
  sum(vp.sp_fuel_card)::bigint                as sp_fuel_card,
  sum(vp.total_fiche)::bigint                 as total_fiche,
  sum(vp.bon)::bigint                         as bon,
  sum(vp.total_cash)::bigint                  as total_cash,
  sum(vp.total_loans)::bigint                 as total_loans,
  sum(vp.total_payments)::bigint              as total_payments,
  sum(vp.gain_payments)::bigint               as gain_payments,
  count(*)                                    as shift_count,
  count(*) filter (where vs.status = 'approved') as approved_shift_count
from v_shift_sales vs
join v_shift_payments vp on vp.shift_id = vs.shift_id
group by vs.company_id, vs.station_id, vs.log_date;


-- Replaces the `stock` collection.
create or replace view v_stock_monthly as
select
  t.company_id,
  t.station_id,
  t.id        as tank_id,
  t.fuel_type,
  to_char(date_trunc('month', sm.recorded_at), 'YYYY-MM') as month_year,
  sum(sm.litres) filter (where sm.kind = 'delivery')::numeric(12,3)   as received_litres,
  (-sum(sm.litres) filter (where sm.kind = 'sale'))::numeric(12,3)    as sold_litres,
  sum(sm.litres) filter (where sm.kind = 'adjustment')::numeric(12,3) as adjustment_litres
from tanks t
join stock_movements sm on sm.tank_id = t.id
group by t.company_id, t.station_id, t.id, t.fuel_type,
         date_trunc('month', sm.recorded_at);


-- Replaces the `gainPompiste` collection.
create or replace view v_gain_pompiste_monthly as
select
  vp.company_id,
  vp.station_id,
  vp.pompiste_id,
  pr.name  as employee_name,
  pr.email,
  to_char(date_trunc('month', vp.log_date), 'YYYY-MM') as month_year,
  sum(vp.gain_payments)::bigint as gain_payments,
  count(*)                      as shift_count
from v_shift_payments vp
join profiles pr on pr.id = vp.pompiste_id
group by vp.company_id, vp.station_id, vp.pompiste_id, pr.name, pr.email,
         date_trunc('month', vp.log_date);


create or replace view v_loans_outstanding as
select
  l.id       as loan_id,
  l.company_id,
  l.station_id,
  l.log_date,
  l.customer_id,
  l.employee_id,
  l.plate,
  l.company_name,
  l.amount,
  coalesce(s.paid, 0)::bigint          as paid,
  (l.amount - coalesce(s.paid, 0))::bigint as outstanding,
  (l.amount - coalesce(s.paid, 0)) = 0 as settled,
  s.last_settled_at
from loans l
left join lateral (
  select sum(amount) as paid, max(settled_at) as last_settled_at
  from loan_settlements
  where loan_id = l.id
) s on true;


-- =============================================================================
-- 13. RLS
--
-- Claims are read from JWT app_metadata, which is server-controlled.
-- user_metadata is user-writable and is never a security boundary.
--
-- Spring Boot connects as a role subject to RLS and sets
--   set local request.jwt.claims = '<validated claims json>'
-- per request. The service role key is for the migration load only.
-- =============================================================================

create or replace function auth_company_id()
returns uuid
language sql
stable
as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'company_id',
      ''
    ), ''
  )::uuid;
$$;

create or replace function auth_role()
returns app_role
language sql
stable
as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'role',
      ''
    ), ''
  )::app_role;
$$;

create or replace function auth_station_id()
returns uuid
language sql
stable
as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'station_id',
      ''
    ), ''
  )::uuid;
$$;

-- True when the caller may see rows for this station.
create or replace function can_access_station(p_station_id uuid)
returns boolean
language sql
stable
as $$
  select case auth_role()
    when 'owner' then exists (
      select 1 from stations s
      where s.id = p_station_id and s.company_id = auth_company_id()
    )
    else p_station_id = auth_station_id()
  end;
$$;

-- True when the caller may still write to this shift.
create or replace function can_write_shift(p_shift_id uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from shifts s
    where s.id = p_shift_id
      and can_access_station(s.station_id)
      and (
        auth_role() in ('owner', 'manager')
        or (s.pompiste_id = auth.uid() and s.status = 'open')
      )
  );
$$;


alter table companies       enable row level security;
alter table stations        enable row level security;
alter table profiles        enable row level security;
alter table tanks           enable row level security;
alter table pumps           enable row level security;
alter table nozzles         enable row level security;
alter table fuel_prices     enable row level security;
alter table devices         enable row level security;
alter table customers       enable row level security;
alter table shifts          enable row level security;
alter table nozzle_readings enable row level security;
alter table payments        enable row level security;
alter table payment_lines   enable row level security;
alter table loans           enable row level security;
alter table loan_settlements enable row level security;
alter table fiche           enable row level security;
alter table stock_movements enable row level security;
alter table tank_dips       enable row level security;
alter table situations      enable row level security;
alter table audit_log       enable row level security;


-- profiles: a select policy here is mandatory. Without it every role
-- lookup returns null and the whole app silently loses its permissions.
create policy profiles_select_own on profiles
  for select using (id = auth.uid());

create policy profiles_select_company on profiles
  for select using (
    company_id = auth_company_id()
    and (auth_role() = 'owner' or station_id = auth_station_id())
  );

create policy profiles_update_own on profiles
  for update
  using (id = auth.uid())
  with check (id = auth.uid());

create policy profiles_manage_company on profiles
  for all
  using (auth_role() in ('owner', 'manager') and company_id = auth_company_id())
  with check (auth_role() in ('owner', 'manager') and company_id = auth_company_id());


create policy companies_owner on companies
  for select using (id = auth_company_id());

create policy stations_read on stations
  for select using (company_id = auth_company_id());

create policy stations_write on stations
  for all
  using (auth_role() = 'owner' and company_id = auth_company_id())
  with check (auth_role() = 'owner' and company_id = auth_company_id());


-- Reference data: readable within the station, writable by manager/owner.
create policy tanks_read      on tanks       for select using (can_access_station(station_id));
create policy pumps_read      on pumps       for select using (can_access_station(station_id));
create policy nozzles_read    on nozzles     for select using (can_access_station(station_id));
create policy prices_read     on fuel_prices for select using (can_access_station(station_id));
create policy devices_read    on devices     for select using (can_access_station(station_id));
create policy customers_read  on customers   for select using (company_id = auth_company_id());

create policy tanks_write on tanks
  for all
  using (auth_role() in ('owner','manager') and can_access_station(station_id))
  with check (auth_role() in ('owner','manager') and can_access_station(station_id));

create policy pumps_write on pumps
  for all
  using (auth_role() in ('owner','manager') and can_access_station(station_id))
  with check (auth_role() in ('owner','manager') and can_access_station(station_id));

create policy nozzles_write on nozzles
  for all
  using (auth_role() in ('owner','manager') and can_access_station(station_id))
  with check (auth_role() in ('owner','manager') and can_access_station(station_id));

create policy prices_write on fuel_prices
  for all
  using (auth_role() in ('owner','manager') and can_access_station(station_id))
  with check (auth_role() in ('owner','manager') and can_access_station(station_id));

create policy devices_write on devices
  for all
  using (auth_role() in ('owner','manager') and can_access_station(station_id))
  with check (auth_role() in ('owner','manager') and can_access_station(station_id));

create policy customers_write on customers
  for all
  using (auth_role() in ('owner','manager') and company_id = auth_company_id())
  with check (auth_role() in ('owner','manager') and company_id = auth_company_id());


-- Shifts: pompistes see and open their own; managers and owners see all
-- at their scope. Approval columns are guarded by trigger, not policy.
create policy shifts_read on shifts
  for select using (
    can_access_station(station_id)
    and (auth_role() in ('owner','manager') or pompiste_id = auth.uid())
  );

create policy shifts_insert_own on shifts
  for insert with check (
    can_access_station(station_id)
    and (auth_role() in ('owner','manager') or pompiste_id = auth.uid())
  );

create policy shifts_update on shifts
  for update
  using (
    can_access_station(station_id)
    and (
      auth_role() in ('owner','manager')
      or (pompiste_id = auth.uid() and status = 'open')
    )
  )
  with check (can_access_station(station_id));


-- Only manager/owner may move a shift into approved or rejected.
create or replace function guard_shift_approval()
returns trigger
language plpgsql
as $$
begin
  if new.status is distinct from old.status
     and new.status in ('approved', 'rejected')
     and coalesce(auth_role(), 'pompiste') not in ('owner', 'manager') then
    raise exception 'only a manager or owner may approve or reject a shift'
      using errcode = 'insufficient_privilege';
  end if;

  if old.status = 'approved' and new.status = 'approved'
     and coalesce(auth_role(), 'pompiste') = 'pompiste' then
    raise exception 'approved shifts are read-only for pompistes'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

create trigger shifts_guard_approval
  before update on shifts
  for each row execute function guard_shift_approval();


-- Shift-scoped operational data.
create policy readings_read on nozzle_readings
  for select using (can_access_station(station_id));

create policy readings_write on nozzle_readings
  for all
  using (can_write_shift(shift_id))
  with check (can_write_shift(shift_id));

create policy payments_read on payments
  for select using (can_access_station(station_id));

create policy payments_write on payments
  for all
  using (can_write_shift(shift_id))
  with check (can_write_shift(shift_id));

create policy payment_lines_read on payment_lines
  for select using (can_access_station(station_id));

create policy payment_lines_write on payment_lines
  for all
  using (exists (
    select 1 from payments p
    where p.id = payment_lines.payment_id and can_write_shift(p.shift_id)
  ))
  with check (exists (
    select 1 from payments p
    where p.id = payment_lines.payment_id and can_write_shift(p.shift_id)
  ));

create policy loans_read on loans
  for select using (can_access_station(station_id));

create policy loans_write on loans
  for all
  using (
    can_access_station(station_id)
    and (auth_role() in ('owner','manager') or can_write_shift(shift_id))
  )
  with check (
    can_access_station(station_id)
    and (auth_role() in ('owner','manager') or can_write_shift(shift_id))
  );

create policy loan_settlements_read on loan_settlements
  for select using (can_access_station(station_id));

create policy loan_settlements_write on loan_settlements
  for all
  using (auth_role() in ('owner','manager') and can_access_station(station_id))
  with check (auth_role() in ('owner','manager') and can_access_station(station_id));

create policy fiche_read on fiche
  for select using (can_access_station(station_id));

create policy fiche_write on fiche
  for all
  using (
    can_access_station(station_id)
    and (auth_role() in ('owner','manager') or can_write_shift(shift_id))
  )
  with check (
    can_access_station(station_id)
    and (auth_role() in ('owner','manager') or can_write_shift(shift_id))
  );

create policy stock_movements_read on stock_movements
  for select using (can_access_station(station_id));

create policy stock_movements_write on stock_movements
  for all
  using (auth_role() in ('owner','manager') and can_access_station(station_id))
  with check (auth_role() in ('owner','manager') and can_access_station(station_id));

create policy tank_dips_read on tank_dips
  for select using (can_access_station(station_id));

create policy tank_dips_write on tank_dips
  for all
  using (can_access_station(station_id))
  with check (can_access_station(station_id));


-- Daily reports: readable at station scope, writable by manager/owner only.
create policy situations_read on situations
  for select using (can_access_station(station_id));

create policy situations_write on situations
  for all
  using (auth_role() in ('owner','manager') and can_access_station(station_id))
  with check (auth_role() in ('owner','manager') and can_access_station(station_id));


-- Audit log is written by security-definer triggers, never directly.
create policy audit_read on audit_log
  for select using (
    auth_role() in ('owner','manager') and company_id = auth_company_id()
  );


-- =============================================================================
-- 14. VIEW SECURITY
--
-- security_invoker makes views run under the caller's permissions, so the
-- underlying RLS policies apply. Without it a view is a hole in the model.
-- =============================================================================

alter view v_shift_sales            set (security_invoker = on);
alter view v_shift_payments         set (security_invoker = on);
alter view v_tank_stock             set (security_invoker = on);
alter view v_situation_live         set (security_invoker = on);
alter view v_stock_monthly          set (security_invoker = on);
alter view v_gain_pompiste_monthly  set (security_invoker = on);
alter view v_loans_outstanding      set (security_invoker = on);
