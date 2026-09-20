# ---------------------------------------------------------------------------
# Build stage — full JDK, discarded from the final image.
#
# Java 21: Spring Boot 3.5.x has a Java 17 baseline and supports 21, so 21
# (the current LTS) is pinned deliberately. This tag, the <release> in
# pom.xml and setup-java in the app-deploy workflow must all agree; a drift
# between them fails either at compile time or with
# UnsupportedClassVersionError at startup.
# ---------------------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-21 AS build

WORKDIR /build

# Dependency resolution is cached as its own layer. pom.xml changes far less
# often than source does, so ordinary code edits reuse the downloaded
# dependencies instead of re-resolving the whole tree on every build.
COPY pom.xml ./
RUN mvn -B -q dependency:go-offline

COPY src ./src
RUN mvn -B -DskipTests package

# The jar name embeds the version from pom.xml. Normalising it here means the
# runtime stage does not have to know the version, so a version bump does not
# silently break the COPY below.
RUN cp target/baseline-app-*.jar /build/app.jar

# ---------------------------------------------------------------------------
# Runtime stage — JRE only. No compiler, no Maven, no build cache.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jre

# Non-root from a fixed UID/GID. A numeric UID matters: Kubernetes
# runAsNonRoot can only verify the user is not root when the image declares a
# numeric USER, and a name-only USER causes the pod to be REJECTED at admission
# under the restricted Pod Security Standard with "container has runAsNonRoot
# and image has non-numeric user".
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app

COPY --from=build --chown=10001:10001 /build/app.jar /app/app.jar

USER 10001:10001

EXPOSE 8080

# Container-aware memory settings. Without MaxRAMPercentage the JVM sizes its
# heap from the host's total memory rather than the cgroup limit, then gets
# OOM-killed by the kernel the moment it grows past the pod's memory limit —
# which surfaces as an unexplained restart loop, not as a Java OOM.
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=70 -XX:InitialRAMPercentage=40 -XX:+UseSerialGC -Djava.security.egd=file:/dev/urandom"

# The root filesystem is mounted read-only by the pod spec, so the JVM's
# temporary directory is redirected to the emptyDir volume mounted at /tmp.
ENV TMPDIR=/tmp

HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD ["/bin/sh", "-c", "exec 3<>/dev/tcp/127.0.0.1/8080 && printf 'GET /actuator/health HTTP/1.0\\r\\n\\r\\n' >&3 && head -n 1 <&3 | grep -q '200'"]

# Exec form: the JVM becomes PID 1 and receives SIGTERM directly. Shell form
# would put /bin/sh at PID 1, which does not forward signals, so graceful
# shutdown never runs and every pod termination takes the full grace period.
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
