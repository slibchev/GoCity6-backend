-- Allow driver_queue_states to persist the new externalRide state.
--
-- The original CHECK constraints in migration 002 were unnamed,
-- so PostgreSQL generated their names automatically.
-- We locate them by their definitions instead of assuming the names.

DO $$
DECLARE
    constraint_name TEXT;
BEGIN
    SELECT c.conname
    INTO constraint_name
    FROM pg_constraint c
    JOIN pg_class t
        ON t.oid = c.conrelid
    JOIN pg_namespace n
        ON n.oid = t.relnamespace
    WHERE n.nspname = current_schema()
      AND t.relname = 'driver_queue_states'
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%availability%'
      AND pg_get_constraintdef(c.oid) NOT ILIKE '%break_started_at%'
    LIMIT 1;

    IF constraint_name IS NOT NULL THEN
        EXECUTE format(
            'ALTER TABLE driver_queue_states DROP CONSTRAINT %I',
            constraint_name
        );
    END IF;
END
$$;


DO $$
DECLARE
    constraint_name TEXT;
BEGIN
    SELECT c.conname
    INTO constraint_name
    FROM pg_constraint c
    JOIN pg_class t
        ON t.oid = c.conrelid
    JOIN pg_namespace n
        ON n.oid = t.relnamespace
    WHERE n.nspname = current_schema()
      AND t.relname = 'driver_queue_states'
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%availability%'
      AND pg_get_constraintdef(c.oid) ILIKE '%break_started_at%'
    LIMIT 1;

    IF constraint_name IS NOT NULL THEN
        EXECUTE format(
            'ALTER TABLE driver_queue_states DROP CONSTRAINT %I',
            constraint_name
        );
    END IF;
END
$$;


ALTER TABLE driver_queue_states
ADD CONSTRAINT driver_queue_states_availability_check
CHECK (
    availability IN (
        'available',
        'shortBreak',
        'longBreak',
        'busy',
        'externalRide'
    )
);


ALTER TABLE driver_queue_states
ADD CONSTRAINT driver_queue_states_break_state_check
CHECK (
    (
        availability IN ('shortBreak', 'longBreak')
        AND break_started_at IS NOT NULL
    )
    OR
    (
        availability IN (
            'available',
            'busy',
            'externalRide'
        )
        AND break_started_at IS NULL
    )
);


CREATE TABLE external_ride_sessions (
    id TEXT PRIMARY KEY,

    driver_id TEXT NOT NULL
        REFERENCES drivers(id),

    started_at TIMESTAMPTZ NOT NULL,

    ended_at TIMESTAMPTZ,

    distance_meters INTEGER NOT NULL DEFAULT 0,

    trigger_offer_id TEXT
        REFERENCES ride_offers(id),

    trigger_ride_id TEXT
        REFERENCES rides(id),

    CONSTRAINT external_ride_sessions_distance_nonnegative
        CHECK (
            distance_meters >= 0
        ),

    CONSTRAINT external_ride_sessions_time_order
        CHECK (
            ended_at IS NULL
            OR ended_at >= started_at
        ),

    CONSTRAINT external_ride_sessions_trigger_pair
        CHECK (
            (
                trigger_offer_id IS NULL
                AND trigger_ride_id IS NULL
            )
            OR
            (
                trigger_offer_id IS NOT NULL
                AND trigger_ride_id IS NOT NULL
            )
        )
);


CREATE UNIQUE INDEX external_ride_sessions_one_active_per_driver_idx
    ON external_ride_sessions (driver_id)
    WHERE ended_at IS NULL;


CREATE INDEX external_ride_sessions_driver_history_idx
    ON external_ride_sessions (
        driver_id,
        started_at DESC
    );


CREATE INDEX external_ride_sessions_trigger_ride_idx
    ON external_ride_sessions (trigger_ride_id)
    WHERE trigger_ride_id IS NOT NULL;