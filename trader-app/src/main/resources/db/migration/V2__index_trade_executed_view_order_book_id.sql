-- GET /query/executed-trades/{orderBookId} filters trade_executed_view by order_book_id, which had no index, so every
-- call scanned the whole append-only table. Same index as @Table(indexes) on TradeExecutedView (local ddl-auto=update).
-- Conditional because a database Hibernate already updated (local profile) and then baselined at V1 already has it;
-- MySQL 5.7 has no CREATE INDEX IF NOT EXISTS.
SET @idx_exists := (SELECT COUNT(*) FROM information_schema.statistics
                    WHERE table_schema = DATABASE() AND table_name = 'trade_executed_view'
                      AND index_name = 'idx_trade_executed_view_order_book_id');
SET @ddl := IF(@idx_exists = 0,
               'CREATE INDEX `idx_trade_executed_view_order_book_id` ON `trade_executed_view` (`order_book_id`)',
               'DO 0');
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
