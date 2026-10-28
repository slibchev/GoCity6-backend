CREATE TABLE driver_break_requests (
    request_id UUID PRIMARY KEY,
    shift_id TEXT NOT NULL REFERENCES driver_shifts(id),
    break_kind TEXT NOT NULL
        CHECK (break_kind IN ('short', 'long')),
    status TEXT NOT NULL
        CHECK (status IN ('pending', 'active', 'completed', 'cancelled')),
    requested_at TIMESTAMPTZ NOT NULL,
    activated_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    CHECK (
        (status = 'pending' AND activated_at IS NULL AND ended_at IS NULL)
        OR
        (
            status = 'active'
            AND activated_at IS NOT NULL
            AND activated_at >= requested_at
            AND ended_at IS NULL
        )
        OR
        (
            status = 'completed'
            AND activated_at IS NOT NULL
            AND ended_at IS NOT NULL
            AND activated_at >= requested_at
            AND ended_at >= activated_at
        )
        OR
        (
            status = 'cancelled'
            AND activated_at IS NULL
            AND ended_at IS NOT NULL
            AND ended_at >= requested_at
        )
    )
);

CREATE INDEX driver_break_requests_shift_history_idx
    ON driver_break_requests (shift_id, requested_at DESC);

ALTER TABLE driver_queue_states
    ADD COLUMN pending_break_kind TEXT,
    ADD COLUMN pending_break_request_id UUID,
    ADD COLUMN active_break_request_id UUID,
    ADD CONSTRAINT driver_queue_states_pending_break_check
        CHECK (
            (
                pending_break_kind IS NULL
                AND pending_break_request_id IS NULL
            )
            OR
            (
                pending_break_kind IN ('short', 'long')
                AND pending_break_kind IS NOT NULL
                AND pending_break_request_id IS NOT NULL
                AND availability = 'busy'
            )
        ),
    ADD CONSTRAINT driver_queue_states_active_break_request_check
        CHECK (
            active_break_request_id IS NULL
            OR availability IN ('shortBreak', 'longBreak')
        ),
    ADD CONSTRAINT driver_queue_states_pending_break_request_fk
        FOREIGN KEY (pending_break_request_id)
        REFERENCES driver_break_requests(request_id),
    ADD CONSTRAINT driver_queue_states_active_break_request_fk
        FOREIGN KEY (active_break_request_id)
        REFERENCES driver_break_requests(request_id);
