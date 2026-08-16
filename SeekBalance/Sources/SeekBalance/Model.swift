import Foundation

// MARK: - 数据模型

struct Balance: Codable {
  var currency: String = "CNY"
  var total: Double = 0
  var granted: Double = 0
  var toppedUp: Double = 0
}

struct Totals {
  var uncachedInput: Int64 = 0
  var cacheRead: Int64 = 0
  var output: Int64 = 0
}

struct TodayUsage {
  var calls: Int = 0
  var uncachedInput: Int64 = 0
  var cacheRead: Int64 = 0
  var output: Int64 = 0
  var reasoning: Int64 = 0
}

struct Report {
  var balance: Balance?
  var balanceError: String?
  var totals: Totals
  var today: TodayUsage
  var costCurrent: Double
  var costOffpeak: Double
  var costPeak: Double
  var updatedAt: Date
  var model: String
}

// MARK: - 价格（元 / 百万 tokens，deepseek-v4-flash）

enum Prices {
  static let current = (cacheHit: 0.02, cacheMiss: 1.0, output: 2.0) // 老价（2026-08-17 前）
  static let offpeak = (cacheHit: 0.05, cacheMiss: 1.5, output: 4.5) // 现价·空闲（8/17 起）
  static let peak = (cacheHit: 0.10, cacheMiss: 3.0, output: 9.0) // 现价·高峰（8/17 起）
}

// MARK: - 数据获取

enum DS {
  static let home = FileManager.default.homeDirectoryForCurrentUser
  static var credentialsPath: URL { home.appendingPathComponent(".dsh/.credentials.yaml") }
  static var projCachePath: URL { home.appendingPathComponent(".dsh/storages/session_projcache.json") }
  static var sessionsRoot: URL { home.appendingPathComponent(".dsh/sessions") }

  /// 读取 DEEPSEEK_API_KEY：优先 dsh 配置文件（老用户），其次本机钥匙串（普通用户粘贴）
  static func apiKey() -> String? {
    if let key = configAPIKey() { return key }
    return Keychain.loadAPIKey()
  }

  /// 从 ~/.dsh/.credentials.yaml 读取（与 dsh 共用同一密钥）
  private static func configAPIKey() -> String? {
    guard let content = try? String(contentsOf: credentialsPath, encoding: .utf8) else { return nil }
    for line in content.split(separator: "\n") {
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("DEEPSEEK_API_KEY") {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
          let key = parts[1].trimmingCharacters(in: .whitespaces)
          return key.isEmpty ? nil : key
        }
      }
    }
    return nil
  }

  /// 余额：GET https://api.deepseek.com/user/balance
  static func fetchBalance(key: String) async throws -> Balance {
    var req = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 15
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
      throw NSError(domain: "balance", code: -1, userInfo: [NSLocalizedDescriptionKey: "余额接口 HTTP 异常"])
    }
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let infos = obj?["balance_infos"] as? [[String: Any]], let b = infos.first else {
      throw NSError(domain: "balance", code: -2, userInfo: [NSLocalizedDescriptionKey: "余额接口未返回数据"])
    }
    // 注意：DeepSeek 接口的余额字段是字符串（如 "8.62"），不能按 NSNumber 解析
    func toDouble(_ v: Any?) -> Double {
      if let n = v as? NSNumber { return n.doubleValue }
      if let s = v as? String { return Double(s) ?? 0 }
      return 0
    }
    return Balance(
      currency: (b["currency"] as? String) ?? "CNY",
      total: toDouble(b["total_balance"]),
      granted: toDouble(b["granted_balance"]),
      toppedUp: toDouble(b["topped_up_balance"])
    )
  }

  /// 累计用量：~/.dsh/storages/session_projcache.json -> tokenUsage.totals
  static func readTotals() -> Totals {
    guard let data = try? Data(contentsOf: projCachePath),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return Totals() }
    var out = Totals()
    guard let tables = obj["tables"] as? [String: Any],
      let sessions = tables["sessions"] as? [String: Any]
    else { return out }
    for (_, s) in sessions {
      guard let s = s as? [String: Any],
        let rows = s["rows"] as? [String: Any],
        let tu = rows["tokenUsage"] as? [String: Any],
        let val = tu["val"] as? [String: Any],
        let totals = val["totals"] as? [String: Any]
      else { continue }
      out.uncachedInput += (totals["uncachedInputTokens"] as? NSNumber)?.int64Value ?? 0
      out.cacheRead += (totals["cacheReadTokens"] as? NSNumber)?.int64Value ?? 0
      out.output += (totals["outputTokens"] as? NSNumber)?.int64Value ?? 0
    }
    return out
  }

  /// 今日精确用量：解析会话日志（zstd JSONL），统计本地零点起的 assistant/message usage
  static func readToday() -> TodayUsage {
    var out = TodayUsage()
    let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
    let fm = FileManager.default
    guard let wsDirs = try? fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil) else { return out }
    for ws in wsDirs {
      guard let sessionDirs = try? fm.contentsOfDirectory(at: ws, includingPropertiesForKeys: nil) else { continue }
      for sdir in sessionDirs {
        let log = sdir.appendingPathComponent("session.jsonl.zstd")
        guard fm.fileExists(atPath: log.path), let text = zstdDecompress(path: log.path) else { continue }
        for line in text.split(separator: "\n") {
          guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            (obj["type"] as? String) == "assistant/message"
          else { continue }
          guard let time = obj["time"] as? NSNumber, time.doubleValue >= midnight else { continue }
          guard let data = obj["data"] as? [String: Any],
            let usage = data["usage"] as? [String: Any]
          else { continue }
          out.calls += 1
          out.uncachedInput += (usage["inputTokens"] as? NSNumber)?.int64Value ?? 0
          out.output += (usage["outputTokens"] as? NSNumber)?.int64Value ?? 0
          out.cacheRead += (usage["cacheReadTokens"] as? NSNumber)?.int64Value ?? 0
          out.reasoning += (usage["reasoningTokens"] as? NSNumber)?.int64Value ?? 0
        }
      }
    }
    return out
  }

  /// 定位 zstd 可执行文件（不同机器安装位置不同，兼容常见路径）
  private static func zstdExecutable() -> String? {
    let candidates = [
      "/opt/homebrew/bin/zstd", // Apple Silicon 的 Homebrew
      "/usr/local/bin/zstd",    // Intel Mac 的 Homebrew
      "/usr/bin/zstd",          // 系统自带（若有）
    ]
    for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
      return p
    }
    return nil
  }

  private static func zstdDecompress(path: String) -> String? {
    guard let zstd = zstdExecutable() else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: zstd)
    process.arguments = ["-dc", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return nil
    }
    // 必须先读完管道再 wait：zstd 解压输出很大，若先 wait 会因管道缓冲
    // 填满而死锁（readDataToEndOfFile 阻塞到 EOF，同时持续排空管道）。
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)
  }
}

// MARK: - 报告组装

func buildReport() async -> Report {
  var rep = Report(
    balance: nil,
    balanceError: nil,
    totals: DS.readTotals(),
    today: DS.readToday(),
    costCurrent: 0,
    costOffpeak: 0,
    costPeak: 0,
    updatedAt: Date(),
    model: "deepseek-v4-flash"
  )
  let t = rep.totals
  rep.costCurrent = Double(t.uncachedInput) / 1e6 * Prices.current.cacheMiss
    + Double(t.cacheRead) / 1e6 * Prices.current.cacheHit
    + Double(t.output) / 1e6 * Prices.current.output
  rep.costOffpeak = Double(t.uncachedInput) / 1e6 * Prices.offpeak.cacheMiss
    + Double(t.cacheRead) / 1e6 * Prices.offpeak.cacheHit
    + Double(t.output) / 1e6 * Prices.offpeak.output
  rep.costPeak = Double(t.uncachedInput) / 1e6 * Prices.peak.cacheMiss
    + Double(t.cacheRead) / 1e6 * Prices.peak.cacheHit
    + Double(t.output) / 1e6 * Prices.peak.output

  if let key = DS.apiKey() {
    do {
      rep.balance = try await DS.fetchBalance(key: key)
    } catch {
      rep.balanceError = error.localizedDescription
    }
  } else {
    rep.balanceError = "未找到 DEEPSEEK_API_KEY"
  }
  return rep
}
