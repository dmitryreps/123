import NetworkExtension

class FilterControlProvider: NEFilterControlProvider {
    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        FlowLog.appendSystem("control-start")
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        FlowLog.appendSystem("control-stop reason=\(reason.rawValue)")
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow, completionHandler: @escaping (NEFilterControlVerdict) -> Void) {
        completionHandler(.allow(withFilterData: true, withUpdate: false))
    }
}
