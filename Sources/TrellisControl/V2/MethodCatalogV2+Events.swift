import Foundation
import TrellisCore

/// Events (docs/api/events.md): subscriptions on the socket and `events.poll` on any transport.
extension MethodCatalogV2 {
    /// Each topic's capability, required only when the topic is asked for (events.md, Topics and types).
    private static func topicCapabilities(_ topics: [EventTopicV2]) -> [ConditionalCapabilityV2] {
        var byCapability: [CapabilityV2: [EventTopicV2]] = [:]
        for topic in topics { for capability in topic.capabilities { byCapability[capability, default: []].append(topic) } }
        return byCapability.sorted { $0.key < $1.key }.map { capability, topics in
            let conditions = topics.sorted().map { ConditionV2.contains("topics", $0.rawValue) }
            return ConditionalCapabilityV2(capability, if: conditions.count == 1 ? conditions[0] : .anyOf(conditions))
        }
    }

    private static let pollTopics = EventTopicV2.allCases.filter { $0 != .output }
    private static let spaceIDs = ParamV2("spaceIds", .uuidList(maxCount: 100), "Only events in these spaces; events without a space (hosts, projects, appearance, grant) never match.")
    private static let afterSequence = ParamV2("afterSequence", .integer(minimum: 0), "Return events after this sequence (from a previous event or nextSequence).")
    private static let instanceID = ParamV2(
        "instanceId", .uuid, unscoped: true, "The instanceId the sequence came from; another instance's is INVALID_CURSOR (start again from workspace.get).")

    static let events: [MethodSpecV2] = [
        MethodSpecV2(
            "events.subscribe", "Follow events on this socket connection as events.event notifications, replaying retained ones after afterSequence.",
            params: [
                ParamV2("topics", .stringList(values: EventTopicV2.allCases.map(\.rawValue), maxCount: 13), required: true, "Topics to follow; each needs its own capability."),
                ParamV2("resourceIds", .uuidList(maxCount: 100), "Only events about these spaces, tabs, panes or sessions (an event matches its resource, pane, session, tab or space)."),
                spaceIDs, afterSequence, instanceID
            ], conditional: topicCapabilities(EventTopicV2.allCases),
            resources: [ResourceRuleV2(.anyLayout, "resourceIds", list: true), ResourceRuleV2(.space, "spaceIds", list: true)], errors: [.invalidCursor],
            socketOnly: true),
        MethodSpecV2(
            "events.unsubscribe", "Stop a subscription this connection made.",
            params: [ParamV2("subscriptionId", .uuid, required: true, unscoped: true, "The subscriptionId events.subscribe returned.")], errors: [.notFound],
            socketOnly: true),
        MethodSpecV2(
            "events.poll", "Wait up to timeoutMs for events after afterSequence and return them (never output); works on every transport, including MCP.",
            params: [
                ParamV2("topics", .stringList(values: pollTopics.map(\.rawValue), maxCount: 12), required: true, "Topics to return; each needs its own capability."),
                spaceIDs, afterSequence, instanceID,
                ParamV2("timeoutMs", .integer(minimum: 0, maximum: Int64(EventHubV2.maximumTimeoutMs)), "How long to wait for the first event, 0–25000 ms; default 0 (return at once)."),
                ParamV2("limit", .integer(minimum: 1, maximum: Int64(PageV2.maximumLimit)), "Most events to return, 1–\(PageV2.maximumLimit); default \(EventHubV2.defaultPollLimit).")
            ], conditional: topicCapabilities(pollTopics), resources: [ResourceRuleV2(.space, "spaceIds", list: true)], errors: [.invalidCursor])
    ]
}
