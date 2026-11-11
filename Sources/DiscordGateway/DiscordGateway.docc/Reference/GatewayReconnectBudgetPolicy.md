[//]: # "File: Sources/DiscordGateway/DiscordGateway.docc/Reference/GatewayReconnectBudgetPolicy.md | Created by Carson Rau. | Copyright (c) 2026 Aurum Studios. | https://aurum-studios.com"

# ``DiscordGateway/GatewayReconnectBudgetPolicy``

## Overview

Select this `Sendable`, `Equatable` policy through
``GatewayShardConfiguration/reconnectBudgetPolicy``. The default preserves the
total-run retry bound. Healthy-session renewal is an explicit local policy using
same-generation monotonic uptime and conservative scheduled-heartbeat ACK evidence;
it never overrides terminal failures or shared admission authority.

## Topics

### Selecting the renewal boundary

- ``DiscordGateway/GatewayReconnectBudgetPolicy/totalRun``
- ``DiscordGateway/GatewayReconnectBudgetPolicy/afterHealthySession(minimumDuration:minimumScheduledHeartbeatACKs:)``

## See Also

- <doc:GatewayReconnectBudgets>
- ``GatewayShardConfiguration``

<!-- API descriptions live in declaration comments; this page curates policy navigation. -->
