ALTER TABLE driver_queue_states
ADD COLUMN latitude DOUBLE PRECISION,
ADD COLUMN longitude DOUBLE PRECISION,
ADD COLUMN location_updated_at TIMESTAMPTZ;

ALTER TABLE driver_queue_states
ADD CONSTRAINT driver_queue_states_location_complete_check
CHECK (
    (
        latitude IS NULL
        AND longitude IS NULL
        AND location_updated_at IS NULL
    )
    OR
    (
        latitude IS NOT NULL
        AND longitude IS NOT NULL
        AND location_updated_at IS NOT NULL
    )
);

ALTER TABLE driver_queue_states
ADD CONSTRAINT driver_queue_states_latitude_check
CHECK (
    latitude IS NULL
    OR latitude BETWEEN -90 AND 90
);

ALTER TABLE driver_queue_states
ADD CONSTRAINT driver_queue_states_longitude_check
CHECK (
    longitude IS NULL
    OR longitude BETWEEN -180 AND 180
);