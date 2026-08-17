import SwiftUI
import AppKit
import UserNotifications

// MARK: - 入口（支持 --once 命令行模式用于自检）

@main
struct Main {
  static func main() {
    if CommandLine.arguments.contains("--once") {
      runCLI()
    } else {
      SeekBalanceApp.main()
    }
  }

  /// 命令行自检：打印一次报告后退出（用于验证数据管线）
  static func runCLI() {
    let semaphore = DispatchSemaphore(value: 0)
    var rep: Report?
    Task {
      rep = await buildReport()
      semaphore.signal()
    }
    semaphore.wait()
    printReport(rep ?? Report(balance: nil, balanceError: "报告生成失败", totals: Totals(), today: TodayUsage(), costCurrent: 0, todayCost: 0, cumCost: 0, updatedAt: Date(), model: "?"))
    exit(0)
  }

  static func printReport(_ r: Report) {
    print("DeepSeek 用量 & 余额报告（\(r.model)）")
    print("==================================================")
    if let b = r.balance {
      print("余额: ¥\(String(format: "%.2f", b.total))（充值 ¥\(String(format: "%.2f", b.toppedUp)) / 赠送 ¥\(String(format: "%.2f", b.granted))）")
    } else {
      print("余额: 查询失败 - \(r.balanceError ?? "未知错误")")
    }
    let p = currentPeriodInfo()
    print("当前时段: \(p.currentRange)（距离\(p.isPeakNow ? "高峰" : "空闲")结束\(fmtCountdown(p.secondsUntilNext))）")
    if let np = nextPeakStart(after: Date()) {
      var cal = Calendar(identifier: .gregorian)
      cal.timeZone = Prices.beijing
      let hh = cal.component(.hour, from: np)
      let mm = cal.component(.minute, from: np)
      let remind = UserDefaults.standard.bool(forKey: "peakReminderEnabled")
      let mins = UserDefaults.standard.integer(forKey: "peakReminderMinutes")
      print("下一高峰: \(String(format: "%02d:%02d", hh, mm))（提醒: \(remind ? "提前 \(mins) 分钟" : "关闭")）")
    }
    let t = r.totals
    print("累计: 输入(未命中) \(fmtTokens(t.uncachedInput)) / 缓存命中 \(fmtTokens(t.cacheRead)) / 输出 \(fmtTokens(t.output))")
    if r.today.calls > 0 {
      print("今日: \(r.today.calls) 次请求, 输入(未命中) \(fmtTokens(r.today.uncachedInput)), 缓存 \(fmtTokens(r.today.cacheRead)), 输出 \(fmtTokens(r.today.output))")
      print("今日高峰/空闲用量: \(fmtTokens(r.today.peakTokens)) / \(fmtTokens(r.today.offpeakTokens))")
      print("今日花费(按请求时间精确): ¥\(String(format: "%.4f", r.todayCost))")
    } else {
      print("今日: 暂无请求记录")
    }
    print("累计花费(按请求时间精确): ¥\(String(format: "%.4f", r.cumCost))")
    print("累计花费(老价估算·参考): ¥\(String(format: "%.4f", r.costCurrent))")
  }
}

// MARK: - 格式化

func fmtTokens(_ n: Int64) -> String {
  let d = Double(n)
  if d >= 1e9 { return String(format: "%.2f B", d / 1e9) }
  if d >= 1e6 { return String(format: "%.2f M", d / 1e6) }
  if d >= 1e3 { return String(format: "%.1f K", d / 1e3) }
  return "\(n)"
}

func fmtYuan(_ n: Double) -> String {
  return "¥" + String(format: "%.4f", n)
}

/// 倒计时显示："还有 X 小时 Y 分"
func fmtCountdown(_ seconds: TimeInterval) -> String {
  let total = Int(seconds.rounded())
  let h = total / 3600
  let m = (total % 3600) / 60
  if h > 0 { return "还有 \(h) 小时 \(m) 分" }
  if m > 0 { return "还有 \(m) 分钟" }
  return "即将切换"
}

/// 请求系统通知权限（首次开启提醒时弹出系统授权框）
func requestNotificationPermission() {
  UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
}

// MARK: - 模型

@MainActor
final class BalanceModel: ObservableObject {
  @Published var balance: Balance?
  @Published var balanceError: String?
  @Published var totals = Totals()
  @Published var today = TodayUsage()
  @Published var costCurrent: Double = 0
  @Published var todayCost: Double = 0
  @Published var cumCost: Double = 0
  @Published var lastUpdated: Date?
  @Published var loading = false
  // 密钥相关：缺失时面板显示粘贴框；apiKeyInput 是用户输入的密钥
  @Published var keyMissing = false
  @Published var apiKeyInput = ""
  private var timer: Timer?
  private var reminderTimer: Timer?

  init() {
    // 提醒定时器应用启动即运行，不依赖面板打开
    startReminderTimer()
  }

  /// 高峰前提醒：每 30 秒检查一次，进入提醒窗口（空闲时段且距下一高峰 ≤ 设定分钟）就发通知
  func startReminderTimer() {
    if UserDefaults.standard.bool(forKey: "peakReminderEnabled") {
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    reminderTimer?.invalidate()
    reminderTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.checkPeakReminder() }
    }
    checkPeakReminder()
  }

  func checkPeakReminder() {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: "peakReminderEnabled") else { return }
    // 只在空闲时段提醒（高峰中不打扰）
    let period = currentPeriodInfo()
    guard !period.isPeakNow else { return }
    let minutes = defaults.integer(forKey: "peakReminderMinutes")
    guard minutes >= 0, minutes <= 60 else { return }
    guard let nextPeak = nextPeakStart(after: Date()) else { return }
    let interval = nextPeak.timeIntervalSinceNow
    guard interval > 0 else { return }
    let window = minutes == 0 ? 30.0 : Double(minutes) * 60
    guard interval <= window else { return }
    // 同一波高峰只提醒一次
    let lastNotified = defaults.double(forKey: "peakReminderLastNotified")
    guard abs(nextPeak.timeIntervalSince1970 - lastNotified) > 60 else { return }
    defaults.set(nextPeak.timeIntervalSince1970, forKey: "peakReminderLastNotified")
    sendPeakReminder(minutesUntil: max(0, Int(interval / 60)), peakStart: nextPeak)
  }

  private func sendPeakReminder(minutesUntil: Int, peakStart: Date) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = Prices.beijing
    let hour = cal.component(.hour, from: peakStart)
    let range = hour == 9 ? "9:00–12:00" : "14:00–18:00"
    let content = UNMutableNotificationContent()
    content.title = "⏰ 高峰时段快到了"
    content.body = minutesUntil > 0
      ? "还有 \(minutesUntil) 分钟进入高峰（\(range)），价格将上调。要省钱的话现在抓紧！"
      : "高峰时段（\(range)）即将开始，价格已上调。"
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "peak-reminder-\(Int(peakStart.timeIntervalSince1970))",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
  }

  var balanceText: String {
    if let b = balance { return String(format: "¥%.2f", b.total) }
    return balanceError == nil ? "💳 ¥--" : "💳 ?"
  }

  func start() {
    refresh()
    timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
  }

  func refresh() {
    guard !loading else { return }
    loading = true
    Task {
      let rep = await buildReport()
      self.balance = rep.balance
      self.balanceError = rep.balanceError
      self.totals = rep.totals
      self.today = rep.today
      self.costCurrent = rep.costCurrent
      self.todayCost = rep.todayCost
      self.cumCost = rep.cumCost
      self.lastUpdated = rep.updatedAt
      self.loading = false
      self.keyMissing = DS.apiKey() == nil
    }
  }

  /// 保存用户粘贴的密钥到本机钥匙串，然后刷新
  func saveAPIKey() {
    let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return }
    if Keychain.saveAPIKey(key) {
      apiKeyInput = ""
      keyMissing = false
      refresh()
    }
  }
}

// MARK: - 应用（窗口式弹层：实心背景 + 显式标签色，彻底脱离磨砂玻璃；紧凑布局）

struct SeekBalanceApp: App {
  @StateObject private var model = BalanceModel()
  // 开关记忆：状态栏是否显示余额数字（UserDefaults 持久化）
  @AppStorage("showBalanceText") private var showBalanceText = true

  var body: some Scene {
    MenuBarExtra {
      BalancePanelView(model: model, showBalanceText: $showBalanceText)
        .frame(width: 260)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "creditcard")
        if showBalanceText {
          Text(model.balanceText)
            .font(.system(size: 12, weight: .medium))
        }
      }
    }
    .menuBarExtraStyle(.window)
  }
}

struct BalancePanelView: View {
  @ObservedObject var model: BalanceModel
  @Binding var showBalanceText: Bool
  @AppStorage("peakReminderEnabled") private var reminderEnabled = false
  @AppStorage("peakReminderMinutes") private var reminderMinutes = 15

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("💳 SeekBalance · 用量 & 余额")
        .font(.system(size: 12, weight: .semibold))
        .padding(.bottom, 2)

      if let b = model.balance {
        row("余额", String(format: "¥%.2f", b.total), bold: true)
        row("充值 / 赠送", String(format: "¥%.2f / ¥%.2f", b.toppedUp, b.granted))
      } else {
        row("余额", "查询失败", bold: true)
        if let err = model.balanceError {
          Text(err).font(.system(size: 9)).foregroundColor(.red).lineLimit(3).padding(.top, 1)
        }
      }

      // 首次使用：没有密钥时显示粘贴框（存入本机钥匙串）
      if model.keyMissing {
        Divider().padding(.vertical, 2)
        Text("🔑 粘贴你的 DeepSeek API 密钥：")
          .font(.system(size: 10))
        SecureField("sk-…", text: $model.apiKeyInput)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
        HStack(spacing: 8) {
          Button("保存并刷新") { model.saveAPIKey() }
            .controlSize(.small)
            .disabled(model.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Spacer()
          Text("仅存本机钥匙串").font(.system(size: 9)).foregroundColor(.secondary)
        }
        .padding(.top, 2)
      }

      Divider().padding(.vertical, 2)

      // 当前时段：高峰/空闲 + 距当前时段结束的倒计时
      // 颜色：第一行=当前状态色（空闲绿/高峰红）；第二行=警示色——
      // 空闲时段剩 ≤30 分钟变红（提醒抓紧用），其余时间绿；高峰时段恒绿（高峰快结束=宽慰）
      let period = currentPeriodInfo()
      let warnSoon = !period.isPeakNow && period.secondsUntilNext <= 30 * 60
      row("当前时段", period.currentRange, valueColor: period.isPeakNow ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen))
      row("距离\(period.isPeakNow ? "高峰" : "空闲")结束", fmtCountdown(period.secondsUntilNext), valueColor: warnSoon ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen))

      // 高峰前提醒设置：开启后按设定分钟数提前发系统通知
      Toggle("高峰前提醒", isOn: $reminderEnabled)
        .controlSize(.small)
        .padding(.vertical, 1)
        .onChange(of: reminderEnabled) { enabled in
          if enabled { requestNotificationPermission() }
        }
      if reminderEnabled {
        Stepper(reminderMinutes == 0 ? "高峰开始时提醒" : "提前 \(reminderMinutes) 分钟提醒", value: $reminderMinutes, in: 0...60)
          .controlSize(.small)
          .padding(.vertical, 1)
      }

      Divider().padding(.vertical, 2)

      if model.today.calls > 0 {
        row("今日请求", "\(model.today.calls) 次")
        row("今日输入", "\(fmtTokens(model.today.uncachedInput)) + 缓存\(fmtTokens(model.today.cacheRead))")
        row("今日输出", fmtTokens(model.today.output))
        row("高峰/空闲用量", "\(fmtTokens(model.today.peakTokens)) / \(fmtTokens(model.today.offpeakTokens))")
        row("今日花费", fmtYuan(model.today.cost), bold: true)
        Divider().padding(.vertical, 2)
      }

      row("累计输入", "\(fmtTokens(model.totals.uncachedInput)) + 缓存\(fmtTokens(model.totals.cacheRead))")
      row("累计输出", fmtTokens(model.totals.output))
      row("累计花费", fmtYuan(model.cumCost), bold: true)

      // 备注：今日/累计用量都只算本机（DeepSeek 无公开用量接口，全账户用量查不到）
      Text("注：今日/累计用量均仅统计这台电脑（余额为全账户）")
        .font(.system(size: 9))
        .foregroundColor(Color(nsColor: .secondaryLabelColor))
        .padding(.top, 2)

      Divider().padding(.vertical, 2)

      Toggle("状态栏显示余额", isOn: $showBalanceText)
        .controlSize(.small)
        .padding(.vertical, 1)

      HStack(spacing: 12) {
        Button("🔄 刷新") { model.refresh() }
        Button("退出") { NSApp.terminate(nil) }
      }
      .controlSize(.small)
      .padding(.top, 1)

      if let t = model.lastUpdated {
        Text("更新于 " + t.formatted(date: .omitted, time: .standard))
          .font(.system(size: 9))
          .foregroundColor(.secondary)
          .padding(.top, 1)
      }
    }
    .padding(10)
    .font(.system(size: 11))
    // 实心背景 + 系统标签色：浅色=黑字/白底，深色=白字/黑底，永远可读
    .background(Color(nsColor: .windowBackgroundColor))
    .foregroundColor(Color(nsColor: .labelColor))
    .onAppear { model.start() }
  }

  private func row(_ k: String, _ v: String, bold: Bool = false, valueColor: Color? = nil) -> some View {
    HStack(spacing: 6) {
      Text(k).foregroundColor(Color(nsColor: .secondaryLabelColor))
      Spacer(minLength: 4)
      Text(v)
        .fontWeight(bold ? .semibold : .regular)
        .foregroundColor(valueColor)
    }
    .padding(.vertical, 1)
  }
}

struct BalanceMenuView: View {
  @ObservedObject var model: BalanceModel
  @AppStorage("peakReminderEnabled") private var reminderEnabled = false
  @AppStorage("peakReminderMinutes") private var reminderMinutes = 15

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("💳 SeekBalance · 用量 & 余额")
        .font(.system(size: 12, weight: .semibold))
        .padding(.vertical, 3)

      if let b = model.balance {
        row("余额", String(format: "¥%.2f", b.total), bold: true)
        row("充值 / 赠送", String(format: "¥%.2f / ¥%.2f", b.toppedUp, b.granted))
      } else {
        row("余额", "查询失败", bold: true)
        if let err = model.balanceError {
          Text(err).font(.system(size: 10)).foregroundColor(.red).lineLimit(2)
        }
      }

      if model.keyMissing {
        Divider().padding(.vertical, 2)
        Text("🔑 粘贴你的 DeepSeek API 密钥：")
          .font(.system(size: 10))
        SecureField("sk-…", text: $model.apiKeyInput)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
        Button("保存并刷新") { model.saveAPIKey() }
          .controlSize(.small)
          .disabled(model.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Text("仅存本机钥匙串").font(.system(size: 9)).foregroundColor(.secondary)
      }

      Divider().padding(.vertical, 2)

      // 当前时段：高峰/空闲 + 距当前时段结束的倒计时
      // 颜色：第一行=当前状态色（空闲绿/高峰红）；第二行=警示色——
      // 空闲时段剩 ≤30 分钟变红（提醒抓紧用），其余时间绿；高峰时段恒绿（高峰快结束=宽慰）
      let period = currentPeriodInfo()
      let warnSoon = !period.isPeakNow && period.secondsUntilNext <= 30 * 60
      row("当前时段", period.currentRange, valueColor: period.isPeakNow ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen))
      row("距离\(period.isPeakNow ? "高峰" : "空闲")结束", fmtCountdown(period.secondsUntilNext), valueColor: warnSoon ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen))

      // 高峰前提醒设置：开启后按设定分钟数提前发系统通知
      Toggle("高峰前提醒", isOn: $reminderEnabled)
        .controlSize(.small)
        .padding(.vertical, 1)
        .onChange(of: reminderEnabled) { enabled in
          if enabled { requestNotificationPermission() }
        }
      if reminderEnabled {
        Stepper(reminderMinutes == 0 ? "高峰开始时提醒" : "提前 \(reminderMinutes) 分钟提醒", value: $reminderMinutes, in: 0...60)
          .controlSize(.small)
          .padding(.vertical, 1)
      }

      Divider().padding(.vertical, 2)

      if model.today.calls > 0 {
        row("今日请求", "\(model.today.calls) 次")
        row("今日输入", "\(fmtTokens(model.today.uncachedInput)) + 缓存\(fmtTokens(model.today.cacheRead))")
        row("今日输出", fmtTokens(model.today.output))
        row("高峰/空闲用量", "\(fmtTokens(model.today.peakTokens)) / \(fmtTokens(model.today.offpeakTokens))")
        row("今日花费", fmtYuan(model.today.cost), bold: true)
        Divider().padding(.vertical, 2)
      }

      row("累计输入", "\(fmtTokens(model.totals.uncachedInput)) + 缓存\(fmtTokens(model.totals.cacheRead))")
      row("累计输出", fmtTokens(model.totals.output))
      row("累计花费", fmtYuan(model.cumCost), bold: true)

      Text("注：今日/累计用量均仅统计这台电脑（余额为全账户）")
        .font(.system(size: 9))
        .foregroundColor(Color(nsColor: .secondaryLabelColor))
        .padding(.top, 2)

      Divider().padding(.vertical, 2)

      HStack(spacing: 10) {
        Button("🔄 刷新") { model.refresh() }
        Button("退出") { NSApp.terminate(nil) }
      }
      .controlSize(.small)
      .padding(.top, 2)

      if let t = model.lastUpdated {
        Text("更新于 " + t.formatted(date: .omitted, time: .standard))
          .font(.system(size: 9))
          .padding(.top, 2)
      }
    }
    .padding(8)
    .font(.system(size: 11))
    // 实心背景：避免磨砂玻璃（vibrancy）导致文字难读
    .background(Color(nsColor: .windowBackgroundColor))
    // 系统标签色：浅色模式=黑、深色模式=白，自动适配
    .foregroundColor(Color(nsColor: .labelColor))
    .onAppear { model.start() }
  }

  private func row(_ k: String, _ v: String, bold: Bool = false, valueColor: Color? = nil) -> some View {
    HStack(spacing: 6) {
      Text(k).lineLimit(1)
      Spacer(minLength: 4)
      Text(v)
        .fontWeight(bold ? .semibold : .regular)
        .foregroundColor(valueColor)
        .lineLimit(1)
    }
    .padding(.vertical, 0.5)
  }
}
