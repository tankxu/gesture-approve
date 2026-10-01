import Foundation

/// Price table = bundled snapshot < LiteLLM community map (refreshed daily) < user's pricing.local.json, merged per model.
/// New models are priced as soon as LiteLLM lists them; no app release needed. Only numbers are taken from the remote file.
enum MonitorPricing {
    static let remoteURL = URL(string: ProcessInfo.processInfo.environment["GA_PRICING_URL"] ?? "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    static var remotePath: String { MonitorIO.root + "/pricing-remote.json" }
    static var overridePath: String { MonitorIO.root + "/pricing.local.json" }
    static let refreshInterval: Double = 86400, retryInterval: Double = 3600
    private static let lock = NSLock()
    private static var cached: (key: String, table: MObject)?
    private static var inFlight = false, lastAttempt = 0.0, fetchedAt: Double?

    /// Merged table: ["version", "models", "internal"]. Rebuilt only when one of the source files changes.
    static func table() -> MObject {
        let paths = [AppPaths.resource("config/monitor-pricing.json"), remotePath, overridePath]
        let key = paths.map { p in "\(((try? FileManager.default.attributesOfItem(atPath:p))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)" }.joined(separator:"|")
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.key == key { return cached.table }
        let layers = paths.map(MonitorIO.read)
        var models: MObject = [:], internalModels = Set<String>(), versions: [String] = []
        for (i, layer) in layers.enumerated() where !layer.isEmpty {
            for (id, p) in layer["models"] as? MObject ?? [:] { if let p = p as? MObject, valid(p) { models[id] = p } }
            internalModels.formUnion(layer["internal"] as? [String] ?? [])
            versions.append(["bundled ","LiteLLM ","local "][i] + (layer["version"] as? String ?? "?"))
        }
        let table: MObject = ["version": versions.isEmpty ? "unavailable" : versions.joined(separator:" + "), "models": models, "internal": Array(internalModels).sorted()]
        cached = (key, table); return table
    }

    /// Exact ID first, then the same ID without deployment wrappers: `[1m]`, `us.anthropic.`/`openai/` prefixes, `-YYYYMMDD` snapshots, `-v1:0`.
    /// Never falls back to a "similar" model: an unknown model stays unpriced.
    static func lookup(_ model: String, _ models: MObject) -> MObject? {
        var id = model.lowercased()
        if let p = models[model] as? MObject ?? models[id] as? MObject { return p }
        if let b = id.firstIndex(of:"[") { id = String(id[..<b]) }
        if let slash = id.lastIndex(of:"/") { id = String(id[id.index(after:slash)...]) }
        if let r = id.range(of:#"^([a-z-]+\.)?(anthropic|openai)\."#, options:.regularExpression) { id.removeSubrange(r) }
        id = id.replacingOccurrences(of:#"-v\d+(:\d+)?$"#, with:"", options:.regularExpression)
        if let p = models[id] as? MObject { return p }
        id = id.replacingOccurrences(of:#"-\d{8}$"#, with:"", options:.regularExpression)
        return models[id] as? MObject
    }

    /// Per-million prices must be finite, non-negative and below an implausible ceiling, or the model is dropped (stays unpriced).
    static func valid(_ p: MObject) -> Bool {
        guard p["input"] != nil, p["output"] != nil else { return false }
        return p.allSatisfy { k, v in
            guard let n = v as? NSNumber else { return false }
            let x = n.doubleValue
            return x.isFinite && x >= 0 && (["longAbove","maxInput"].contains(k) ? x <= 1e8 : k.hasSuffix("Multiplier") ? x <= 20 : x <= 1000)
        }
    }

    /// LiteLLM per-token USD → our per-million schema. Only first-party Anthropic/OpenAI text models are kept.
    static func convert(_ raw: MObject) -> MObject {
        let fields = ["input":"input_cost_per_token","cacheRead":"cache_read_input_token_cost","cacheWrite":"cache_creation_input_token_cost","cacheWrite1h":"cache_creation_input_token_cost_above_1hr","output":"output_cost_per_token"]
        var models: MObject = [:]
        for (id, value) in raw {
            guard let e = value as? MObject, ["anthropic","openai"].contains(e["litellm_provider"] as? String ?? ""), ["chat","responses"].contains(e["mode"] as? String ?? ""), !id.contains("/") else { continue }
            var p: MObject = [:]
            for (ours, theirs) in fields { if let n = e[theirs] as? NSNumber { p[ours] = n.doubleValue * 1e6 } }
            // Long-context tier, e.g. `input_cost_per_token_above_272k_tokens`; the 1h-write variant is `..._above_1hr_above_200k_tokens`.
            if let k = e.keys.first(where: { $0.hasPrefix("input_cost_per_token_above_") && $0.hasSuffix("k_tokens") }),
               let n = Double(k.dropFirst("input_cost_per_token_above_".count).dropLast("k_tokens".count)) {
                let suffix = "_above_\(Int(n))k_tokens"
                p["longAbove"] = n * 1000
                for (ours, theirs) in fields { if let v = e[theirs + suffix] as? NSNumber { p["long" + ours.prefix(1).uppercased() + ours.dropFirst()] = v.doubleValue * 1e6 } }
            }
            let input = (e["input_cost_per_token"] as? NSNumber)?.doubleValue ?? 0
            if let fast = (e["provider_specific_entry"] as? MObject)?["fast"] as? NSNumber { p["fastMultiplier"] = fast.doubleValue }
            else if input > 0, let pr = e["input_cost_per_token_priority"] as? NSNumber { p["fastMultiplier"] = pr.doubleValue / input }
            if input > 0, let flex = e["input_cost_per_token_flex"] as? NSNumber { p["flexMultiplier"] = flex.doubleValue / input }
            if valid(p) { models[id] = p }
        }
        return models
    }

    /// Called from the monitor tick; at most one fetch in flight, daily on success, hourly retry on failure.
    static func refreshIfDue(now: Double = Date().timeIntervalSince1970) {
        lock.lock()
        if fetchedAt == nil { fetchedAt = MonitorIO.number(MonitorIO.read(remotePath)["fetchedAt"]) }
        guard !inFlight, now - fetchedAt! >= refreshInterval, now - lastAttempt >= retryInterval else { lock.unlock(); return }
        inFlight = true; lastAttempt = now; lock.unlock()
        var req = URLRequest(url: remoteURL); req.timeoutInterval = 30
        if let etag = MonitorIO.read(remotePath)["etag"] as? String { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { lock.lock(); inFlight = false; lock.unlock() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var cache = MonitorIO.read(remotePath)
            if status == 304, !cache.isEmpty { cache["fetchedAt"] = now; try? MonitorIO.atomic(cache, remotePath); lock.lock(); fetchedAt = now; lock.unlock(); return }
            guard error == nil, status == 200, let data, data.count < 64 << 20,
                  let raw = (try? JSONSerialization.jsonObject(with: data)) as? MObject else { GALog.log("pricing refresh failed: \(error?.localizedDescription ?? "HTTP \(status)")"); return }
            let models = convert(raw)
            // A truncated or reshaped upstream file must not wipe a good cache.
            guard models.count >= 10 else { GALog.log("pricing refresh rejected: only \(models.count) models"); return }
            let stamp = ISO8601DateFormatter.string(from: Date(timeIntervalSince1970: now), timeZone: .init(identifier: "UTC")!, formatOptions: [.withFullDate])
            var out: MObject = ["version": stamp, "source": remoteURL.absoluteString, "fetchedAt": now, "models": models]
            if let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") { out["etag"] = etag }
            guard (try? MonitorIO.atomic(out, remotePath)) != nil else { return }
            lock.lock(); fetchedAt = now; lock.unlock()
        }.resume()
    }
}
