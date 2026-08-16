import SwiftUI
import AppKit

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
    printReport(rep ?? Report(balance: nil, balanceError: "报告生成失败", totals: Totals(), today: TodayUsage(), costCurrent: 0, costOffpeak: 0, costPeak: 0, updatedAt: Date(), model: "?"))
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
    let t = r.totals
    print("累计: 输入(未命中) \(fmtTokens(t.uncachedInput)) / 缓存命中 \(fmtTokens(t.cacheRead)) / 输出 \(fmtTokens(t.output))")
    if r.today.calls > 0 {
      print("今日: \(r.today.calls) 次请求, 输入(未命中) \(fmtTokens(r.today.uncachedInput)), 缓存 \(fmtTokens(r.today.cacheRead)), 输出 \(fmtTokens(r.today.output))")
      print("今日估算花费(现价·空闲/高峰): ¥\(String(format: "%.4f", todayCostOffpeak(r.today))) / ¥\(String(format: "%.4f", todayCostPeak(r.today)))")
    } else {
      print("今日: 暂无请求记录")
    }
    print("累计花费(老价估算): ¥\(String(format: "%.4f", r.costCurrent))")
    print("累计花费(现价·空闲/高峰): ¥\(String(format: "%.4f", r.costOffpeak)) / ¥\(String(format: "%.4f", r.costPeak))")
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

/// 今日花费（现价·空闲 / 高峰）
func todayCostOffpeak(_ today: TodayUsage) -> Double {
  return Double(today.uncachedInput) / 1e6 * Prices.offpeak.cacheMiss
    + Double(today.cacheRead) / 1e6 * Prices.offpeak.cacheHit
    + Double(today.output) / 1e6 * Prices.offpeak.output
}

func todayCostPeak(_ today: TodayUsage) -> Double {
  return Double(today.uncachedInput) / 1e6 * Prices.peak.cacheMiss
    + Double(today.cacheRead) / 1e6 * Prices.peak.cacheHit
    + Double(today.output) / 1e6 * Prices.peak.output
}

// MARK: - 模型

@MainActor
final class BalanceModel: ObservableObject {
  @Published var balance: Balance?
  @Published var balanceError: String?
  @Published var totals = Totals()
  @Published var today = TodayUsage()
  @Published var costCurrent: Double = 0
  @Published var costOffpeak: Double = 0
  @Published var costPeak: Double = 0
  @Published var lastUpdated: Date?
  @Published var loading = false
  // 密钥相关：缺失时面板显示粘贴框；apiKeyInput 是用户输入的密钥
  @Published var keyMissing = false
  @Published var apiKeyInput = ""
  private var timer: Timer?

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
      self.costOffpeak = rep.costOffpeak
      self.costPeak = rep.costPeak
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

      if model.today.calls > 0 {
        row("今日请求", "\(model.today.calls) 次")
        row("今日输入", "\(fmtTokens(model.today.uncachedInput)) + 缓存\(fmtTokens(model.today.cacheRead))")
        row("今日输出", fmtTokens(model.today.output))
        row("今日花费", "空闲 \(fmtYuan(todayCostOffpeak(model.today))) / 高峰 \(fmtYuan(todayCostPeak(model.today)))", bold: true)
        Divider().padding(.vertical, 2)
      }

      row("累计输入", "\(fmtTokens(model.totals.uncachedInput)) + 缓存\(fmtTokens(model.totals.cacheRead))")
      row("累计输出", fmtTokens(model.totals.output))
      row("累计花费", "空闲 \(fmtYuan(model.costOffpeak)) / 高峰 \(fmtYuan(model.costPeak))", bold: true)

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

  private func row(_ k: String, _ v: String, bold: Bool = false) -> some View {
    HStack(spacing: 6) {
      Text(k).foregroundColor(Color(nsColor: .secondaryLabelColor))
      Spacer(minLength: 4)
      Text(v).fontWeight(bold ? .semibold : .regular)
    }
    .padding(.vertical, 1)
  }
}

struct BalanceMenuView: View {
  @ObservedObject var model: BalanceModel

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

      if model.today.calls > 0 {
        row("今日请求", "\(model.today.calls) 次")
        row("今日输入", "\(fmtTokens(model.today.uncachedInput)) + 缓存\(fmtTokens(model.today.cacheRead))")
        row("今日输出", fmtTokens(model.today.output))
        row("今日花费", "空闲 \(fmtYuan(todayCostOffpeak(model.today))) / 高峰 \(fmtYuan(todayCostPeak(model.today)))", bold: true)
        Divider().padding(.vertical, 2)
      }

      row("累计输入", "\(fmtTokens(model.totals.uncachedInput)) + 缓存\(fmtTokens(model.totals.cacheRead))")
      row("累计输出", fmtTokens(model.totals.output))
      row("累计花费", "空闲 \(fmtYuan(model.costOffpeak)) / 高峰 \(fmtYuan(model.costPeak))", bold: true)

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

  private func row(_ k: String, _ v: String, bold: Bool = false) -> some View {
    HStack(spacing: 6) {
      Text(k).lineLimit(1)
      Spacer(minLength: 4)
      Text(v)
        .fontWeight(bold ? .semibold : .regular)
        .lineLimit(1)
    }
    .padding(.vertical, 0.5)
  }
}
