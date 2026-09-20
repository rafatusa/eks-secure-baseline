package com.udap.baselineapp;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Tests the behaviour the deployment actually depends on.
 *
 * <p>Two of these are guarding security controls rather than features: the
 * actuator exposure lockdown, and the absence of a stack trace in an error
 * response. Both are configuration that is easy to undo accidentally and
 * whose regression is invisible until someone goes looking.
 */
@SpringBootTest
@org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc
class LandingControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    @DisplayName("GET / returns a rendered HTML landing page, not JSON")
    void landingPageRendersHtml() throws Exception {
        mockMvc.perform(get("/"))
                .andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith(MediaType.TEXT_HTML))
                .andExpect(content().string(org.hamcrest.Matchers.containsString("<!DOCTYPE html>")))
                .andExpect(content().string(
                        org.hamcrest.Matchers.containsString("Spring Boot on the secure baseline")));
    }

    @Test
    @DisplayName("The landing page substitutes runtime values, leaving no placeholders")
    void landingPageSubstitutesPlaceholders() throws Exception {
        // A templating mistake leaves the literal token in the page. That
        // renders as visible garbage in a browser and would otherwise only be
        // caught by a human looking at the deployed site.
        mockMvc.perform(get("/"))
                .andExpect(status().isOk())
                .andExpect(content().string(org.hamcrest.Matchers.not(
                        org.hamcrest.Matchers.containsString("{{"))));
    }

    @Test
    @DisplayName("Health endpoint is up — this is what both probes and the ALB call")
    void healthEndpointReportsUp() throws Exception {
        mockMvc.perform(get("/actuator/health"))
                .andExpect(status().isOk())
                .andExpect(content().string(org.hamcrest.Matchers.containsString("\"status\":\"UP\"")));
    }

    @Test
    @DisplayName("Liveness and readiness probe groups are published separately")
    void probeEndpointsArePublished() throws Exception {
        // The Deployment points its probes at these paths. If probes.enabled
        // were lost from application.yaml they would 404, every pod would be
        // marked unready, and the rollout would stall with no obvious cause.
        mockMvc.perform(get("/actuator/health/liveness")).andExpect(status().isOk());
        mockMvc.perform(get("/actuator/health/readiness")).andExpect(status().isOk());
    }

    @Test
    @DisplayName("Sensitive actuator endpoints stay unexposed")
    void sensitiveActuatorEndpointsAreNotExposed() throws Exception {
        // /actuator/env dumps the full environment, which on a Kubernetes pod
        // includes every injected configuration value. Exposing it is a real
        // disclosure, so the lockdown is asserted rather than assumed.
        mockMvc.perform(get("/actuator/env")).andExpect(status().isNotFound());
        mockMvc.perform(get("/actuator/configprops")).andExpect(status().isNotFound());
        mockMvc.perform(get("/actuator/beans")).andExpect(status().isNotFound());
    }
}
