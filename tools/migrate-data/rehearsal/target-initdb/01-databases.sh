#!/bin/bash
# Same databases and users as modules/backing-services, each user confined to its own database
# (the state infra/k8s/scripts/cloudsql-grants.sh leaves on Cloud SQL).
set -e
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS enginedb;
CREATE DATABASE IF NOT EXISTS appdb;
CREATE USER 'trading-engine'@'%' IDENTIFIED BY '${TRADING_ENGINE_PASSWORD}';
CREATE USER 'trader-app'@'%' IDENTIFIED BY '${TRADER_APP_PASSWORD}';
GRANT ALL PRIVILEGES ON enginedb.* TO 'trading-engine'@'%';
GRANT ALL PRIVILEGES ON appdb.* TO 'trader-app'@'%';
SQL
