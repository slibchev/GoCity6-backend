ALTER TABLE rides
    ADD COLUMN pickup_latitude DOUBLE PRECISION,
    ADD COLUMN pickup_longitude DOUBLE PRECISION;

ALTER TABLE rides
    ADD CONSTRAINT rides_pickup_coordinates_pair_and_range_check
    CHECK (
        (pickup_latitude IS NULL AND pickup_longitude IS NULL)
        OR (
            pickup_latitude IS NOT NULL
            AND pickup_longitude IS NOT NULL
            AND pickup_latitude BETWEEN -90 AND 90
            AND pickup_longitude BETWEEN -180 AND 180
        )
    );
