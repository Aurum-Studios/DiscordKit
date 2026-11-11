[//]: # "File: Sources/DiscordHTTP/DiscordHTTP.docc/Guides/RESTPhaseTiming.md | Created by Carson Rau. | Copyright (c) 2026 Aurum Studios. | https://aurum-studios.com"

# REST pipeline phase timing

Observe content-free REST pipeline attribution independently from the existing
exchange observer and detailed interval observer. Set `RESTClient.phaseTiming`
through its initializer; a nil option performs no instrumentation clock reads.
The consumer owns bounded aggregation and must return promptly, including when
called concurrently. Enabling this observer adds callback cost inside enclosing
request timers, so record the instrumentation configuration when comparing runs.

Construction ends as soon as the request builder returns or throws. Ordering ends
when the coordinator invokes the admitted operation, before request service.
Cache lookup includes its actor hop and records ordinary misses as success.
Decode covers each real decoder invocation; a successful wire response is decoded
once for validation before retention and once per caller. Cache hits decode once.
Retry wait covers only an explicit accepted policy sleep, including cancellation.
A 429's coordinator-controlled delay belongs to rate admission; no retry-sleep
observation is fabricated for it.

Terminal timestamps precede their own callbacks. The hook does not change rate,
ordering, retry, cache or cancellation policy. It creates no tasks, log bootstrap,
file writes or retained history, and it provides no network subphase attribution.

## Samples and invalid clocks

A scalar elapsed observation for one real construction, ordering, enabled cache
lookup, decoder or explicit retry-sleep boundary. Its fixed phase and finite outcome
carry no route, identity, credential, request body or error description.

An observer clock regression produces a nil elapsed value. Consumers must report
invalid evidence or loss rather than invent zero latency. Samples are independent
population observations, not correlated lifecycle intervals. Do not subtract
percentiles to construct a waterfall.
