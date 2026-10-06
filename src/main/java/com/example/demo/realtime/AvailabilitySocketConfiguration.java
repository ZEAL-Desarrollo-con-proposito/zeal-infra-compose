package com.example.demo.realtime;

import java.util.Arrays;
import java.util.List;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Configuration;
import org.springframework.messaging.simp.config.MessageBrokerRegistry;
import org.springframework.web.socket.config.annotation.EnableWebSocketMessageBroker;
import org.springframework.web.socket.config.annotation.StompEndpointRegistry;
import org.springframework.web.socket.config.annotation.WebSocketMessageBrokerConfigurer;

@Configuration
@EnableWebSocketMessageBroker
public class AvailabilitySocketConfiguration implements WebSocketMessageBrokerConfigurer {

	private final List<String> allowedOrigins;

	public AvailabilitySocketConfiguration(
			@Value("${app.websocket.allowed-origin-patterns:http://localhost:3000,http://localhost:5173}")
			String allowedOrigins) {
		this.allowedOrigins = Arrays.stream(allowedOrigins.split(",")).map(String::trim).toList();
	}

	@Override
	public void configureMessageBroker(MessageBrokerRegistry registry) {
		registry.enableSimpleBroker("/topic");
		registry.setApplicationDestinationPrefixes("/app");
	}

	@Override
	public void registerStompEndpoints(StompEndpointRegistry registry) {
		registry.addEndpoint("/ws").setAllowedOriginPatterns(allowedOrigins.toArray(String[]::new));
	}
}
