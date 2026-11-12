package co.zeal.metrics;

import io.micrometer.core.instrument.MeterRegistry;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.testcontainers.containers.GenericContainer;

import static org.assertj.core.api.Assertions.assertThat;

/** Eventos reales (copiados de lo que publican wellbeing y marketplace) → métricas, cada uno una vez. */
@SpringBootTest
class DomainEventMetricsTest {

    @ServiceConnection(name = "redis")
    static final GenericContainer<?> REDIS = new GenericContainer<>("redis:7-alpine").withExposedPorts(6379);

    static {
        REDIS.start();
    }

    @Autowired
    StringRedisTemplate redis;
    @Autowired
    MeterRegistry meters;

    @Test
    void countsBusinessFactsFromExistingEventsExactlyOnce() throws Exception {
        Thread.sleep(500); // suscripción lista
        publish("zeal.notifications", "{\"userId\":\"u\",\"type\":\"RESERVA_CONFIRMADA\",\"title\":\"x\",\"message\":\"Laura\",\"eventId\":\"e-1\"}");
        publish("zeal.notifications", "{\"userId\":\"u\",\"type\":\"RESERVA_CONFIRMADA\",\"title\":\"x\",\"message\":\"Laura\",\"eventId\":\"e-1\"}");
        publish("zeal.notifications", "{\"userId\":\"p\",\"type\":\"CITA_CANCELADA\",\"eventId\":\"e-2\"}");
        publish("zeal.notifications", "{\"userId\":\"p\",\"type\":\"NUEVA_CITA\",\"eventId\":\"e-3\"}");
        publish("zeal.wellbeing.slots", "{\"type\":\"CREADA\",\"slot\":{\"status\":\"DISPONIBLE\"},\"eventId\":\"e-4\"}");
        publish("zeal.wellbeing.freed-slots.taken", "{\"offerId\":\"o\",\"winnerId\":\"u\",\"eventId\":\"e-5\"}");
        publish("zeal.marketplace.applications", "{\"userId\":\"u\",\"application\":{\"status\":\"EN_ESPERA\"},\"eventId\":\"e-6\"}");
        publish("zeal.marketplace.enrollments", "{\"userId\":\"u\",\"enrollment\":{\"id\":\"i\"},\"eventId\":\"e-7\"}");
        publish("zeal.marketplace.workshops.published", "{\"organization\":\"N\",\"workshop\":{},\"eventId\":\"e-8\"}");
        redis.opsForSet().add(DomainEventMetrics.PRESENCE_USERS, "usr-a", "usr-b");
        Thread.sleep(1500);

        assertThat(count("zeal.business.appointments", "outcome", "reservada")).as("duplicado contado una vez").isEqualTo(1);
        assertThat(count("zeal.business.appointments", "outcome", "cancelada")).isEqualTo(1);
        assertThat(count("zeal.business.slots.opened", null, null)).isEqualTo(1);
        assertThat(count("zeal.business.freed_slots.taken", null, null)).isEqualTo(1);
        assertThat(count("zeal.business.applications", "status", "EN_ESPERA")).isEqualTo(1);
        assertThat(count("zeal.business.workshop_enrollments", null, null)).isEqualTo(1);
        assertThat(count("zeal.business.published", "kind", "taller")).isEqualTo(1);
        assertThat(meters.find("zeal.business.users.active").gauge().value()).isEqualTo(2);
    }

    private void publish(String channel, String json) {
        redis.convertAndSend(channel, json);
    }

    private double count(String name, String tag, String value) {
        var search = meters.find(name);
        if (tag != null) {
            search = search.tag(tag, value);
        }
        var counter = search.counter();
        return counter == null ? 0 : counter.count();
    }
}
