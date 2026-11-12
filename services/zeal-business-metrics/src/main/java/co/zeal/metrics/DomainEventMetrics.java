package co.zeal.metrics;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.connection.Message;
import org.springframework.data.redis.connection.MessageListener;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.time.Duration;

/**
 * R2-31 / MANT-2 · Métricas de negocio derivadas de los eventos de dominio que YA publican wellbeing y
 * marketplace por Redis Pub/Sub. Es un consumidor nuevo e independiente: no requirió cambiar ni una
 * línea de los productores (lee los canales y el formato de siempre).
 *
 * <p>Varias réplicas reciben cada evento; solo cuenta la que reclama su {@code eventId} ({@code SET NX}).
 * Nunca se registra el contenido de un evento (traen nombres y textos de notificaciones).
 */
@Component
public class DomainEventMetrics implements MessageListener {

    static final String PRESENCE_USERS = "zeal:presence:users";
    private static final Logger log = LoggerFactory.getLogger(DomainEventMetrics.class);

    private final MeterRegistry meters;
    private final StringRedisTemplate redis;
    private final ObjectMapper objectMapper;

    public DomainEventMetrics(MeterRegistry meters, StringRedisTemplate redis, ObjectMapper objectMapper) {
        this.meters = meters;
        this.redis = redis;
        this.objectMapper = objectMapper;
        // Personas conectadas en este momento (presencia compartida del gateway, solo lectura).
        Gauge.builder("zeal.business.users.active", redis, r -> {
            Long count = r.opsForSet().size(PRESENCE_USERS);
            return count == null ? 0 : count;
        }).description("Personas con al menos una conexión en tiempo real").register(meters);
    }

    @Override
    public void onMessage(Message message, byte[] pattern) {
        String channel = new String(message.getChannel(), StandardCharsets.UTF_8);
        try {
            JsonNode event = objectMapper.readTree(message.getBody());
            if (!claim(channel, event)) {
                return;
            }
            count(channel, event);
        } catch (Exception e) {
            log.warn("Evento ilegible en {}: {}", channel, e.getClass().getSimpleName());
        }
    }

    private void count(String channel, JsonNode event) {
        switch (channel) {
            case "zeal.notifications" -> {
                switch (event.path("type").asText()) {
                    case "RESERVA_CONFIRMADA" -> appointment("reservada");
                    case "CITA_CANCELADA" -> appointment("cancelada");
                    default -> { /* otros avisos no son métricas de negocio */ }
                }
            }
            case "zeal.wellbeing.slots" -> {
                if ("CREADA".equals(event.path("type").asText())) {
                    meters.counter("zeal.business.slots.opened").increment();
                }
            }
            case "zeal.wellbeing.freed-slots.taken" -> meters.counter("zeal.business.freed_slots.taken").increment();
            case "zeal.marketplace.applications" -> meters.counter("zeal.business.applications",
                    "status", event.path("application").path("status").asText("DESCONOCIDO")).increment();
            case "zeal.marketplace.enrollments" -> meters.counter("zeal.business.workshop_enrollments").increment();
            case "zeal.marketplace.projects.published" -> meters.counter("zeal.business.published", "kind", "convocatoria").increment();
            case "zeal.marketplace.workshops.published" -> meters.counter("zeal.business.published", "kind", "taller").increment();
            default -> { /* canal sin métrica de negocio */ }
        }
        meters.counter("zeal.business.events", "channel", channel).increment();
    }

    private void appointment(String outcome) {
        meters.counter("zeal.business.appointments", "outcome", outcome).increment();
    }

    /** Eventos sin eventId (productores anteriores a R2-24) se cuentan en cada réplica: correr una sola. */
    private boolean claim(String channel, JsonNode event) {
        String eventId = event.path("eventId").asText(null);
        return eventId == null || Boolean.TRUE.equals(redis.opsForValue()
                .setIfAbsent("zeal:metrics-claims:" + channel + ":" + eventId, "1", Duration.ofMinutes(10)));
    }
}
