package co.zeal.metrics;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.listener.ChannelTopic;
import org.springframework.data.redis.listener.PatternTopic;
import org.springframework.data.redis.listener.RedisMessageListenerContainer;

import java.util.List;

/** Escucha los canales de dominio existentes (los mismos que consume el Real-Time Gateway). */
@Configuration
public class ListenerConfig {

    @Bean
    RedisMessageListenerContainer domainEventsListener(RedisConnectionFactory connectionFactory,
                                                       DomainEventMetrics metrics) {
        RedisMessageListenerContainer container = new RedisMessageListenerContainer();
        container.setConnectionFactory(connectionFactory);
        container.addMessageListener(metrics, List.of(new PatternTopic("zeal.wellbeing.*"),
                new PatternTopic("zeal.marketplace.*"), new ChannelTopic("zeal.notifications")));
        return container;
    }
}
