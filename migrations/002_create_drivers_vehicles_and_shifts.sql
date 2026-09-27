CREATE TABLE drivers (
    id TEXT PRIMARY KEY,

    username TEXT NOT NULL,
    password_hash TEXT NOT NULL,

    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    phone TEXT NOT NULL,

    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    created_at TIMESTAMPTZ NOT NULL
);

CREATE UNIQUE INDEX drivers_username_lower_idx
    ON drivers (LOWER(username));


CREATE TABLE vehicles (
    id TEXT PRIMARY KEY,

    plate_number TEXT NOT NULL,

    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    created_at TIMESTAMPTZ NOT NULL
);

CREATE UNIQUE INDEX vehicles_plate_number_lower_idx
    ON vehicles (LOWER(plate_number));


CREATE TABLE driver_shifts (
    id TEXT PRIMARY KEY,

    driver_id TEXT NOT NULL
        REFERENCES drivers(id),

    vehicle_id TEXT NOT NULL
        REFERENCES vehicles(id),

    started_at TIMESTAMPTZ NOT NULL,

    ended_at TIMESTAMPTZ,

    protected_breaks_used INTEGER NOT NULL DEFAULT 0
        CHECK (
            protected_breaks_used >= 0
            AND protected_breaks_used <= 3
        ),

    CHECK (
        ended_at IS NULL
        OR ended_at >= started_at
    )
);

CREATE UNIQUE INDEX driver_shifts_one_active_per_driver_idx
    ON driver_shifts (driver_id)
    WHERE ended_at IS NULL;

CREATE UNIQUE INDEX driver_shifts_one_active_per_vehicle_idx
    ON driver_shifts (vehicle_id)
    WHERE ended_at IS NULL;


CREATE TABLE driver_queue_states (
    shift_id TEXT PRIMARY KEY
        REFERENCES driver_shifts(id),

    availability TEXT NOT NULL
        CHECK (
            availability IN (
                'available',
                'shortBreak',
                'longBreak',
                'busy'
            )
        ),

    queue_priority_since TIMESTAMPTZ NOT NULL,

    break_started_at TIMESTAMPTZ,

    has_pending_offer BOOLEAN NOT NULL DEFAULT FALSE,

    CHECK (
        (
            availability IN ('shortBreak', 'longBreak')
            AND break_started_at IS NOT NULL
        )
        OR
        (
            availability IN ('available', 'busy')
            AND break_started_at IS NULL
        )
    )
);

CREATE INDEX driver_queue_states_priority_idx
    ON driver_queue_states (queue_priority_since);

CREATE INDEX driver_queue_states_availability_idx
    ON driver_queue_states (availability);