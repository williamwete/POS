# Build context: root repo (butuh folder /db untuk migration)
#   docker build -f backend/Dockerfile -t pos-backend .
FROM eclipse-temurin:21-jdk AS build
WORKDIR /src
COPY db ./db
COPY backend ./backend
WORKDIR /src/backend
RUN ./gradlew --no-daemon bootJar -x test

FROM eclipse-temurin:21-jre
RUN useradd --system --uid 10001 pos
WORKDIR /app
COPY --from=build /src/backend/build/libs/pos-backend.jar app.jar
USER pos
EXPOSE 8080
# Probe untuk orchestrator: /actuator/health/liveness dan /actuator/health/readiness
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
