import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BanyanCore

/// Explicit opt-in only. Sends two synthetic spans and queries only their IDs;
/// it never launches the app, modifies config, or inspects terminal sessions.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BANYAN_TELEMETRY_SMOKE"] == "1"))
func telemetryConfiguredLiveSmoke() async throws {
    let config = TelemetryConfig.load(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    guard let exporter = AxiomExporter.configured(config: config, appVersion: "telemetry-smoke") else {
        print("Axiom live smoke: no active configuration; dashboard verification remains pending.")
        return
    }
    let marker = UUID().uuidString.lowercased()
    guard let root = exporter.startSpan("telemetry.smoke.\(marker)", attributes: ["smoke.marker": marker]) else {
        Issue.record("Active exporter did not create a span")
        return
    }
    TraceContext.$current.withValue(root.context) {
        exporter.startSpan("telemetry.smoke.child", attributes: ["smoke.marker": marker])?.end()
    }
    root.end()
    let result = await exporter.shutdownAndWait(timeout: 15)
    #expect(result.exportedSpans == 2)
    #expect(result.droppedSpans == 0)
    guard result.exportedSpans == 2 else { return }
    print("Axiom smoke exported: marker=\(marker) trace_id=\(root.context.traceID)")

    let dataset = String(data: try JSONSerialization.data(withJSONObject: [config.axiomDataset]), encoding: .utf8)!
    let now = Date()
    let formatter = ISO8601DateFormatter()
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    func query(_ apl: String) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "https://api.axiom.co/v1/datasets/_apl?format=tabular")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(config.axiomAPIToken ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let org = config.axiomOrgID { request.setValue(org, forHTTPHeaderField: "X-Axiom-Org-ID") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "apl": apl,
            "startTime": formatter.string(from: now.addingTimeInterval(-120)),
            "endTime": formatter.string(from: Date().addingTimeInterval(30)),
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Never include the request, response body or errors in output: Axiom
        // can echo configuration or server details on a rejected query.
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }
    let (schemaStatus, _) = try await query("\(dataset) | getschema")
    #expect(schemaStatus == 200)
    guard schemaStatus == 200 else {
        print("Axiom smoke: schema query HTTP \(schemaStatus); query/dashboard evidence remains pending.")
        return
    }
    // Query by the generated trace ID, then verify the marker and parent-child
    // relation in Axiom's normalized OTel fields rather than trusting HTTP 200.
    let apl = "\(dataset) | where ['trace_id'] == '\(root.context.traceID)' | project ['name'], ['trace_id'], ['span_id'], ['parent_span_id'] | limit 2"
    var rows: [[String: String]] = []
    for attempt in 0..<6 {
        let (status, json) = try await query(apl)
        #expect(status == 200)
        guard status == 200 else {
            print("Axiom smoke: query HTTP \(status); query/dashboard evidence remains pending.")
            return
        }
        rows = (json["tables"] as? [[String: Any]] ?? []).flatMap { table -> [[String: String]] in
            let fields = (table["fields"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let columns = table["columns"] as? [[Any]] ?? []
            guard columns.count == fields.count else { return [] }
            return (0..<(columns.first?.count ?? 0)).map { index in
                Dictionary(uniqueKeysWithValues: fields.enumerated().map { fieldIndex, name in
                    (name, String(describing: columns[fieldIndex][index]))
                })
            }
        }
        if rows.count == 2 { break }
        if attempt < 5 { try await Task.sleep(nanoseconds: 2_000_000_000) }
    }
    #expect(rows.count == 2)
    #expect(rows.contains { $0["name"] == "telemetry.smoke.\(marker)" && $0["span_id"] == root.context.spanID })
    #expect(rows.contains { $0["name"] == "telemetry.smoke.child" && $0["parent_span_id"] == root.context.spanID })
    if rows.count == 2 { print("Axiom smoke query returned both spans and parent context. Visual dashboard verification remains pending.") }
}
