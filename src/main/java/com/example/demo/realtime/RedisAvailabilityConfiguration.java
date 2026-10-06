package com.example.demo.realtime;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.listener.ChannelTopic;
import org.springframework.data.redis.listener.RedisMessageListenerContainer;

@Configuration
@ConditionalOnProperty(name = "app.redis.enabled", havingValue = "true", matchIfMissing = true)
public class RedisAvailabilityConfiguration {

	@Bean
	ChannelTopic availabilityTopic() {
		return new ChannelTopic(ReservationEventPublisher.CHANNEL);
	}

	@Bean
	RedisMessageListenerContainer availabilityListenerContainer(
			RedisConnectionFactory connectionFactory, RedisAvailabilityMessageListener listener,
			ChannelTopic availabilityTopic) {
		RedisMessageListenerContainer container = new RedisMessageListenerContainer();
		container.setConnectionFactory(connectionFactory);
		container.addMessageListener(listener, availabilityTopic);
		return container;
	}
}
