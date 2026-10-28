ALTER TABLE driver_queue_states
    ADD COLUMN district_object_id INTEGER,
    ADD COLUMN district_entered_at TIMESTAMPTZ,
    ADD COLUMN district_last_observed_at TIMESTAMPTZ,
    ADD COLUMN gps_fix_at TIMESTAMPTZ,
    ADD COLUMN pending_district_object_id INTEGER,
    ADD COLUMN pending_district_since TIMESTAMPTZ,
    ADD COLUMN pending_district_last_seen_at TIMESTAMPTZ,
    ADD COLUMN pending_district_observations INTEGER NOT NULL DEFAULT 0;

ALTER TABLE driver_queue_states
    ADD CONSTRAINT driver_queue_states_district_membership_check
        CHECK (
            (district_object_id IS NULL AND district_entered_at IS NULL)
            OR
            (
                district_object_id IS NOT NULL
                AND district_object_id > 0
                AND district_entered_at IS NOT NULL
            )
        ),
    ADD CONSTRAINT driver_queue_states_pending_district_check
        CHECK (
            (
                pending_district_object_id IS NULL
                AND pending_district_since IS NULL
                AND pending_district_last_seen_at IS NULL
                AND pending_district_observations = 0
            )
            OR
            (
                pending_district_object_id IS NOT NULL
                AND
                pending_district_object_id > 0
                AND pending_district_object_id IS DISTINCT FROM district_object_id
                AND pending_district_since IS NOT NULL
                AND pending_district_last_seen_at IS NOT NULL
                AND pending_district_last_seen_at >= pending_district_since
                AND pending_district_observations > 0
            )
        ),
    ADD CONSTRAINT driver_queue_states_district_observation_order_check
        CHECK (
            (
                district_object_id IS NULL
                OR district_last_observed_at IS NOT NULL
            )
            AND
            (
                pending_district_object_id IS NULL
                OR (
                    district_last_observed_at IS NOT NULL
                    AND pending_district_last_seen_at IS NOT NULL
                    AND pending_district_last_seen_at <=
                        district_last_observed_at
                )
            )
        );

CREATE INDEX driver_queue_states_district_fifo_idx
    ON driver_queue_states (
        district_object_id,
        (GREATEST(district_entered_at, queue_priority_since)),
        shift_id
    )
    WHERE district_object_id IS NOT NULL;
