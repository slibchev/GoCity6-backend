CREATE TABLE ride_reservations (
    id TEXT PRIMARY KEY,

    ride_id TEXT NOT NULL
        REFERENCES rides(id),

    driver_id TEXT NOT NULL
        REFERENCES drivers(id),

    vehicle_id TEXT NOT NULL
        REFERENCES vehicles(id),

    shift_id TEXT NOT NULL
        REFERENCES driver_shifts(id),

    reserved_at TIMESTAMPTZ NOT NULL,

    ended_at TIMESTAMPTZ,

    CONSTRAINT ride_reservations_time_order
        CHECK (
            ended_at IS NULL
            OR ended_at >= reserved_at
        )
);


-- Една поръчка може да има максимум една активна резервация.
--
-- Това е последната DB защита при race:
-- driver A и driver B опитват да резервират една и съща ride.
CREATE UNIQUE INDEX ride_reservations_one_active_per_ride_idx
    ON ride_reservations (ride_id)
    WHERE ended_at IS NULL;


-- Един шофьор може да има максимум една активна
-- следваща резервирана поръчка.
--
-- Това реализира правилото:
-- 1 current + 1 reserved.
CREATE UNIQUE INDEX ride_reservations_one_active_per_driver_idx
    ON ride_reservations (driver_id)
    WHERE ended_at IS NULL;


-- Активният vehicle също не трябва да може да бъде
-- свързан с две едновременни reservations.
--
-- Обикновено това следва от active-shift правилата,
-- но този индекс предпазва и от stale/inconsistent state.
CREATE UNIQUE INDEX ride_reservations_one_active_per_vehicle_idx
    ON ride_reservations (vehicle_id)
    WHERE ended_at IS NULL;


CREATE INDEX ride_reservations_driver_history_idx
    ON ride_reservations (
        driver_id,
        reserved_at DESC
    );


CREATE INDEX ride_reservations_ride_history_idx
    ON ride_reservations (
        ride_id,
        reserved_at DESC
    );