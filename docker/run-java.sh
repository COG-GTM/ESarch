#!/bin/sh
set -eu

exec java ${JAVA_OPTS:-} \
  -XX:+UseContainerSupport \
  -XX:MaxRAMPercentage="${JAVA_MAX_RAM_PERCENTAGE:-75.0}" \
  -jar "${APP_JAR}"
