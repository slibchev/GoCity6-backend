-- ============================================================
-- RIDES
-- ============================================================

-- Текущ автоматичен dispatch кръг:
-- 1 = нормално търсене
-- 2 = повторно търсене с +5 EUR бонус
ALTER TABLE rides
ADD COLUMN dispatch_round INTEGER NOT NULL DEFAULT 1;

ALTER TABLE rides
ADD CONSTRAINT rides_dispatch_round_check
CHECK (
    dispatch_round IN (1, 2)
);

-- Бонусът е в евроцентове.
-- 500 = 5.00 EUR.
ALTER TABLE rides
ADD COLUMN driver_bonus_minor INTEGER NOT NULL DEFAULT 0;

ALTER TABLE rides
ADD CONSTRAINT rides_driver_bonus_minor_check
CHECK (
    driver_bonus_minor IN (0, 500)
);

-- Решението на клиента за предложената добавка.
--
-- not_offered      = още не сме стигнали до предложението
-- awaiting_customer = чакаме клиента да избере
-- accepted         = клиентът е приел +5 EUR
-- declined         = клиентът предпочита да изчака
ALTER TABLE rides
ADD COLUMN bonus_decision TEXT NOT NULL DEFAULT 'not_offered';

ALTER TABLE rides
ADD CONSTRAINT rides_bonus_decision_check
CHECK (
    bonus_decision IN (
        'not_offered',
        'awaiting_customer',
        'accepted',
        'declined'
    )
);

-- Първият кръг винаги е без бонус.
-- Вторият кръг винаги е с точно +5.00 EUR.
ALTER TABLE rides
ADD CONSTRAINT rides_dispatch_bonus_consistency_check
CHECK (
    (
        dispatch_round = 1
        AND driver_bonus_minor = 0
        AND bonus_decision IN (
            'not_offered',
            'awaiting_customer',
            'declined'
        )
    )
    OR
    (
        dispatch_round = 2
        AND driver_bonus_minor = 500
        AND bonus_decision = 'accepted'
    )
);


-- ============================================================
-- RIDE OFFERS
-- ============================================================

-- Записваме в кой dispatch кръг е създадена конкретната оферта.
ALTER TABLE ride_offers
ADD COLUMN dispatch_round INTEGER NOT NULL DEFAULT 1;

ALTER TABLE ride_offers
ADD CONSTRAINT ride_offers_dispatch_round_check
CHECK (
    dispatch_round IN (1, 2)
);

-- Бонусът, който шофьорът е виждал в конкретната оферта.
ALTER TABLE ride_offers
ADD COLUMN bonus_minor INTEGER NOT NULL DEFAULT 0;

ALTER TABLE ride_offers
ADD CONSTRAINT ride_offers_bonus_minor_check
CHECK (
    bonus_minor IN (0, 500)
);

ALTER TABLE ride_offers
ADD CONSTRAINT ride_offers_dispatch_bonus_consistency_check
CHECK (
    (
        dispatch_round = 1
        AND bonus_minor = 0
    )
    OR
    (
        dispatch_round = 2
        AND bonus_minor = 500
    )
);


-- ============================================================
-- OFFER UNIQUENESS
-- ============================================================

-- Старото правило беше:
--
--   една ride_id може да бъде предложена на driver_id
--   само веднъж завинаги.
--
-- То вече не е правилно, защото при втория кръг
-- същият шофьор трябва да може да получи същата
-- поръчка отново, вече с +5 EUR бонус.
DROP INDEX ride_offers_ride_driver_once_idx;

-- Новото правило е:
--
--   един шофьор може да получи дадена поръчка
--   максимум веднъж ВЪВ ВСЕКИ dispatch кръг.
CREATE UNIQUE INDEX ride_offers_ride_round_driver_once_idx
    ON ride_offers (
        ride_id,
        dispatch_round,
        driver_id
    );