ALTER TABLE ride_offers
    ALTER COLUMN eta_seconds DROP NOT NULL,
    ALTER COLUMN distance_meters DROP NOT NULL,
    ADD COLUMN dispatch_district_object_id INTEGER,
    ADD COLUMN dispatch_district_entered_at TIMESTAMPTZ,
    ADD CONSTRAINT ride_offers_route_metrics_pair_check
        CHECK (
            (eta_seconds IS NULL AND distance_meters IS NULL)
            OR (eta_seconds IS NOT NULL AND distance_meters IS NOT NULL)
        ),
    ADD CONSTRAINT ride_offers_dispatch_district_pair_check
        CHECK (
            (
                dispatch_district_object_id IS NULL
                AND dispatch_district_entered_at IS NULL
            )
            OR (
                dispatch_district_object_id IS NOT NULL
                AND dispatch_district_entered_at IS NOT NULL
                AND dispatch_district_object_id > 0
            )
        );

ALTER TABLE driver_queue_states
    ADD COLUMN has_customer_cancellation_priority BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE rides
    ADD COLUMN manual_acceptance_shift_id TEXT
        REFERENCES driver_shifts(id),
    ADD COLUMN manual_acceptance_district_object_id INTEGER,
    ADD COLUMN manual_acceptance_district_entered_at TIMESTAMPTZ,
    ADD COLUMN manual_acceptance_queue_priority_since TIMESTAMPTZ,
    ADD CONSTRAINT rides_manual_acceptance_queue_snapshot_check
        CHECK (
            (
                manual_acceptance_shift_id IS NULL
                AND manual_acceptance_district_object_id IS NULL
                AND manual_acceptance_district_entered_at IS NULL
                AND manual_acceptance_queue_priority_since IS NULL
            )
            OR (
                manual_acceptance_shift_id IS NOT NULL
                AND manual_acceptance_queue_priority_since IS NOT NULL
                AND (
                    (
                        manual_acceptance_district_object_id IS NULL
                        AND manual_acceptance_district_entered_at IS NULL
                    )
                    OR (
                        manual_acceptance_district_object_id IS NOT NULL
                        AND manual_acceptance_district_entered_at IS NOT NULL
                        AND manual_acceptance_district_object_id > 0
                    )
                )
            )
        );
