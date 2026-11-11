[//]: # "File: Sources/DiscordGateway/DiscordGateway.docc/Guides/GatewayReconnectBudgets.md | Created by Carson Rau. | Copyright (c) 2026 Aurum Studios. | https://aurum-studios.com"

# Choosing a bounded reconnect policy

Keep the default total-run limit or explicitly renew it after observed session health.

## Overview

``GatewayShard`` owns connection recovery inside one run. The
``GatewayShardConfiguration/reconnectBudgetPolicy`` property selects when its local
retry count and backoff progression can reset. The default
``GatewayReconnectBudgetPolicy/totalRun`` preserves the existing total-run budget.
``GatewayShardConfiguration/maximumReconnectAttempts`` still accepts `0...30`,
defaults to `5`, and counts replacement connection attempts. Zero permits only the
original connection under either policy.

### Opt in to healthy-session renewal

The ``GatewayReconnectBudgetPolicy/afterHealthySession(minimumDuration:minimumScheduledHeartbeatACKs:)``
case requires a positive duration and a positive ACK threshold. Configuration
validation rejects nonpositive values. The policy is supplied as the last,
defaulted configuration initializer argument, so existing calls retain their
previous behavior.

```swift
import DiscordGateway

let configuration = try GatewayShardConfiguration(
    maximumReconnectAttempts: 5,
    reconnectBudgetPolicy: .afterHealthySession(
        minimumDuration: .seconds(300),
        minimumScheduledHeartbeatACKs: 2
    )
)
```

These 300-second/two-ACK values are MiniCarson's proposed service policy. They are
neither a Discord requirement nor the DiscordKit default. Choose application policy
explicitly; this configuration opens no socket and starts no task.

### Understand the health evidence

Health belongs to one socket generation. That generation must accept READY or
RESUMED, remain healthy for the configured monotonic duration, and observe the
required number of qualifying ACKs after adapter-confirmed scheduled heartbeat
writes. Earlier generations contribute neither elapsed time nor ACKs.

Unsolicited, requested-heartbeat and pre-ready ACKs do not establish health. Neither
do early ACKs received before scheduled write confirmation. Overlapping requested
and scheduled heartbeats invalidate the sample. More than two outstanding
ambiguous observations can disable further health observations
for that generation. Discord's ACK contains no nonce: the classifier records
conservative observations, without claiming exact heartbeat/ACK pairing.

The owner freezes the healthy interval at session failure before joining child and
socket cleanup. Cleanup, retry waits and disconnected time cannot complete an
otherwise short interval. No extra timer or retained history is introduced.

### Preserve failure and ownership boundaries

The next eligible recoverable failure applies earned health to reset the retry
count and backoff progression, then follows ordinary bounded recovery. Accepting
READY, RESUMED or an ACK does not itself reset retries or replace a connection.
Cancellation, fatal or terminal failures, ownership and coordinator failures,
malformed input and overflow keep their existing precedence. A healthy session
does not authorize recovery from them.

Repeated qualifying sessions can allow more replacements over a long run; an
unhealthy interval still has the configured finite budget. The same shard run owns
every socket and joins cleanup before handoff. The policy introduces no outer
restart, changes no heartbeat schedule, and preserves shared Identify/session-start
and opcode limits, lease fences and fail-closed continuity. It does not replay
application effects or supply live Discord qualification.

### Protocol sources

Verified **2026-11-11** against the official
[Gateway reference](https://docs.discord.com/developers/events/gateway) and
[Gateway close codes](https://docs.discord.com/developers/topics/opcodes-and-status-codes).
Discord documents scheduled and requested heartbeats, ACK receipt and retained
session Resume; healthy-session budget renewal is DiscordKit's explicit local
policy. This supplemental review does not replace the historical discovery
baseline.

## See Also

- <doc:GatewayLifecycle>
- ``GatewayReconnectBudgetPolicy``
- ``GatewayShardConfiguration``
