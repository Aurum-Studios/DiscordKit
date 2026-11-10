[//]: # "File: Sources/DiscordLogging/DiscordLogging.docc/DiscordLogging.md | Created by Carson Rau. | Copyright (c) 2026 Aurum Studios. | https://aurum-studios.com"

# ``DiscordLogging``

Emit native SwiftLog diagnostics with application-owned outputs and task-scoped routing.

## Overview

``DiscordLog`` provides a logger factory used by independent operation owners.
Trace describes execution steps, debug describes diagnostic summaries, info records
normal lifecycle outcomes and notice records recovery or operational milestones.
Warning/error/critical identify degradation, terminal failure and lost safety.
Component thresholds and correlated operation context are task scoped.
Constructors and pure compilation emit nothing. The application configures
SwiftLog once and may select the optional `DiscordLogHandlers` product.

``DiscordIntervalTiming`` provides a separate, opt-in numeric lifecycle observer
without a SwiftLog bootstrap. Explicit runtime owners capture real begin/end
boundaries, retain finite parent/attempt context and flag invalid clock data.
Applications own bounded observation storage and output lifetime.

## Topics

### Adoption

- <doc:ScopedLogging>
- <doc:RuntimeIntervals>
- <doc:APIReference>
