FROM eclipse-temurin:8-jre
COPY target/discovery-server-0.0.1-SNAPSHOT.jar /app/discovery-server.jar
EXPOSE 8761
ENTRYPOINT ["java", "-jar", "/app/discovery-server.jar"]
