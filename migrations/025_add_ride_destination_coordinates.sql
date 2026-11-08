ALTER TABLE rides
    ADD COLUMN destination_latitude DOUBLE PRECISION,
    ADD COLUMN destination_longitude DOUBLE PRECISION;

ALTER TABLE rides
    ADD CONSTRAINT rides_destination_coordinates_pair_and_range_check
    CHECK (
        (destination_latitude IS NULL AND destination_longitude IS NULL)
        OR (
            destination_latitude IS NOT NULL
            AND destination_longitude IS NOT NULL
            AND destination_latitude BETWEEN -90 AND 90
            AND destination_longitude BETWEEN -180 AND 180
        )
    );
