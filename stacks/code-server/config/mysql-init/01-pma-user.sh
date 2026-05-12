#!/bin/bash
set -euo pipefail

# Runs only on first initialization of MySQL data directory.
# MYSQL_PASSWORD is intentionally sourced from PMA_CONTROLPASS in compose.yaml.

mysql --protocol=socket -uroot -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
	CREATE DATABASE IF NOT EXISTS phpmyadmin;
	CREATE USER IF NOT EXISTS 'pma'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
	GRANT ALL PRIVILEGES ON phpmyadmin.* TO 'pma'@'%';
	FLUSH PRIVILEGES;
EOSQL
