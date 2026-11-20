-- GET /query/executed-trades/{orderBookId} filters trade_executed_view by order_book_id, which had no index, so every
-- call scanned the whole append-only table. Same index as @Table(indexes) on TradeExecutedView (local ddl-auto=update).
CREATE INDEX `idx_trade_executed_view_order_book_id` ON `trade_executed_view` (`order_book_id`);
