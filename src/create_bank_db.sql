-- ============================================
-- Создание тестовой БД для банковской сферы
-- PostgreSQL
-- ============================================

-- Удаление таблиц (если существуют)
DROP TABLE IF EXISTS acquiring_transactions CASCADE;
DROP TABLE IF EXISTS terminals CASCADE;
DROP TABLE IF EXISTS merchants CASCADE;
DROP TABLE IF EXISTS transactions CASCADE;
DROP TABLE IF EXISTS cards CASCADE;
DROP TABLE IF EXISTS accounts CASCADE;
DROP TABLE IF EXISTS customers CASCADE;
DROP TABLE IF EXISTS mcc_codes CASCADE;

-- ============================================
-- Справочники
-- ============================================

CREATE TABLE mcc_codes (
    mcc_code TEXT PRIMARY KEY,
    description TEXT NOT NULL,
    category TEXT NOT NULL,
    risk_level TEXT CHECK(risk_level IN ('low', 'medium', 'high')) DEFAULT 'low'
);

-- ============================================
-- Клиенты
-- ============================================

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    customer_type TEXT CHECK(customer_type IN ('individual', 'legal')) NOT NULL,
    name TEXT NOT NULL,
    inn TEXT,
    kpp TEXT,
    registration_date DATE DEFAULT CURRENT_DATE,
    status TEXT CHECK(status IN ('active', 'blocked', 'closed')) DEFAULT 'active',
    phone TEXT,
    email TEXT
);

-- ============================================
-- Счета
-- ============================================

CREATE TABLE accounts (
    account_id SERIAL PRIMARY KEY,
    customer_id INTEGER REFERENCES customers(customer_id) ON DELETE CASCADE,
    account_number TEXT NOT NULL UNIQUE,
    currency TEXT CHECK(currency IN ('RUB', 'USD', 'EUR')) DEFAULT 'RUB',
    account_type TEXT CHECK(account_type IN ('current', 'settlement', 'deposit', 'loan')) NOT NULL,
    balance DECIMAL(15, 2) DEFAULT 0,
    open_date DATE DEFAULT CURRENT_DATE,
    status TEXT CHECK(status IN ('active', 'blocked', 'closed')) DEFAULT 'active'
);

-- ============================================
-- Карты
-- ============================================

CREATE TABLE cards (
    card_id SERIAL PRIMARY KEY,
    customer_id INTEGER REFERENCES customers(customer_id) ON DELETE CASCADE,
    account_id INTEGER REFERENCES accounts(account_id) ON DELETE SET NULL,
    card_number_masked TEXT NOT NULL,
    card_type TEXT CHECK(card_type IN ('debit', 'credit')) NOT NULL,
    payment_system TEXT CHECK(payment_system IN ('VISA', 'MASTERCARD', 'MIR')) NOT NULL,
    expiry_date DATE NOT NULL,
    cvv_hash TEXT,
    status TEXT CHECK(status IN ('active', 'blocked', 'expired', 'cancelled')) DEFAULT 'active',
    issue_date DATE DEFAULT CURRENT_DATE
);

-- ============================================
-- Транзакции по счетам
-- ============================================

CREATE TABLE transactions (
    transaction_id SERIAL PRIMARY KEY,
    account_id INTEGER REFERENCES accounts(account_id) ON DELETE CASCADE,
    amount DECIMAL(15, 2) NOT NULL,
    currency TEXT CHECK(currency IN ('RUB', 'USD', 'EUR')) DEFAULT 'RUB',
    transaction_type TEXT CHECK(transaction_type IN ('debit', 'credit')) NOT NULL,
    counterparty_account TEXT,
    counterparty_name TEXT,
    counterparty_inn TEXT,
    description TEXT,
    transaction_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    mcc_code TEXT REFERENCES mcc_codes(mcc_code),
    status TEXT CHECK(status IN ('pending', 'completed', 'failed', 'reversed')) DEFAULT 'completed',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ============================================
-- Мерчанты (торговые точки)
-- ============================================

CREATE TABLE merchants (
    merchant_id SERIAL PRIMARY KEY,
    customer_id INTEGER REFERENCES customers(customer_id) ON DELETE CASCADE,
    merchant_name TEXT NOT NULL,
    inn TEXT NOT NULL,
    address TEXT,
    category TEXT CHECK(category IN ('retail', 'restaurant', 'online', 'fuel', 'entertainment', 'services', 'other')) NOT NULL,
    status TEXT CHECK(status IN ('active', 'blocked', 'closed')) DEFAULT 'active',
    contract_date DATE DEFAULT CURRENT_DATE,
    commission_rate DECIMAL(5, 4) DEFAULT 0.02
);

-- ============================================
-- Терминалы эквайринга
-- ============================================

CREATE TABLE terminals (
    terminal_id SERIAL PRIMARY KEY,
    merchant_id INTEGER REFERENCES merchants(merchant_id) ON DELETE CASCADE,
    terminal_number TEXT NOT NULL UNIQUE,
    location TEXT,
    install_date DATE DEFAULT CURRENT_DATE,
    status TEXT CHECK(status IN ('active', 'inactive', 'maintenance', 'disabled')) DEFAULT 'active',
    model TEXT,
    serial_number TEXT
);

-- ============================================
-- Эквайринг транзакции
-- ============================================

CREATE TABLE acquiring_transactions (
    acquiring_id SERIAL PRIMARY KEY,
    terminal_id INTEGER REFERENCES terminals(terminal_id) ON DELETE CASCADE,
    card_mask TEXT NOT NULL,
    amount DECIMAL(15, 2) NOT NULL,
    currency TEXT CHECK(currency IN ('RUB', 'USD', 'EUR')) DEFAULT 'RUB',
    transaction_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    mcc_code TEXT REFERENCES mcc_codes(mcc_code),
    auth_code TEXT,
    rrn TEXT,
    status TEXT CHECK(status IN ('approved', 'declined', 'reversed', 'refunded')) DEFAULT 'approved',
    commission_rate DECIMAL(5, 4) DEFAULT 0.02,
    commission_amount DECIMAL(15, 2),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ============================================
-- Индексы для производительности
-- ============================================

CREATE INDEX idx_transactions_account ON transactions(account_id);
CREATE INDEX idx_transactions_date ON transactions(transaction_date);
CREATE INDEX idx_acquiring_terminal ON acquiring_transactions(terminal_id);
CREATE INDEX idx_acquiring_date ON acquiring_transactions(transaction_date);
CREATE INDEX idx_acquiring_mcc ON acquiring_transactions(mcc_code);
CREATE INDEX idx_customers_type ON customers(customer_type);
CREATE INDEX idx_accounts_customer ON accounts(customer_id);

-- ============================================
-- Заполнение справочника MCC-кодов
-- ============================================

INSERT INTO mcc_codes (mcc_code, description, category, risk_level) VALUES
('5411', 'Продуктовые магазины', 'retail', 'low'),
('5541', 'АЗС', 'fuel', 'medium'),
('5812', 'Рестораны', 'restaurant', 'low'),
('5813', 'Бары', 'restaurant', 'low'),
('5912', 'Аптеки', 'services', 'low'),
('5311', 'Универмаги', 'retail', 'low'),
('5732', 'Электроника', 'retail', 'medium'),
('5945', 'Игрушки и игры', 'retail', 'low'),
('6011', 'Банкоматы', 'services', 'medium'),
('6012', 'Финансовые учреждения', 'services', 'high'),
('7995', 'Азартные игры', 'entertainment', 'high'),
('4829', 'Денежные переводы', 'services', 'high'),
('5999', 'Разные розничные товары', 'retail', 'medium'),
('5734', 'ПО и компьютеры', 'retail', 'medium'),
('5814', 'Фастфуд', 'restaurant', 'low'),
('5944', 'Ювелирные магазины', 'retail', 'high'),
('7011', 'Отели', 'services', 'low'),
('7832', 'Кинотеатры', 'entertainment', 'low'),
('7941', 'Спортзалы', 'entertainment', 'low'),
('8011', 'Медицинские услуги', 'services', 'low');

-- ============================================
-- Тестовые данные: Клиенты
-- ============================================

INSERT INTO customers (customer_type, name, inn, kpp, phone, email) VALUES
-- Юридические лица
('legal', 'ООО "Торговый Дом Ромашка"', '7701234567', '770101001', '+7(495)123-45-67', 'info@romashka.ru'),
('legal', 'АО "Банк ФинТех"', '7702345678', '770201001', '+7(495)234-56-78', 'contact@fintech-bank.ru'),
('legal', 'ИП Иванов Петр Сергеевич', '770301234567', NULL, '+7(916)345-67-89', 'ivanov.ps@mail.ru'),
('legal', 'ООО "Сеть Кафе Вкусно"', '7703456789', '770301001', '+7(495)456-78-90', 'info@vkusno-cafe.ru'),
('legal', 'АО "НефтьГазОйл"', '7704567890', '770401001', '+7(495)567-89-01', 'info@neftegaz.ru'),
-- Физические лица
('individual', 'Петров Алексей Владимирович', NULL, NULL, '+7(916)678-90-12', 'petrov.av@gmail.com'),
('individual', 'Сидорова Мария Ивановна', NULL, NULL, '+7(916)789-01-23', 'sidorova.mi@yandex.ru'),
('individual', 'Козлов Дмитрий Андреевич', NULL, NULL, '+7(916)890-12-34', 'kozlov.da@mail.ru'),
('individual', 'Новикова Елена Сергеевна', NULL, NULL, '+7(916)901-23-45', 'novikova.es@gmail.com'),
('individual', 'Морозов Игорь Петрович', NULL, NULL, '+7(916)012-34-56', 'morozov.ip@yandex.ru');

-- ============================================
-- Тестовые данные: Счета
-- ============================================

INSERT INTO accounts (customer_id, account_number, currency, account_type, balance) VALUES
-- Счета юр лиц
(1, '40702810100000000001', 'RUB', 'settlement', 1500000.00),
(1, '40702810100000000002', 'USD', 'settlement', 25000.00),
(2, '40702810200000000003', 'RUB', 'settlement', 5000000.00),
(3, '40702810300000000004', 'RUB', 'settlement', 350000.00),
(4, '40702810400000000005', 'RUB', 'settlement', 890000.00),
(5, '40702810500000000006', 'RUB', 'settlement', 12000000.00),
-- Счета физ лиц
(6, '40817810600000000007', 'RUB', 'current', 150000.00),
(6, '40817810600000000008', 'USD', 'current', 2000.00),
(7, '40817810700000000009', 'RUB', 'current', 75000.00),
(8, '40817810800000000010', 'RUB', 'current', 250000.00),
(9, '40817810900000000011', 'RUB', 'current', 45000.00),
(10, '40817811000000000012', 'RUB', 'current', 180000.00);

-- ============================================
-- Тестовые данные: Карты
-- ============================================

INSERT INTO cards (customer_id, account_id, card_number_masked, card_type, payment_system, expiry_date, status) VALUES
-- Карты физ лиц
(6, 7, '2200********1234', 'debit', 'MIR', '2028-05-31', 'active'),
(6, 8, '4276********5678', 'debit', 'VISA', '2027-08-31', 'active'),
(7, 9, '5536********9012', 'debit', 'MASTERCARD', '2028-01-31', 'active'),
(8, 10, '2200********3456', 'credit', 'MIR', '2027-12-31', 'active'),
(9, 11, '4276********7890', 'debit', 'VISA', '2028-03-31', 'active'),
(10, 12, '5536********2345', 'debit', 'MASTERCARD', '2027-10-31', 'active');

-- ============================================
-- Тестовые данные: Мерчанты
-- ============================================

INSERT INTO merchants (customer_id, merchant_name, inn, address, category, commission_rate) VALUES
(1, 'Магазин "Ромашка" на Ленина', '7701234567', 'г. Москва, ул. Ленина, д. 10', 'retail', 0.018),
(1, 'Магазин "Ромашка" на Мира', '7701234567', 'г. Москва, пр-т Мира, д. 25', 'retail', 0.018),
(3, 'ИП Иванов - точка выдачи', '770301234567', 'г. Москва, ул. Тверская, д. 5', 'retail', 0.02),
(4, 'Кафе "Вкусно" на Арбате', '7703456789', 'г. Москва, ул. Арбат, д. 15', 'restaurant', 0.025),
(4, 'Кафе "Вкусно" в Парке', '7703456789', 'г. Москва, Парк Горького, стр. 3', 'restaurant', 0.025),
(5, 'АЗС "НефтьГаз" №1', '7704567890', 'г. Москва, МКАД, 23 км', 'fuel', 0.015),
(5, 'АЗС "НефтьГаз" №2', '7704567890', 'г. Москва, МКАД, 45 км', 'fuel', 0.015);

-- ============================================
-- Тестовые данные: Терминалы
-- ============================================

INSERT INTO terminals (merchant_id, terminal_number, location, model, serial_number) VALUES
(1, 'TRM001001', 'г. Москва, ул. Ленина, д. 10', 'Ingenico iCT250', 'IG123456'),
(1, 'TRM001002', 'г. Москва, ул. Ленина, д. 10 (касса 2)', 'Ingenico iCT250', 'IG123457'),
(2, 'TRM002001', 'г. Москва, пр-т Мира, д. 25', 'PAX S90', 'PX234567'),
(3, 'TRM003001', 'г. Москва, ул. Тверская, д. 5', 'Verifone V240m', 'VF345678'),
(4, 'TRM004001', 'г. Москва, ул. Арбат, д. 15', 'Ingenico iCT250', 'IG456789'),
(5, 'TRM005001', 'г. Москва, Парк Горького, стр. 3', 'PAX S90', 'PX567890'),
(6, 'TRM006001', 'г. Москва, МКАД, 23 км', 'Verifone V240m', 'VF678901'),
(7, 'TRM007001', 'г. Москва, МКАД, 45 км', 'Ingenico iCT250', 'IG789012');

-- ============================================
-- Тестовые данные: Транзакции по счетам (за последний месяц)
-- ============================================

INSERT INTO transactions (account_id, amount, currency, transaction_type, counterparty_account, counterparty_name, counterparty_inn, description, transaction_date, mcc_code, status) VALUES
-- Поступления на счета юр лиц
(1, 500000.00, 'RUB', 'credit', '40702810500000000006', 'АО "НефтьГазОйл"', '7704567890', 'Оплата по договору поставки №123', '2026-02-15 10:30:00', NULL, 'completed'),
(1, 250000.00, 'RUB', 'credit', '40702810400000000005', 'ООО "Сеть Кафе Вкусно"', '7703456789', 'Оплата аренды', '2026-02-20 14:15:00', NULL, 'completed'),
(3, 1000000.00, 'RUB', 'credit', '40702810100000000001', 'ООО "Торговый Дом Ромашка"', '7701234567', 'Возврат займа', '2026-02-25 09:00:00', NULL, 'completed'),
-- Списание со счетов юр лиц
(1, 150000.00, 'RUB', 'debit', '40702810900000000011', 'Поставщик ООО', '7705678901', 'Оплата товаров', '2026-02-18 11:45:00', NULL, 'completed'),
(1, 50000.00, 'RUB', 'debit', '40817810600000000007', 'Петров А.В.', NULL, 'Зарплата', '2026-02-28 16:00:00', NULL, 'completed'),
(4, 80000.00, 'RUB', 'debit', '40702810200000000003', 'АО "Банк ФинТех"', '7702345678', 'Платеж по кредиту', '2026-03-01 10:00:00', NULL, 'completed'),
-- Транзакции физ лиц
(7, 25000.00, 'RUB', 'debit', NULL, 'Пятерочка', '7701234567', 'Покупка в магазине', '2026-03-05 18:30:00', '5411', 'completed'),
(7, 5000.00, 'RUB', 'debit', NULL, 'Лукойл', '7704567890', 'АЗС', '2026-03-07 12:00:00', '5541', 'completed'),
(7, 3500.00, 'RUB', 'debit', NULL, 'Кафе Вкусно', '7703456789', 'Обед', '2026-03-08 14:30:00', '5812', 'completed'),
(9, 150000.00, 'RUB', 'credit', NULL, 'Зарплата', NULL, 'Зачисление зарплаты', '2026-03-01 09:00:00', NULL, 'completed'),
(9, 45000.00, 'RUB', 'debit', NULL, 'М.Видео', '7706789012', 'Покупка техники', '2026-03-10 16:45:00', '5732', 'completed'),
(9, 12000.00, 'RUB', 'debit', NULL, 'Аптека', '7707890123', 'Лекарства', '2026-03-12 10:15:00', '5912', 'completed'),
(11, 180000.00, 'RUB', 'credit', NULL, 'Зарплата', NULL, 'Зачисление зарплаты', '2026-03-01 09:00:00', NULL, 'completed'),
(11, 8500.00, 'RUB', 'debit', NULL, 'Ресторан', '7703456789', 'Ужин', '2026-03-14 20:00:00', '5812', 'completed'),
(11, 3200.00, 'RUB', 'debit', NULL, 'Кинотеатр', '7708901234', 'Билеты', '2026-03-15 18:30:00', '7832', 'completed'),
(12, 65000.00, 'RUB', 'credit', NULL, 'Зарплата', NULL, 'Зачисление зарплаты', '2026-03-01 09:00:00', NULL, 'completed'),
(12, 22000.00, 'RUB', 'debit', NULL, 'Спортзал', '7709012345', 'Абонемент', '2026-03-05 11:00:00', '7941', 'completed'),
(12, 15000.00, 'RUB', 'debit', NULL, 'Отель', '7700123456', 'Бронирование', '2026-03-18 14:00:00', '7011', 'completed');

-- ============================================
-- Тестовые данные: Эквайринг транзакции
-- ============================================

INSERT INTO acquiring_transactions (terminal_id, card_mask, amount, currency, transaction_date, mcc_code, auth_code, rrn, status, commission_rate, commission_amount) VALUES
-- Терминал 1 (магазин Ромашка на Ленина)
(1, '2200********1234', 2500.00, 'RUB', '2026-03-01 10:15:00', '5411', '123456', '260601001234', 'approved', 0.018, 45.00),
(1, '4276********5678', 1800.50, 'RUB', '2026-03-01 11:30:00', '5411', '123457', '260601001235', 'approved', 0.018, 32.41),
(1, '5536********9012', 3200.00, 'RUB', '2026-03-01 14:45:00', '5411', '123458', '260601001236', 'approved', 0.018, 57.60),
(1, '2200********3456', 950.00, 'RUB', '2026-03-02 09:20:00', '5411', '123459', '260602001237', 'approved', 0.018, 17.10),
(1, '4276********7890', 4500.00, 'RUB', '2026-03-02 16:00:00', '5411', '123460', '260602001238', 'approved', 0.018, 81.00),
-- Терминал 2 (магазин Ромашка на Мира)
(2, '5536********2345', 1250.00, 'RUB', '2026-03-01 12:00:00', '5411', '234567', '260601002234', 'approved', 0.018, 22.50),
(2, '2200********1234', 6700.00, 'RUB', '2026-03-02 15:30:00', '5411', '234568', '260602002235', 'approved', 0.018, 120.60),
-- Терминал 3 (кафе Вкусно на Арбате)
(4, '4276********5678', 2800.00, 'RUB', '2026-03-01 13:00:00', '5812', '345678', '260601004234', 'approved', 0.025, 70.00),
(4, '5536********9012', 1500.00, 'RUB', '2026-03-01 14:30:00', '5812', '345679', '260601004235', 'approved', 0.025, 37.50),
(4, '2200********3456', 4200.00, 'RUB', '2026-03-01 19:00:00', '5812', '345680', '260601004236', 'approved', 0.025, 105.00),
(4, '4276********7890', 3100.00, 'RUB', '2026-03-02 13:15:00', '5812', '345681', '260602004237', 'approved', 0.025, 77.50),
(4, '5536********2345', 1850.00, 'RUB', '2026-03-02 20:30:00', '5812', '345682', '260602004238', 'approved', 0.025, 46.25),
-- Терминал 4 (АЗС НефтьГаз)
(6, '2200********1234', 2000.00, 'RUB', '2026-03-01 08:00:00', '5541', '456789', '260601006234', 'approved', 0.015, 30.00),
(6, '4276********5678', 1500.00, 'RUB', '2026-03-01 17:45:00', '5541', '456790', '260601006235', 'approved', 0.015, 22.50),
(6, '5536********9012', 3000.00, 'RUB', '2026-03-02 07:30:00', '5541', '456791', '260602006236', 'approved', 0.015, 45.00),
(6, '2200********3456', 2500.00, 'RUB', '2026-03-02 18:00:00', '5541', '456792', '260602006237', 'approved', 0.015, 37.50),
-- Терминал 5 (ИП Иванов)
(3, '4276********7890', 5600.00, 'RUB', '2026-03-01 11:00:00', '5311', '567890', '260601003234', 'approved', 0.02, 112.00),
(3, '5536********2345', 12000.00, 'RUB', '2026-03-02 14:00:00', '5311', '567891', '260602003235', 'approved', 0.02, 240.00),
-- Declined транзакции
(1, '4276********5678', 150000.00, 'RUB', '2026-03-02 10:00:00', '5411', NULL, '260602001239', 'declined', 0.018, 0),
(4, '2200********1234', 50000.00, 'RUB', '2026-03-02 15:00:00', '5812', NULL, '260602004239', 'declined', 0.025, 0),
-- Refunded транзакции
(1, '2200********1234', 2500.00, 'RUB', '2026-03-03 11:00:00', '5411', '123461', '260603001240', 'refunded', 0.018, 45.00);

-- ============================================
-- Представления для аналитики
-- ============================================

-- Обороты по мерчантам
CREATE VIEW merchant_turnover AS
SELECT 
    m.merchant_id,
    m.merchant_name,
    m.category,
    COUNT(at.acquiring_id) as transaction_count,
    SUM(at.amount) as total_amount,
    SUM(at.commission_amount) as total_commission,
    AVG(at.amount) as avg_transaction
FROM merchants m
JOIN terminals t ON m.merchant_id = t.merchant_id
JOIN acquiring_transactions at ON t.terminal_id = at.terminal_id
WHERE at.status = 'approved'
GROUP BY m.merchant_id, m.merchant_name, m.category;

-- Активность по картам
CREATE VIEW card_activity AS
SELECT 
    c.card_mask,
    c.mcc_code,
    mc.description as mcc_description,
    mc.category,
    COUNT(*) as transaction_count,
    SUM(c.amount) as total_amount
FROM acquiring_transactions c
LEFT JOIN mcc_codes mc ON c.mcc_code = mc.mcc_code
WHERE c.status = 'approved'
GROUP BY c.card_mask, c.mcc_code, mc.description, mc.category;

-- Дневные обороты
CREATE VIEW daily_turnover AS
SELECT 
    DATE(transaction_date) as transaction_day,
    COUNT(*) as transaction_count,
    SUM(amount) as total_amount,
    SUM(commission_amount) as total_commission
FROM acquiring_transactions
WHERE status = 'approved'
GROUP BY DATE(transaction_date)
ORDER BY transaction_day;

-- ============================================
-- Информация о созданной БД
-- ============================================

COMMENT ON TABLE customers IS 'Клиенты банка (физ и юр лица)';
COMMENT ON TABLE accounts IS 'Банковские счета';
COMMENT ON TABLE cards IS 'Банковские карты';
COMMENT ON TABLE transactions IS 'Транзакции по счетам';
COMMENT ON TABLE merchants IS 'Торговые точки (мерчанты)';
COMMENT ON TABLE terminals IS 'Терминалы эквайринга';
COMMENT ON TABLE acquiring_transactions IS 'Эквайринг транзакции';
COMMENT ON TABLE mcc_codes IS 'Справочник MCC-кодов';
