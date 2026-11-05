package io.pivotal.refarch.cqrs.trader.tradingengine;

import org.axonframework.commandhandling.CommandBus;
import org.axonframework.commandhandling.CommandMessage;
import org.axonframework.messaging.MessageHandlerInterceptor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.context.annotation.Configuration;

/**
 * Logs every command this node handles, including its payload (which carries the target aggregate identifier), on the
 * local segment of the {@link org.axonframework.commandhandling.distributed.DistributedCommandBus}. With several
 * replicas this shows which pod the consistent-hash ring routed each command to.
 */
@Configuration
public class CommandLoggingConfiguration {

    private static final Logger logger = LoggerFactory.getLogger(CommandLoggingConfiguration.class);

    @Autowired
    public void configure(@Qualifier("localSegment") CommandBus commandBus) {
        MessageHandlerInterceptor<CommandMessage<?>> interceptor = (unitOfWork, chain) -> {
            logger.info("Handling command {}", unitOfWork.getMessage().getPayload());
            return chain.proceed();
        };
        commandBus.registerHandlerInterceptor(interceptor);
    }
}
