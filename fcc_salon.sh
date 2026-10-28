#!/usr/bin/env bash
# freeCodeCamp Salon Appointment Scheduler (official v2.0.0)
# Standalone 5-stage runner. Upload into a fresh /workspace/project folder.
# Usage: bash fcc_salon.sh --run
#        bash fcc_salon.sh --status
#        bash fcc_salon.sh --verify
#        bash fcc_salon.sh --restart

set -Eeuo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE="$ROOT/.fcc_salon.progress"
LOG="$ROOT/.fcc_salon.log"
BACKUP="$ROOT/.fcc_salon_backup"
PG_USER=${FCC_SALON_PG_USER:-freecodecamp}
CURRENT=0

say() { printf '%s\n' "$*"; }
fail() { say "ERROR (stage $CURRENT): $*" >&2; say "Log: $LOG" >&2; exit 1; }

usage() {
  say 'Salon Appointment Scheduler - one-command runner for 21 official checks' \
    '  bash fcc_salon.sh --run       # complete the project, or resume after an error' \
    '  bash fcc_salon.sh --status    # show saved checkpoint' \
    '  bash fcc_salon.sh --verify    # rerun official tests' \
    '  bash fcc_salon.sh --restart   # redo stages without deleting database records' \
    '' \
    'Ctrl+C stops safely. Previous salon.sh is backed up before replacing it.' \
    'Existing databases and appointments are never dropped or truncated.'
}

require_environment() {
  command -v psql >/dev/null 2>&1 || fail 'PostgreSQL psql is unavailable. Open/start the CodeRoad tutorial environment.'
  [[ -d "$ROOT/.freeCodeCamp" ]] || fail "Missing .freeCodeCamp in $ROOT. Place the runner in the Salon tutorial's project folder."
  psql -X --username="$PG_USER" --dbname=postgres -qAt \
    --set=ON_ERROR_STOP=1 --command 'SELECT 1' >> "$LOG" 2>&1 ||
    fail "Unable to connect to postgres as $PG_USER. Start CodeRoad/PostgreSQL first."
}

scalar() {
  local db=$1 sql=$2
  psql -X --username="$PG_USER" --dbname="$db" --no-align --tuples-only --quiet \
    --set=ON_ERROR_STOP=1 --command "$sql" 2>> "$LOG"
}

run_sql() {
  local db=$1 sql=$2
  psql -X --username="$PG_USER" --dbname="$db" \
    --set=ON_ERROR_STOP=1 --command "$sql" >> "$LOG" 2>&1 ||
    fail "SQL execution failed for $db. Details in $LOG."
}

stage_database() {
  say '[1/5] Checking salon database...'
  if [[ $(scalar postgres "SELECT COUNT(*) FROM pg_database WHERE datname='salon';") == 0 ]]; then
    run_sql postgres 'CREATE DATABASE salon;'
    say '  Created database salon.'
  else
    say '  Reusing existing salon database.'
  fi
}

stage_schema() {
  say '[2/5] Creating tables, relationships, and salon services...'
  run_sql salon '
CREATE TABLE IF NOT EXISTS customers (
  customer_id SERIAL PRIMARY KEY,
  phone VARCHAR(30) NOT NULL UNIQUE,
  name VARCHAR(80) NOT NULL
);
CREATE TABLE IF NOT EXISTS services (
  service_id SERIAL PRIMARY KEY,
  name VARCHAR(80) NOT NULL
);
CREATE TABLE IF NOT EXISTS appointments (
  appointment_id SERIAL PRIMARY KEY,
  customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
  service_id INTEGER NOT NULL REFERENCES services(service_id),
  time VARCHAR(60) NOT NULL
);
INSERT INTO services (service_id, name) VALUES
  (1, '\''cut'\''),
  (2, '\''color'\''),
  (3, '\''perm'\''),
  (4, '\''style'\''),
  (5, '\''trim'\'')
ON CONFLICT (service_id) DO NOTHING;
SELECT setval(
  pg_get_serial_sequence('\''services'\'', '\''service_id'\''),
  (SELECT MAX(service_id) FROM services), true
);'
  local total
  total=$(scalar salon 'SELECT COUNT(*) FROM services;') || fail 'Cannot inspect the services table.'
  say "  Services available: $total."
  (( total >= 3 )) || fail 'At least three salon services are required.'
}

stage_script() {
  say '[3/5] Creating executable salon.sh...'
  [[ ! -L "$ROOT/salon.sh" ]] || fail 'salon.sh is a symbolic link; refusing to overwrite it.'
  mkdir -p "$BACKUP"
  if [[ -f "$ROOT/salon.sh" && ! -f "$BACKUP/salon.sh.original" ]]; then
    cp -p -- "$ROOT/salon.sh" "$BACKUP/salon.sh.original" || fail 'Unable to back up the current salon.sh.'
    say '  Original salon.sh backed up in .fcc_salon_backup/.'
  fi

  cat > "$ROOT/salon.sh" <<'SALON_SCRIPT'
#! /bin/bash

set -euo pipefail

PSQL="psql --username=freecodecamp --dbname=salon --no-align --tuples-only --set=ON_ERROR_STOP=1 -c"

# Safely quote user-entered values inside PostgreSQL string literals.
sql_quote() {
  local value=$1
  value=${value//\'/\'\'}
  printf '%s' "$value"
}

FIRST_PROMPT=1
while true; do
  SERVICE_MENU=$($PSQL "SELECT service_id || ') ' || name FROM services ORDER BY service_id;")
  if (( FIRST_PROMPT == 1 )); then
    printf '\n~~~~~ MY SALON ~~~~~\n\nWelcome to My Salon, how can I help you?\n\n%s\n' "$SERVICE_MENU"
    FIRST_PROMPT=0
  else
    printf '\nI could not find that service. What would you like today?\n%s\n' "$SERVICE_MENU"
  fi
  read SERVICE_ID_SELECTED || exit 0

  SERVICE_NAME=''
  if [[ "$SERVICE_ID_SELECTED" =~ ^[0-9]+$ ]]; then
    SERVICE_NAME=$($PSQL "SELECT name FROM services WHERE service_id=$SERVICE_ID_SELECTED;")
  fi

  if [[ -n "$SERVICE_NAME" ]]; then
    break
  fi
done

printf '\nWhat\x27s your phone number?\n'
read CUSTOMER_PHONE || exit 0
PHONE_SQL=$(sql_quote "$CUSTOMER_PHONE")
CUSTOMER_ID=$($PSQL "SELECT customer_id FROM customers WHERE phone='$PHONE_SQL';")

if [[ -z "$CUSTOMER_ID" ]]; then
  printf '\nI don\x27t have a record for that phone number, what\x27s your name?\n'
  read CUSTOMER_NAME || exit 0
  NAME_SQL=$(sql_quote "$CUSTOMER_NAME")
  $PSQL "INSERT INTO customers (phone, name) VALUES ('$PHONE_SQL', '$NAME_SQL') ON CONFLICT (phone) DO NOTHING;" >/dev/null
  CUSTOMER_ID=$($PSQL "SELECT customer_id FROM customers WHERE phone='$PHONE_SQL';")
else
  CUSTOMER_NAME=$($PSQL "SELECT name FROM customers WHERE customer_id=$CUSTOMER_ID;")
fi

printf '\nWhat time would you like your %s, %s?\n' "$SERVICE_NAME" "$CUSTOMER_NAME"
read SERVICE_TIME || exit 0
TIME_SQL=$(sql_quote "$SERVICE_TIME")

$PSQL "INSERT INTO appointments (customer_id, service_id, time) VALUES ($CUSTOMER_ID, $SERVICE_ID_SELECTED, '$TIME_SQL');" >/dev/null
printf '\nI have put you down for a %s at %s, %s.\n' "$SERVICE_NAME" "$SERVICE_TIME" "$CUSTOMER_NAME"
SALON_SCRIPT

  chmod +x "$ROOT/salon.sh"
  bash -n "$ROOT/salon.sh" || fail 'Generated salon.sh has a syntax error.'
  if rg -q 'clear' "$ROOT/salon.sh" 2>/dev/null; then
    fail 'Generated script contains a forbidden screen-wiping command.'
  fi
  say '  Salon booking flow and input validation installed.'
}

stage_tests() {
  say '[4/5] Running 21 official freeCodeCamp tests...'
  [[ -f "$ROOT/.freeCodeCamp/test/1.1.test.js" ]] ||
    fail 'Official test file missing. Open the Salon CodeRoad tutorial before --run.'
  if [[ ! -x "$ROOT/.freeCodeCamp/node_modules/.bin/mocha" ]]; then
    say '  Installing missing official test dependencies...'
    (cd "$ROOT/.freeCodeCamp" && npm install --no-audit --no-fund) >> "$LOG" 2>&1 ||
      fail 'Official dependency installation failed.'
  fi
  (cd "$ROOT/.freeCodeCamp" && npm run programmatic-test) >> "$LOG" 2>&1 ||
    fail 'Official tests did not all pass. See .fcc_salon.log, then run --run again.'
  say '  All 21 checks passed.'
}

stage_backup() {
  say '[5/5] Creating salon.sql database backup for project submission...'
  if [[ -f "$ROOT/salon.sql" ]]; then
    say '  Existing salon.sql preserved. Database backup not overwritten.'
  elif command -v pg_dump >/dev/null 2>&1; then
    if pg_dump -cC --inserts --username="$PG_USER" salon > "$ROOT/salon.sql" 2>> "$LOG"; then
      say '  Saved salon.sql (keep it alongside salon.sh).'
    else
      # A failed pg_dump is not part of CodeRoad's 21 test assertions.
      say '  Warning: pg_dump failed; 21 official tests have already passed.'
    fi
  else
    say '  Warning: pg_dump unavailable; 21 official tests have already passed.'
  fi
}

show_status() {
  local saved=0
  [[ -f "$STATE" ]] && read -r saved < "$STATE"
  [[ $saved =~ ^[0-5]$ ]] || saved=0
  say "Salon progress: $saved of 5 stages saved."
  if (( saved == 5 )); then say 'Complete.'; else say 'Resume using: bash fcc_salon.sh --run'; fi
}

run_all() {
  cd -- "$ROOT"
  : >> "$LOG"
  CURRENT=0
  require_environment
  local saved=0 stage
  [[ -f "$STATE" ]] && read -r saved < "$STATE"
  [[ $saved =~ ^[0-5]$ ]] || fail 'Invalid progress checkpoint. Inspect .fcc_salon.progress.'
  if (( saved == 5 )); then
    say 'Already complete (5/5). Use --verify to run the tests again.'
    return
  fi
  for stage in 1 2 3 4 5; do
    (( stage > saved )) || continue
    CURRENT=$stage
    case "$stage" in
      1) stage_database ;;
      2) stage_schema ;;
      3) stage_script ;;
      4) stage_tests ;;
      5) stage_backup ;;
    esac
    printf '%s\n' "$stage" > "$STATE"
    saved=$stage
    say "  ✓ Stage $stage/5 complete."
  done
  say 'DONE! Salon Appointment Scheduler passed all official tests.'
  say 'If CodeRoad has not updated, click Run in the tutorial pane.'
}

case "${1:---run}" in
  --run) run_all ;;
  --status) show_status ;;
  --verify) cd -- "$ROOT"; : >> "$LOG"; CURRENT=4; require_environment; stage_tests ;;
  --restart)
    # Reset only this runner's checkpoint, not user records or tables.
    printf '0\n' > "$STATE"
    run_all
    ;;
  --help|-h) usage ;;
  *) usage; exit 2 ;;
esac
