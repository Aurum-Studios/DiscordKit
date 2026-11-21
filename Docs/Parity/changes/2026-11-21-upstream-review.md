<!-- copyright:begin
File: Docs/Parity/changes/2026-11-21-upstream-review.md
Created by Carson Rau.
Copyright (c) 2026 Aurum Studios.
https://aurum-studios.com
copyright:end -->

# November 21 upstream maintenance review

Reviewed November 21, 2026 UTC. The next review is due November 28. REST and
Gateway remain v10, and Voice Gateway remains v8. The review compared 39 paths
across seven written-documentation commits. Of the 24 previously maintained
written sources, 10 changed and 14 were byte-identical. Both OpenAPI files
were byte-identical at the November 13 revision. The snapshot records 29
source hashes, including the lobby and native Social SDK pages reviewed for
this update. [Dated source snapshot](../../Release/sources/2026-11-21-upstream-review.json) ·
[Written-documentation comparison](https://github.com/discord/discord-api-docs/compare/36adecb2e0bbbf500c430147ef4acbe9aa1a389e...9b737ec51ee8d5076af0565d209a9adf8f590a27) ·
[Stable and preview OpenAPI revision](https://github.com/discord/discord-api-spec/tree/3a21a01249a763cd47f1dfec3da91c5ba71bb974)

## Effective HTTP and Gateway channel obfuscation

Discord confirmed the November 16 rollout to all bots. Get Guild Channels omits
channels Discord considers non-viewable. A channel also counts as viewable when
the client is connected to it by voice, and a category is viewable when it has a
viewable child. DiscordKit returns the channel list from Discord and treats an
omitted entry as an absence from that response. The before/on-date, empty and
restored fixtures still cover the boundary. [Discord rollout](https://docs.discord.com/developers/change-log#channel-obfuscation-is-now-live-for-all-bots) ·
[Guild endpoint](https://docs.discord.com/developers/resources/guild#get-guild-channels) ·
[HTTP fixtures](../../../Tests/DiscordHTTPTests/ChannelTransitionTests.swift)

Gateway Channel Create, Update and Delete can carry obfuscated objects, as can
the channel list in Guild Create. The response flag at bit 17 still identifies
obfuscation. Discord withdrew the temporary Identify bit and portal opt-in
guidance. Existing callers can stop requesting `GatewayCapabilities.channelObfuscation`.
Gateway decoders preserve raw channel metadata. The cache removes unreliable
fields from available obfuscated projections, records their redaction and handles
deletion by ID. The permission resolver treats obfuscated inputs as indeterminate. [Gateway Identify](https://docs.discord.com/developers/events/gateway-events#identify-gateway-capabilities) ·
[Channel reference](https://docs.discord.com/developers/resources/channel#channel-object-obfuscated-channels) ·
[Cache fixtures](../../../Tests/DiscordCacheTests/DiscordCacheTests.swift)

## REST and Voice updates

- Create and modify lobby requests already cap submitted members at 25. Bulk
  updates accept 1–25 members. Discord owns the 1,000-member lobby capacity.
  HTTP 400 errors such as code 50035 retain Discord's nested validation details
  when returned. The error decoder also preserves expired-invite code 50270 as
  an open numeric value. [Lobby reference](https://docs.discord.com/developers/resources/lobby#create-lobby-member-limits) ·
  [JSON error codes](https://docs.discord.com/developers/topics/opcodes-and-status-codes) ·
  [Lobby boundary tests](../../../Tests/DiscordModelsTests/LobbyRequestTests.swift) ·
  [REST error tests](../../../Tests/DiscordHTTPTests/RESTClientTests.swift)
- The Voice supervisor requests v8, accepts the additional Hello version field
  and reads the heartbeat interval. Version validation and fallback negotiation
  remain outside its coverage. Received Speaking already binds a user's SSRC to
  the receive stream. [Voice Gateway versioning](https://docs.discord.com/developers/topics/voice-connections#voice-gateway-versioning) ·
  [Voice session tests](../../../Tests/DiscordVoiceTests/VoiceSessionTests.swift)
- Voice opcode 15 documents Media Sink Wants in both directions. Discord's
  receive-all default remains compatible with the current session. Raw frames
  preserve the opcode. Typed subscription updates, the `any` fallback and
  per-SSRC selection, whole-map replacement after Ready, and handling server
  subscription events remain unsupported. [Media Sink Wants](https://docs.discord.com/developers/topics/voice-connections#media-sink-wants) ·
  [Voice capability inventory](../voice-media-capabilities.json)

Native Social SDK 1.11.24259, platform compatibility and support cadence updates
apply to the upstream native SDK. The other changes update Doxygen reference URLs
and generated mappings or adjust Snowflake diagram styling. Existing protocol
support classifications and specification gaps remain in effect. [Native SDK
release](https://docs.discord.com/developers/change-log#discord-social-sdk-release-11124259) ·
[Previous specification review](2026-11-13-upstream-review.md)

## Verification scope

The [maintenance ledger](../../Release/maintenance.json) binds this review to the
source snapshot and the existing dated transition fixture. The local maintenance
check accepted November 21 and the inclusive November 28 deadline, then rejected
November 29 as overdue. The upstream collector completed against the official
Git repositories and changelog after retrying Git with HTTP/1.1. All 236 release
tooling tests and both upstream collector tests passed. Hosted TeamCity
certification and live Discord acceptance require their own receipts.
