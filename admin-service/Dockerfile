# ---- Build stage: compile the Ballerina service into an executable fat JAR ----
FROM ballerina/ballerina:2201.13.6 AS build
USER root
WORKDIR /build
COPY . .
RUN bal build && cp target/bin/*.jar /build/app.jar

# ---- Runtime stage: slim JRE, non-root user ----
FROM eclipse-temurin:21-jre
RUN useradd --system --uid 10001 --home /app app
WORKDIR /app
COPY --from=build /build/app.jar ./app.jar
COPY Config.toml ./Config.toml
USER app
ENV HTTP_PORT=8087     JAVA_OPTS="-XX:+UseSerialGC -Xms48m -Xmx192m -Xss512k -XX:TieredStopAtLevel=1 -XX:ReservedCodeCacheSize=48m"
# 9797 = Prometheus metrics endpoint (ballerinax/prometheus)
EXPOSE 8087 9797
HEALTHCHECK --interval=15s --timeout=5s --start-period=60s --retries=5   CMD bash -c 'exec 3<>/dev/tcp/127.0.0.1/$HTTP_PORT && printf "GET /health HTTP/1.0\r\n\r\n" >&3 && head -1 <&3 | grep -q " 200 "'
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]
