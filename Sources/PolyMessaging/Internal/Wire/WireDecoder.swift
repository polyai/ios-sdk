// Copyright PolyAI Limited

import Foundation

enum WireDecoder {

    static func decode(_ data: Data, logger: PolyLogger? = nil) -> [MessagingEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? WireJSON else {
            logger?.warn("Failed to parse JSON frame", metadata: nil)
            return []
        }
        return decodeFrame(json, logger: logger)
    }

    static func decodeFrame(_ json: WireJSON, logger: PolyLogger? = nil) -> [MessagingEvent] {
        guard let typeString = json.string("type"), !typeString.isEmpty else {
            return []
        }

        if typeString == WireEventType.eventBatch.rawValue {
            return decodeBatch(json, logger: logger)
        }

        if let event = decodeSingle(json, logger: logger) {
            return [event]
        }
        return []
    }

    // MARK: - Batch

    private static func decodeBatch(_ json: WireJSON, logger: PolyLogger?) -> [MessagingEvent] {
        guard let payload = json.dict("payload"),
              let nested = payload.array("events") else {
            logger?.warn("Malformed event batch — dropped", metadata: nil)
            return []
        }

        let batchTypes = nested.compactMap { $0["type"] as? String }
        logger?.info("Batch contents", metadata: [
            "count": String(nested.count),
            "types": batchTypes.joined(separator: ","),
        ])

        var results: [MessagingEvent] = []
        for raw in nested {
            let reshaped = reshapeBatchEvent(raw, logger: logger)
            if let event = decodeSingle(reshaped, logger: logger) {
                results.append(event)
            } else if let typeStr = raw["type"] as? String {
                logger?.warn("Batch event dropped during decode", metadata: ["wireType": typeStr])
            }
        }

        // Events may arrive out of order during reconnection replay.
        // Sort by sequence; nil-sequence events preserve relative order at the end.
        return results.sortedBySequence()
    }

    private static func reshapeBatchEvent(_ event: WireJSON, logger: PolyLogger?) -> WireJSON {
        guard let type = event.string("type"), !type.isEmpty else { return event }

        let isObject: (Any?) -> Bool = { v in
            v != nil && v is WireJSON
        }

        var payload: Any? = isObject(event["payload"]) ? event["payload"] : nil

        if payload == nil {
            let payloadKey = type
                .replacingOccurrences(of: "EVENT_TYPE_", with: "")
                .lowercased()
            let oneofPayload = event[payloadKey]
            if isObject(oneofPayload) {
                payload = oneofPayload
            } else {
                logger?.warn("Batch event payload not found — emitting empty", metadata: ["wireType": type])
            }
        }

        return [
            "id": event["id"] as Any,
            "type": type,
            "sequence": event["sequence"] as Any,
            "timestamp": event["timestamp"] as Any,
            "metadata": event["metadata"] as Any,
            "payload": (payload as? WireJSON) ?? [:] as WireJSON,
        ]
    }

    // MARK: - Single event

    private static func decodeSingle(_ json: WireJSON, logger: PolyLogger?) -> MessagingEvent? {
        guard let typeString = json.string("type"),
              let wireType = WireEventType(rawValue: typeString) else {
            if let t = json.string("type") {
                logger?.warn("Unknown event type — dropped", metadata: ["wireType": t])
            }
            return nil
        }

        let isHeartbeat = wireType == .heartbeat
        guard isHeartbeat || (json.string("id") != nil && json.string("timestamp") != nil) else {
            return nil
        }

        let envelope = Envelope(
            id: json.string("id") ?? "",
            sequence: json.int("sequence"),
            timestamp: json.date("timestamp") ?? Date(),
            metadata: decodeMetadata(json.dict("metadata"))
        )

        let payload = json.dict("payload") ?? [:]

        switch wireType {
        case .heartbeat:
            return .heartbeat(envelope)
        case .sessionStart:
            return .sessionStart(envelope, decodeSessionStart(payload))
        case .sessionEnd:
            return .sessionEnd(envelope, SessionEndPayload(reason: payload.string("reason")))
        case .userMessage:
            return .userMessage(envelope, UserMessageEchoPayload(
                messageId: payload.string("message_id") ?? "",
                text: payload.string("text") ?? ""
            ))
        case .userTyping:
            return .userTyping(envelope)
        case .userEndSession:
            return .userEndSession(envelope)
        case .requestPolyAgentJoin:
            return .requestPolyAgentJoin(envelope)
        case .polyAgentJoined:
            return .agentJoined(envelope, AgentJoinedPayload(
                agentName: payload.string("agent_name"),
                avatarUrl: payload.url("agent_avatar_url") ?? payload.url("avatar_url")
            ))
        case .polyAgentThinking:
            return .agentThinking(envelope)
        case .polyAgentMessage:
            return .agentMessage(envelope, decodeAgentMessage(payload))
        case .polyAgentMessageChunk:
            return .agentMessageChunk(envelope, decodeAgentChunk(payload))
        case .polyAgentLeft:
            return .agentLeft(envelope, AgentLeftPayload(reason: payload.string("reason")))
        case .polyAgentTriggeredHandoff:
            return .agentTriggeredHandoff(envelope)
        case .liveAgentJoined:
            return .liveAgentJoined(envelope, decodeLiveAgentJoined(payload))
        case .liveAgentTyping:
            // Honor server-sent `state` so STOPPED actually dismisses the
            // typing indicator instead of (silently) restarting it. Missing
            // state defaults to .started to stay compatible with any legacy
            // sender that omits it.
            let typingState = TypingState(rawValue: payload.string("state") ?? "") ?? .started
            return .liveAgentTyping(envelope, LiveAgentTypingPayload(
                state: typingState,
                agentId: payload.string("agent_id"),
                agentName: payload.string("agent_name")
            ))
        case .liveAgentMessage:
            return .liveAgentMessage(envelope, decodeLiveAgentMessage(payload))
        case .liveAgentLeft:
            return .liveAgentLeft(envelope, LiveAgentLeftPayload(
                agentId: payload.string("agent_id"),
                agentName: payload.string("agent_name"),
                reason: payload.string("reason")
            ))
        case .systemMessage:
            return .systemMessage(envelope, SystemMessagePayload(
                message: payload.string("message") ?? "",
                level: SystemMessageLevel(rawValue: payload.string("level") ?? "") ?? .info
            ))
        case .clientHandoffRequired:
            // V2 backend sends `{route}` only (events.proto:221-223). Legacy
            // `reason` / `queue_name` decoded as fallbacks for older servers.
            return .clientHandoffRequired(envelope, ClientHandoffRequiredPayload(
                route: payload.string("route"),
                reason: payload.string("reason"),
                queueName: payload.string("queue_name")
            ))
        case .handoffQueueStatus:
            // V2 backend (events.proto:225-229) sends position_in_queue +
            // estimated_wait_seconds + queue_name; we also probe `position`
            // and `display_message` as legacy / forward-compat field names.
            return .handoffQueueStatus(envelope, HandoffQueueStatusPayload(
                position: payload.int("position_in_queue") ?? payload.int("position"),
                estimatedWaitSeconds: payload.int("estimated_wait_seconds"),
                queueName: payload.string("queue_name"),
                displayMessage: payload.string("display_message")
            ))
        case .handoffAccepted:
            return .handoffAccepted(envelope, HandoffAcceptedPayload(
                queueName: payload.string("queue_name")
            ))
        case .handoffFailed:
            return .handoffFailed(envelope, HandoffFailedPayload(
                reason: payload.string("reason")
            ))
        case .handoffTimeout:
            return .handoffTimeout(envelope, HandoffTimeoutPayload(
                reason: payload.string("reason")
            ))
        case .sessionIdleWarning:
            return .sessionIdleWarning(envelope)
        case .userReceivedMessage, .userReadMessage,
             .polyAgentReceivedMessage, .polyAgentReadMessage,
             .liveAgentReceivedMessage, .liveAgentReadMessage,
             .showCsatRequest, .csatResponse:
            // Spec-defined incoming events the backend isn't sending yet.
            // Drop with a log rather than crash so they surface when they
            // start arriving.
            logger?.debug("TBD event received", metadata: ["type": typeString])
            return nil
        case .eventBatch:
            return nil
        }
    }

    // MARK: - Payload decoders

    private static func decodeMetadata(_ json: WireJSON?) -> EventMetadata? {
        guard let json else { return nil }
        let custom = json["custom"] as? [String: String]
        return EventMetadata(custom: custom)
    }

    private static func decodeSessionStart(_ p: WireJSON) -> SessionStartPayload {
        let caps = p.dict("capabilities") ?? [:]
        return SessionStartPayload(capabilities: SessionCapabilities(
            streaming: caps.bool("streaming") ?? false,
            // Backend default is 1 MiB — the fallback only fires if the server
            // omits the capability.
            maxMessageSize: caps.int("max_message_size_bytes") ?? 1_048_576,
            heartbeatIntervalSeconds: caps.int("heartbeat_interval_seconds"),
            maxReconnectAttempts: caps.int("max_reconnect_attempts")
        ))
    }

    private static func decodeAgentMessage(_ p: WireJSON) -> AgentMessagePayload {
        AgentMessagePayload(
            messageId: p.string("message_id") ?? "",
            text: p.string("text") ?? "",
            agentName: p.string("agent_name"),
            avatarUrl: p.url("avatar_url"),
            attachments: decodeAttachments(p.array("attachments")),
            responseSuggestions: decodeSuggestions(p.array("response_suggestions")),
            chatCallActions: decodeChatCallActions(p.array("chat_call_actions")),
            endConversation: p.bool("end_conversation") ?? false
        )
    }

    private static func decodeAgentChunk(_ p: WireJSON) -> AgentMessageChunkPayload {
        AgentMessageChunkPayload(
            messageId: p.string("message_id") ?? "",
            chunkIndex: p.int("chunk_index") ?? 0,
            isComplete: p.bool("is_complete") ?? false,
            text: p.string("text"),
            attachments: decodeAttachments(p.array("attachments")),
            responseSuggestions: decodeSuggestions(p.array("response_suggestions"))
        )
    }

    private static func decodeLiveAgentJoined(_ p: WireJSON) -> LiveAgentJoinedPayload {
        var id = p.string("agent_id")
        var name = p.string("agent_name")
        var avatar = p.url("avatar_url")
        // V2 wire form: payload is `{agent: AgentInfo{id, name, avatar_url}}`
        // per `events.proto:180-182`. Earlier builds flattened the same fields
        // at the top level; honor both.
        if let agent = p.dict("agent") {
            id = id ?? agent.string("id")
            name = name ?? agent.string("name")
            avatar = avatar ?? agent.url("avatar_url")
        }
        return LiveAgentJoinedPayload(agentId: id, agentName: name, avatarUrl: avatar)
    }

    private static func decodeLiveAgentMessage(_ p: WireJSON) -> LiveAgentMessagePayload {
        LiveAgentMessagePayload(
            messageId: p.string("message_id") ?? "",
            text: p.string("text") ?? "",
            agentId: p.string("agent_id"),
            agentName: p.string("agent_name"),
            avatarUrl: p.url("avatar_url"),
            attachments: decodeAttachments(p.array("attachments")),
            responseSuggestions: decodeSuggestions(p.array("response_suggestions")),
            chatCallActions: decodeChatCallActions(p.array("chat_call_actions"))
        )
    }

    // MARK: - Shared component decoders

    private static func decodeAttachments(_ arr: [WireJSON]?) -> [Attachment] {
        guard let arr else { return [] }
        return arr.map { a in
            Attachment(
                contentType: AttachmentContentType(rawValue: a.string("content_type") ?? "") ?? .unknown,
                contentUrl: a.url("content_url"),
                title: a.string("title"),
                previewImageUrl: a.url("preview_image_url"),
                callToActionText: a.string("call_to_action_text")
            )
        }
    }

    private static func decodeSuggestions(_ arr: [WireJSON]?) -> [ResponseSuggestion] {
        guard let arr else { return [] }
        return arr.map { s in
            ResponseSuggestion(
                messageText: s.string("message_text") ?? "",
                payload: s.string("payload")
            )
        }
    }

    private static func decodeChatCallActions(_ arr: [WireJSON]?) -> [ChatCallAction] {
        guard let arr else { return [] }
        return arr.map { c in
            ChatCallAction(
                title: c.string("title") ?? "",
                contactNumber: c.string("contact_number") ?? ""
            )
        }
    }
}

// MARK: - Batch sequence ordering

private extension Array where Element == MessagingEvent {

    /// Stable-sort by envelope sequence. Events without a sequence are kept in
    /// their original relative order and placed after all sequenced events.
    func sortedBySequence() -> [MessagingEvent] {
        // Pair each event with its original index for a stable nil-preserving sort.
        return enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.envelope?.sequence, rhs.element.envelope?.sequence) {
                case let (a?, b?):  return a < b
                case (_?, nil):     return true
                case (nil, _?):     return false
                case (nil, nil):    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }
}
