CREATE TABLE rides (
    id TEXT PRIMARY KEY,

    pickup TEXT NOT NULL,
    destination TEXT NOT NULL,

    passengers INTEGER NOT NULL
        CHECK (passengers > 0),

    has_luggage BOOLEAN NOT NULL DEFAULT FALSE,

    requested_at TIMESTAMPTZ NOT NULL,

    status TEXT NOT NULL
        CHECK (
            status IN (
                'pending',
                'waitingForVehicle',
                'reserved',
                'accepted',
                'driverArriving',
                'inProgress',
                'completed',
                'cancelled'
            )
        ),

    assigned_driver_id TEXT,
    assigned_vehicle_id TEXT,

    currency CHAR(3) NOT NULL DEFAULT 'EUR',

    meter_fare_minor BIGINT
        CHECK (
            meter_fare_minor IS NULL
            OR meter_fare_minor > 0
        ),

    commission_rate_bps INTEGER
        CHECK (
            commission_rate_bps IS NULL
            OR (
                commission_rate_bps >= 0
                AND commission_rate_bps <= 10000
            )
        ),

    commission_amount_minor BIGINT
        CHECK (
            commission_amount_minor IS NULL
            OR commission_amount_minor >= 0
        ),

    completed_by_driver_id TEXT,
    completed_at TIMESTAMPTZ,

    CHECK (
        status <> 'completed'
        OR (
            meter_fare_minor IS NOT NULL
            AND commission_rate_bps IS NOT NULL
            AND commission_amount_minor IS NOT NULL
            AND completed_by_driver_id IS NOT NULL
            AND completed_at IS NOT NULL
        )
    )
);

CREATE INDEX rides_status_idx
    ON rides (status);

CREATE INDEX rides_assigned_driver_id_idx
    ON rides (assigned_driver_id);

CREATE INDEX rides_requested_at_idx
    ON rides (requested_at);
    