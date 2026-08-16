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
  var cost: Double = 0 // 今日花费（按每次请求的时间精确计价）
  var peakTokens: Int64 = 0 // 今日高峰时段用量（输入+缓存+输出）
  var offpeakTokens: Int64 = 0 // 今日空闲时段用量
}

struct Report {
  var balance: Balance?
  var balanceError: String?
  var totals: Totals
  var today: TodayUsage
  var costCurrent: Double   // 累计·老价估算（仅参考）
  var todayCost: Double     // 今日·按请求时间精确
  var cumCost: Double       // 累计·按请求时间精确
  var updatedAt: Date
  var model: String
}

// MARK: - 价格（元 / 百万 tokens，deepseek-v4-flash）

enum Prices {
  static let current = (cacheHit: 0.02, cacheMiss: 1.0, output: 2.0) // 老价（2026-08-17 前）
  static let offpeak = (cacheHit: 0.05, cacheMiss: 1.5, output: 4.5) // 现价·空闲（8/17 起）
  static let peak = (cacheHit: 0.10, cacheMiss: 3.0, output: 9.0) // 现价·高峰（8/17 起）

  /// 高峰时段（北京时间）：每日 9:00–12:00、14:00–18:00；其余为空闲时段
  static func isPeak(_ minutes: Int) -> Bool {
    return (minutes >= 9 * 60 && minutes < 12 * 60)
      || (minutes >= 14 * 60 && minutes < 18 * 60)
  }
  static let beijing = TimeZone(identifier: "Asia/Shanghai")!

  /// 新价格生效时刻：北京时间 2026-08-17 00:00
  static let newPriceDate: Date = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = beijing
    return cal.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 0))!
  }()

  /// 请求时刻的北京时间分钟数（0–1439）
  static func beijingMinutes(for timeMs: Double) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = beijing
    let comps = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: timeMs / 1000))
    return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
  }

  /// 按请求时间取价：8/17 0 点前用老价；之后按请求时刻判断高峰（9-12、14-18）/空闲
  static func price(for timeMs: Double) -> (cacheHit: Double, cacheMiss: Double, output: Double) {
    let date = Date(timeIntervalSince1970: timeMs / 1000)
    guard date >= newPriceDate else { return current }
    return isPeak(beijingMinutes(for: timeMs)) ? peak : offpeak
  }
}

// MARK: - 时段状态（高峰/空闲）

struct PeriodInfo {
  var isPeakNow: Bool
  var currentRange: String      // 如 "高峰 9:00–12:00"
  var nextIsPeak: Bool          // 下一个切换到的状态是否高峰
  var secondsUntilNext: TimeInterval
}

/// 当前时段信息（北京时间）：高峰 9:00–12:00、14:00–18:00，其余空闲
func currentPeriodInfo(now: Date = Date()) -> PeriodInfo {
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = Prices.beijing
  let comps = cal.dateComponents([.hour, .minute], from: now)
  let minutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
  // 时段边界：09:00=540, 12:00=720, 14:00=840, 18:00=1080
  let isPeak: Bool
  let rangeText: String
  let nextBoundary: Int
  let nextIsPeak: Bool
  if minutes < 540 { // 00:00–09:00 空闲 → 下一变化：09:00 转高峰
    isPeak = false
    rangeText = "空闲 00:00–09:00"
    nextBoundary = 540
    nextIsPeak = true
  } else if minutes < 720 { // 09:00–12:00 高峰 → 12:00 转空闲
    isPeak = true
    rangeText = "高峰 09:00–12:00"
    nextBoundary = 720
    nextIsPeak = false
  } else if minutes < 840 { // 12:00–14:00 空闲 → 14:00 转高峰
    isPeak = false
    rangeText = "空闲 12:00–14:00"
    nextBoundary = 840
    nextIsPeak = true
  } else if minutes < 1080 { // 14:00–18:00 高峰 → 18:00 转空闲
    isPeak = true
    rangeText = "高峰 14:00–18:00"
    nextBoundary = 1080
    nextIsPeak = false
  } else { // 18:00–24:00 空闲 → 下一变化：明天 09:00 转高峰
    isPeak = false
    rangeText = "空闲 18:00–24:00"
    nextBoundary = 540 + 1440
    nextIsPeak = true
  }
  return PeriodInfo(
    isPeakNow: isPeak,
    currentRange: rangeText,
    nextIsPeak: nextIsPeak,
    secondsUntilNext: TimeInterval(nextBoundary - minutes) * 60
  )
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

  /// 一次扫描全部会话日志：今日精确用量（含按请求时间精确计价的花费）+ 累计精确花费
  /// （8/17 0 点前的请求按老价，之后按请求时刻的高峰/空闲价）
  static func readTodayAndCumulativeCost() -> (today: TodayUsage, cumCost: Double) {
    var today = TodayUsage()
    var cumCost = 0.0
    let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
    let fm = FileManager.default
    guard let wsDirs = try? fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil) else { return (today, cumCost) }
    for ws in wsDirs {
      guard let sessionDirs = try? fm.contentsOfDirectory(at: ws, includingPropertiesForKeys: nil) else { continue }
      for sdir in sessionDirs {
        let log = sdir.appendingPathComponent("session.jsonl.zstd")
        guard fm.fileExists(atPath: log.path), let text = zstdDecompress(path: log.path) else { continue }
        for line in text.split(separator: "\n") {
          guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            (obj["type"] as? String) == "assistant/message"
          else { continue }
          guard let time = obj["time"] as? NSNumber,
            let data = obj["data"] as? [String: Any],
            let usage = data["usage"] as? [String: Any]
          else { continue }
          let timeMs = time.doubleValue
          let uncached = (usage["inputTokens"] as? NSNumber)?.int64Value ?? 0
          let cacheRead = (usage["cacheReadTokens"] as? NSNumber)?.int64Value ?? 0
          let output = (usage["outputTokens"] as? NSNumber)?.int64Value ?? 0
          let p = Prices.price(for: timeMs)
          cumCost += Double(uncached) / 1e6 * p.cacheMiss
            + Double(cacheRead) / 1e6 * p.cacheHit
            + Double(output) / 1e6 * p.output
          guard timeMs >= midnight else { continue }
          today.calls += 1
          today.uncachedInput += uncached
          today.output += output
          today.cacheRead += cacheRead
          today.reasoning += (usage["reasoningTokens"] as? NSNumber)?.int64Value ?? 0
          today.cost += Double(uncached) / 1e6 * p.cacheMiss
            + Double(cacheRead) / 1e6 * p.cacheHit
            + Double(output) / 1e6 * p.output
          if Prices.isPeak(Prices.beijingMinutes(for: timeMs)) {
            today.peakTokens += uncached + cacheRead + output
          } else {
            today.offpeakTokens += uncached + cacheRead + output
          }
        }
      }
    }
    return (today, cumCost)
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
  let scan = DS.readTodayAndCumulativeCost()
  var rep = Report(
    balance: nil,
    balanceError: nil,
    totals: DS.readTotals(),
    today: scan.today,
    costCurrent: 0,
    todayCost: scan.today.cost,
    cumCost: scan.cumCost,
    updatedAt: Date(),
    model: "deepseek-v4-flash"
  )
  let t = rep.totals
  rep.costCurrent = Double(t.uncachedInput) / 1e6 * Prices.current.cacheMiss
    + Double(t.cacheRead) / 1e6 * Prices.current.cacheHit
    + Double(t.output) / 1e6 * Prices.current.output

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
