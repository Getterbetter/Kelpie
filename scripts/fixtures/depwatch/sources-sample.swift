// A stand-in for Sources/ in the cross-reference tests: one `method:` literal
// per line the way HerdrWire.swift spells them, and the dotted event-kind
// spellings HerdrEvents.swift uses.
let ping = HerdrRequest(method: "ping", params: [:])
let snapshot = HerdrRequest(method: "session.snapshot", params: [:])
let agents = HerdrRequest(method: "agent.list", params: [:])
let read = HerdrRequest(method: "pane.read", params: [:])

enum PaneEventKind: String {
    case paneUpdated = "pane.updated"
    case agentStatusChanged = "pane.agent_status_changed"
}
