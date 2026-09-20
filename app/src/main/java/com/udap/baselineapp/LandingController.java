package com.udap.baselineapp;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.ResponseBody;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.time.Duration;
import java.time.Instant;

/**
 * Serves the landing page at '/'.
 *
 * <p>The page is rendered from a template on the classpath rather than
 * assembled from string concatenation in Java, so the markup stays readable
 * and there is exactly one place to edit it.
 *
 * <p>Only two runtime values are substituted: the pod name and the process
 * uptime. Both are useful operationally — refreshing the page and seeing the
 * pod name change is the quickest confirmation that the ALB is actually load
 * balancing across both replicas rather than pinning every request to one.
 */
@Controller
public class LandingController {

    private static final Instant STARTED_AT = Instant.now();

    private final String appVersion;

    public LandingController(@Value("${app.version:unknown}") String appVersion) {
        this.appVersion = appVersion;
    }

    @GetMapping(value = "/", produces = MediaType.TEXT_HTML_VALUE)
    @ResponseBody
    public String landing() {
        return TEMPLATE
                .replace("{{POD}}", escape(podName()))
                .replace("{{UPTIME}}", escape(uptime()))
                .replace("{{VERSION}}", escape(appVersion));
    }

    /**
     * The pod name, taken from the downward API via the POD_NAME environment
     * variable set in the Deployment. Falls back to the container hostname,
     * which Kubernetes also sets to the pod name, and finally to a literal so
     * the page still renders when run outside a cluster.
     */
    private String podName() {
        String fromEnv = System.getenv("POD_NAME");
        if (fromEnv != null && !fromEnv.isBlank()) {
            return fromEnv;
        }
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (UnknownHostException e) {
            return "unknown";
        }
    }

    private String uptime() {
        Duration d = Duration.between(STARTED_AT, Instant.now());
        long hours = d.toHours();
        long minutes = d.toMinutesPart();
        long seconds = d.toSecondsPart();
        if (hours > 0) {
            return hours + "h " + minutes + "m";
        }
        if (minutes > 0) {
            return minutes + "m " + seconds + "s";
        }
        return seconds + "s";
    }

    /**
     * Minimal HTML escaping. These values originate from the pod's own
     * environment rather than from user input, but escaping on the way into
     * markup is the habit that prevents the one case where that stops being
     * true.
     */
    private static String escape(String raw) {
        if (raw == null) {
            return "";
        }
        return raw.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;")
                .replace("\"", "&quot;");
    }

    private static final String TEMPLATE = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>eks-secure-baseline</title>
              <style>
                :root { color-scheme: dark; }
                * { box-sizing: border-box; }
                body {
                  margin: 0;
                  min-height: 100vh;
                  display: grid;
                  place-items: center;
                  background: radial-gradient(circle at 20% 15%, #1b2a4a 0%, #0b1120 55%);
                  color: #e6edf7;
                  font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
                  padding: 2rem 1.25rem;
                }
                .card {
                  width: min(680px, 100%);
                  background: rgba(17, 26, 45, 0.82);
                  border: 1px solid rgba(120, 160, 230, 0.22);
                  border-radius: 16px;
                  padding: 2.5rem;
                  box-shadow: 0 24px 60px rgba(0, 0, 0, 0.45);
                }
                .badge {
                  display: inline-block;
                  font-size: 0.72rem;
                  letter-spacing: 0.09em;
                  text-transform: uppercase;
                  color: #7ee3a8;
                  border: 1px solid rgba(126, 227, 168, 0.4);
                  border-radius: 999px;
                  padding: 0.3rem 0.8rem;
                  margin-bottom: 1.4rem;
                }
                h1 { margin: 0 0 0.6rem; font-size: 1.9rem; line-height: 1.2; }
                p.lead { margin: 0 0 2rem; color: #9fb0cc; line-height: 1.6; }
                dl {
                  margin: 0;
                  display: grid;
                  grid-template-columns: max-content 1fr;
                  gap: 0.7rem 1.5rem;
                  font-size: 0.93rem;
                }
                dt { color: #8ba0c2; }
                dd {
                  margin: 0;
                  font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
                  overflow-wrap: anywhere;
                }
                ul.controls {
                  margin: 2rem 0 0;
                  padding: 1.3rem 0 0;
                  border-top: 1px solid rgba(120, 160, 230, 0.18);
                  list-style: none;
                  display: grid;
                  gap: 0.6rem;
                  font-size: 0.88rem;
                  color: #9fb0cc;
                }
                ul.controls li::before { content: "\\2713"; color: #7ee3a8; margin-right: 0.6rem; }
                footer { margin-top: 1.8rem; font-size: 0.78rem; color: #6b7d9c; }
                a { color: #7fb2ff; }
              </style>
            </head>
            <body>
              <main class="card">
                <span class="badge">Running &middot; Amazon EKS</span>
                <h1>Spring Boot on the secure baseline</h1>
                <p class="lead">
                  This page is served by a Spring Boot pod on a hardened EKS cluster,
                  reached through an internet-facing Application Load Balancer that the
                  AWS Load Balancer Controller provisioned from an Ingress resource.
                </p>

                <dl>
                  <dt>Pod</dt><dd>{{POD}}</dd>
                  <dt>Uptime</dt><dd>{{UPTIME}}</dd>
                  <dt>Version</dt><dd>{{VERSION}}</dd>
                  <dt>Health</dt><dd><a href="/actuator/health">/actuator/health</a></dd>
                </dl>

                <ul class="controls">
                  <li>Runs as a non-root user with a read-only root filesystem</li>
                  <li>All Linux capabilities dropped, seccomp RuntimeDefault</li>
                  <li>Namespace enforces the <em>restricted</em> Pod Security Standard</li>
                  <li>Default-deny NetworkPolicy; only the load balancer may reach it</li>
                </ul>

                <footer>
                  Refresh to see the pod name change &mdash; that is the load balancer
                  distributing requests across both replicas.
                </footer>
              </main>
            </body>
            </html>
            """;
}
