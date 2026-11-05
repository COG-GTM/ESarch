FROM maven:3.6.3-jdk-8 AS build

WORKDIR /workspace
COPY docker/maven-settings.xml /root/.m2/settings.xml
COPY . .
RUN mvn -B -s /root/.m2/settings.xml -DskipTests package

FROM eclipse-temurin:8-jre-jammy

ENV APP_JAR=/app/trader-app.jar \
    JAVA_MAX_RAM_PERCENTAGE=75.0

RUN useradd --system --uid 10001 --create-home --home-dir /home/trader trader \
    && mkdir -p /app \
    && chown -R trader:trader /app /home/trader

COPY --from=build --chown=trader:trader /workspace/trader-app/target/trader-app.jar /app/trader-app.jar
COPY --chown=trader:trader docker/run-java.sh /usr/local/bin/run-java

RUN chmod 0755 /usr/local/bin/run-java

USER trader
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/run-java"]
