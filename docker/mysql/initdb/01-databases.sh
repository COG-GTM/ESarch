#!/bin/bash
# One schema per app, matching the two TAS MySQL instances (enginedb for trading-engine, appdb for trader-app).
set -e
mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS enginedb;
CREATE DATABASE IF NOT EXISTS appdb;
GRANT ALL PRIVILEGES ON enginedb.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON appdb.* TO '${MYSQL_USER}'@'%';
FLUSH PRIVILEGES;
SQL
