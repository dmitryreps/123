import NetworkExtension

class FilterDataProvider: NEFilterDataProvider {
    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        FlowLog.appendSystem("data-start")
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        FlowLog.appendSystem("data-stop reason=\(reason.rawValue)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        FlowLog.append(flow: flow)
        return NEFilterNewFlowVerdict.allow()
    }
}
