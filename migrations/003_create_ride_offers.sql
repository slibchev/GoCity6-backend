CREATE TABLE ride_offers (
    id TEXT PRIMARY KEY,

    ride_id TEXT NOT NULL
        REFERENCES rides(id),

    driver_id TEXT NOT NULL
        REFERENCES drivers(id),

    vehicle_id TEXT NOT NULL
        REFERENCES vehicles(id),

    eta_seconds INTEGER NOT NULL
        CHECK (eta_seconds >= 0),

    distance_meters INTEGER NOT NULL
        CHECK (distance_meters >= 0),

    offered_at TIMESTAMPTZ NOT NULL,

    expires_at TIMESTAMPTZ NOT NULL,

    status TEXT NOT NULL
        CHECK (
            status IN (
                'pending',
                'accepted',
                'rejected',
                'expired'
            )
        ),

    resolved_at TIMESTAMPTZ,

    CHECK (
        expires_at > offered_at
    ),

    CHECK (
        (
            status = 'pending'
            AND resolved_at IS NULL
        )
        OR
        (
            status IN ('accepted', 'rejected')
            AND resolved_at IS NOT NULL
            AND resolved_at < expires_at
        )
        OR
        (
            status = 'expired'
            AND resolved_at IS NOT NULL
            AND resolved_at >= expires_at
        )
    )
);

-- Същата поръчка никога не се предлага повторно
-- на същия шофьор.
CREATE UNIQUE INDEX ride_offers_ride_driver_once_idx
    ON ride_offers (ride_id, driver_id);

-- Една поръчка може да има максимум
-- едно активно предложение в даден момент.
CREATE UNIQUE INDEX ride_offers_one_pending_per_ride_idx
    ON ride_offers (ride_id)
    WHERE status = 'pending';

-- Един шофьор не може да получава две
-- едновременни предложения.
CREATE UNIQUE INDEX ride_offers_one_pending_per_driver_idx
    ON ride_offers (driver_id)
    WHERE status = 'pending';

-- Същата защита и за автомобила.
CREATE UNIQUE INDEX ride_offers_one_pending_per_vehicle_idx
    ON ride_offers (vehicle_id)
    WHERE status = 'pending';

-- История на предложенията за дадена поръчка.
CREATE INDEX ride_offers_ride_offered_at_idx
    ON ride_offers (ride_id, offered_at);

-- История на предложенията към даден шофьор.
CREATE INDEX ride_offers_driver_offered_at_idx
    ON ride_offers (driver_id, offered_at);

-- За бързо намиране на предложения,
-- чиито 15 секунди са изтекли.
CREATE INDEX ride_offers_pending_expires_at_idx
    ON ride_offers (expires_at)
    WHERE status = 'pending';