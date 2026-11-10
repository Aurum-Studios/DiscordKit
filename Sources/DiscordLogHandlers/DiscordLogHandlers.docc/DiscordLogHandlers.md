[//]: # "File: Sources/DiscordLogHandlers/DiscordLogHandlers.docc/DiscordLogHandlers.md | Created by Carson Rau. | Copyright (c) 2026 Aurum Studios. | https://aurum-studios.com"

# ``DiscordLogHandlers``

Choose optional logging outputs and bounded numeric timing adapters.

## Overview

Runtime products never select these handlers. An application opens
``DiscordFileLogSink`` explicitly, constructs value-semantic handlers and chooses
its own SwiftLog bootstrap. Standard `StreamLogHandler` supplies console output;
standard `MultiplexLogHandler` combines destinations. Wrap individual outputs with
``DiscordLevelFilterLogHandler`` to preserve minimum severities when logger thresholds change.
All dynamic Apple unified-log payloads are private by default.

Timing adapters consume finite observations from `DiscordLogging`. Aggregation
and capture retain bounded numeric state; applications own close and file export.
Apple signposts consume genuine live begin/end callbacks rather than reconstructed
scalar samples. Runtime products retain their independent output-free graph.

## Topics

### Output ownership

- <doc:OutputOwnership>
- <doc:TimingOutputs>
- <doc:APIReference>
