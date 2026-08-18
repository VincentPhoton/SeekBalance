import SwiftUI
import AppKit
import UserNotifications
import Combine

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
    print("版本: v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
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

// MARK: - 更新状态

enum UpdateStatus: Equatable {
  case idle
  case checking
  case upToDate
  case updateAvailable(String)
  case downloading
  case installing
  case done(String)
  case failed(String)
}

@MainActor
private final class ModalCloser: NSObject, NSWindowDelegate {
  func windowWillClose(_ notification: Notification) {
    NSApp.stopModal()
  }
}

/// 屏幕中央自定义弹窗：图标 + 标题 + 多行内容，全部居中（模态，点"好的"或关闭按钮退出）
/// 注意：固定窗口尺寸，用 contentView 挂 SwiftUI（绝不设 contentViewController，避免窗口被自动拉大）
@MainActor
func showCenteredDialog(title: String, lines: [String], buttonTitle: String = "好的") {
  let closer = ModalCloser()
  let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 360, height: 340),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
  )
  panel.title = ""
  panel.isReleasedWhenClosed = false
  panel.delegate = closer
  let icon = NSImage(named: "AppIcon") ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
  let root = VStack(spacing: 10) {
    Spacer(minLength: 0)
    Image(nsImage: icon)
      .resizable()
      .frame(width: 64, height: 64)
    Text(title)
      .font(.system(size: 14, weight: .semibold))
    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
      Text(line)
        .font(.system(size: 12))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    Button(buttonTitle) {
      panel.close()
      NSApp.stopModal()
    }
    .keyboardShortcut(.defaultAction)
    .padding(.top, 6)
    Spacer(minLength: 0)
  }
  .frame(maxWidth: .infinity, maxHeight: .infinity)
  .padding(24)
  let hosting = NSHostingController(rootView: root)
  panel.contentView = hosting.view
  hosting.view.frame = panel.contentView!.bounds
  hosting.view.autoresizingMask = [.width, .height]
  panel.center()
  NSApp.runModal(for: panel)
}

func updateStatusText(_ s: UpdateStatus) -> String {
  switch s {
  case .idle: return ""
  case .checking: return "正在检查更新…"
  case .upToDate: return "已是最新版本 ✅"
  case .updateAvailable(let v): return "发现新版本 v\(v)，开始更新…"
  case .downloading: return "正在下载更新…"
  case .installing: return "正在安装更新…"
  case .done(let v): return "更新已完成（v\(v)）✅"
  case .failed(let msg): return "更新失败：\(msg)"
  }
}

func updateStatusColor(_ s: UpdateStatus) -> Color {
  switch s {
  case .failed: return Color(nsColor: .systemRed)
  case .done, .upToDate: return Color(nsColor: .systemGreen)
  case .downloading, .installing, .checking, .updateAvailable: return Color(nsColor: .systemOrange)
  case .idle: return Color.secondary
  }
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
  @Published var updateStatus: UpdateStatus = .idle
  private var timer: Timer?
  private var reminderTimer: Timer?

  init() {
    // 提醒定时器应用启动即运行，不依赖面板打开
    startReminderTimer()
  }

  /// 高峰前提醒：每 30 秒检查一次，进入提醒窗口（空闲时段且距下一高峰 ≤ 设定分钟）就发通知
  func startReminderTimer() {
    notifyUpdateDoneIfNeeded()
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

  // MARK: - 版本与自动更新

  var currentVersion: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.1.2"
  }

  /// 检查更新：查 GitHub 最新 Release，有新版则自动下载安装并重启
  func checkForUpdate() {
    if case .downloading = updateStatus { return }
    if case .installing = updateStatus { return }
    if case .checking = updateStatus { return }
    updateStatus = .checking
    Task {
      do {
        let info = try await fetchLatestRelease()
        let latest = info.tag.replacingOccurrences(of: "v", with: "")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheckTime")
        guard versionCompare(latest, currentVersion) > 0 else {
          // 已是最新：屏幕中央弹窗提示（含上次检查更新时间）
          updateStatus = .idle
          showUpdateDialog(
            title: "已是最新版本",
            message: "当前版本：v\(currentVersion)\n上次检查更新：\(lastCheckTimeText())"
          )
          return
        }
        updateStatus = .updateAvailable(latest)
        try await performUpdate(dmgURL: info.assetURL, version: latest)
      } catch {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheckTime")
        updateStatus = .idle
        showUpdateDialog(title: "检查更新失败", message: error.localizedDescription)
      }
    }
  }

  /// 检查更新结果弹窗（屏幕中央，图标+内容居中）
  private func showUpdateDialog(title: String, message: String) {
    showCenteredDialog(title: title, lines: message.split(separator: "\n").map(String.init))
  }

  /// 上次检查更新的时间
  private func lastCheckTimeText() -> String {
    let t = UserDefaults.standard.double(forKey: "lastUpdateCheckTime")
    guard t > 0 else { return "从未" }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: t))
  }

  private func fetchLatestRelease() async throws -> (tag: String, assetURL: URL) {
    var req = URLRequest(url: URL(string: "https://api.github.com/repos/VincentPhoton/SeekBalance/releases/latest")!)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
      throw NSError(domain: "update", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法连接 GitHub"])
    }
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let tag = obj?["tag_name"] as? String,
      let assets = obj?["assets"] as? [[String: Any]],
      let asset = assets.first(where: { ($0["name"] as? String)?.contains("arm64") == true }),
      let urlString = asset["browser_download_url"] as? String,
      let url = URL(string: urlString)
    else {
      throw NSError(domain: "update", code: -2, userInfo: [NSLocalizedDescriptionKey: "未找到安装包"])
    }
    return (tag, url)
  }

  /// 比较 "1.1" / "1.2.1" 等版本号：a>b 返回 1，相等 0，小于 -1
  private func versionCompare(_ a: String, _ b: String) -> Int {
    let pa = a.split(separator: ".").compactMap { Int($0) }
    let pb = b.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(pa.count, pb.count) {
      let x = i < pa.count ? pa[i] : 0
      let y = i < pb.count ? pb[i] : 0
      if x != y { return x > y ? 1 : -1 }
    }
    return 0
  }

  /// 自动更新：下载 DMG → 挂载 → 替换 /Applications/SeekBalance.app → 杀旧进程并重启新版
  private func performUpdate(dmgURL: URL, version: String) async throws {
    updateStatus = .downloading
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("SeekBalance-update.dmg")
    try? FileManager.default.removeItem(at: tmp)
    let (downloadURL, _) = try await URLSession.shared.download(from: dmgURL)
    try? FileManager.default.removeItem(at: tmp)
    try FileManager.default.moveItem(at: downloadURL, to: tmp)

    updateStatus = .installing
    let mountPoint = try await mountDMG(tmp)
    _ = try await shell("rm -rf \(shq("/Applications/SeekBalance.app")) && cp -R \(shq(mountPoint + "/SeekBalance.app")) /Applications/SeekBalance.app")
    _ = try await shell("hdiutil detach \(shq(mountPoint)) -force")
    try? FileManager.default.removeItem(at: tmp)

    // 标记刚更新：新版启动时弹"更新已完成"通知
    UserDefaults.standard.set(version, forKey: "justUpdatedVersion")

    // 启动自毁重开脚本（延迟 1 秒杀掉旧进程，再打开新版）
    let helper = FileManager.default.temporaryDirectory.appendingPathComponent("seekbalance-relaunch.sh")
    let script = "#!/bin/sh\nsleep 1\npkill -x SeekBalance\nsleep 0.5\nopen /Applications/SeekBalance.app\n"
    try? script.write(to: helper, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = [helper.path]
    try? proc.run()
    updateStatus = .done(version)
  }

  /// 挂载 DMG 并解析挂载点
  private func mountDMG(_ dmg: URL) async throws -> String {
    let output = try await shell("/usr/bin/hdiutil attach -nobrowse -readonly \(shq(dmg.path)) -plist")
    guard let data = output.data(using: .utf8),
      let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
      let entities = obj["system-entities"] as? [[String: Any]]
    else {
      throw NSError(domain: "update", code: -3, userInfo: [NSLocalizedDescriptionKey: "无法挂载安装包"])
    }
    for e in entities {
      if let mp = e["mount-point"] as? String { return mp }
    }
    throw NSError(domain: "update", code: -3, userInfo: [NSLocalizedDescriptionKey: "无法挂载安装包"])
  }

  /// 在后台线程跑 shell 命令并返回输出（先读 stdout 再 wait，避免管道死锁）
  private func shell(_ cmd: String) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/bin/zsh")
      p.arguments = ["-c", cmd]
      let outPipe = Pipe()
      let errPipe = Pipe()
      p.standardOutput = outPipe
      p.standardError = errPipe
      try p.run()
      let out = outPipe.fileHandleForReading.readDataToEndOfFile()
      _ = errPipe.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      return String(data: out, encoding: .utf8) ?? ""
    }.value
  }

  private func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// 新版启动时提示"更新已完成"
  private func notifyUpdateDoneIfNeeded() {
    let d = UserDefaults.standard
    guard let v = d.string(forKey: "justUpdatedVersion") else { return }
    d.removeObject(forKey: "justUpdatedVersion")
    let content = UNMutableNotificationContent()
    content.title = "✅ 更新已完成"
    content.body = "SeekBalance 已自动更新到 v\(v)，现在使用的是最新版。"
    content.sound = .default
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "updated-\(UUID().uuidString)", content: content, trigger: nil))
  }

  var balanceText: String {
    if let b = balance { return String(format: "¥%.2f", b.total) }
    return balanceError == nil ? "💳 ¥--" : "💳 ?"
  }

  func start() {
    refresh()
    scheduleRefreshTimer()
  }

  /// 按设置的刷新频率（3/5/10 分钟）重排定时器
  private func scheduleRefreshTimer() {
    timer?.invalidate()
    let minutes = refreshMinutesSetting()
    timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes) * 60, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
  }

  /// 用户修改刷新频率：持久化并立即生效
  func setRefreshInterval(minutes: Int) {
    UserDefaults.standard.set(minutes, forKey: "refreshIntervalMinutes")
    scheduleRefreshTimer()
    refresh()
  }

  private func refreshMinutesSetting() -> Int {
    let m = UserDefaults.standard.integer(forKey: "refreshIntervalMinutes")
    return [3, 5, 10].contains(m) ? m : 5
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

// MARK: - 应用（AppKit 状态栏：左键弹面板、右键快捷菜单）

struct SeekBalanceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    // 菜单栏应用无主窗口；Settings 场景仅用于让 App 生命周期正常运转
    Settings { EmptyView() }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem?
  private var popover: NSPopover?
  private var contextMenu: NSMenu?
  private var cancellables = Set<AnyCancellable>()
  private lazy var model = BalanceModel()

  /// 状态栏是否显示余额数字（UserDefaults 持久化，与面板开关共用 "showBalanceText"）
  private var showBalanceText: Bool {
    get { UserDefaults.standard.object(forKey: "showBalanceText") as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: "showBalanceText")
      updateStatusLabel()
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    model.start()
    // 余额变化时刷新菜单栏文字
    model.objectWillChange
      .sink { [weak self] _ in self?.updateStatusLabel() }
      .store(in: &cancellables)
    setupStatusItem()
    setupPopover()
    updateStatusLabel()
    }
  }

  // MARK: 状态栏

  private func setupStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    if let button = item.button {
      button.image = NSImage(systemSymbolName: "creditcard", accessibilityDescription: "SeekBalance")
      button.imagePosition = .imageLeading
      button.target = self
      button.action = #selector(statusItemClicked(_:))
      // 左键与右键都触发，在 action 里区分
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    buildContextMenu()
  }

  @objc private func statusItemClicked(_ sender: Any?) {
    guard let event = NSApp.currentEvent else { return }
    if event.type == .rightMouseUp {
      // 右键：弹出快捷菜单
      if let button = statusItem?.button, let menu = contextMenu {
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
      }
    } else {
      togglePopover()
    }
  }

  /// 右键快捷菜单：刷新 / 检查更新 / 关于 / GitHub / 退出
  private func buildContextMenu() {
    let menu = NSMenu()
    menu.addItem(makeItem("刷新", #selector(refresh)))
    menu.addItem(makeItem("检查更新", #selector(checkForUpdate)))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(makeItem("关于", #selector(showAbout)))
    menu.addItem(makeItem("GitHub 上的 SeekBalance", #selector(openGitHub)))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(makeItem("退出 SeekBalance", #selector(quitApp)))
    contextMenu = menu
  }

  private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
    i.target = self
    return i
  }

  // MARK: 面板弹层

  private func setupPopover() {
    let p = NSPopover()
    p.behavior = .transient
    let panel = BalancePanelView(
      model: model,
      showBalanceText: Binding(
        get: { self.showBalanceText },
        set: { self.showBalanceText = $0 }
      )
    )
    .frame(width: 260, height: 500, alignment: .top)
    .background(Color(nsColor: .windowBackgroundColor))
    let hosting = NSHostingController(rootView: panel)
    // 显式固定尺寸：禁用自动尺寸报告，并把 preferredContentSize 与 contentSize 都设为同一值
    hosting.sizingOptions = []
    let fixed = NSSize(width: 260, height: 500)
    hosting.preferredContentSize = fixed
    p.contentViewController = hosting
    p.contentSize = fixed
    popover = p
  }

  private func togglePopover() {
    guard let button = statusItem?.button else { return }
    if let popover, popover.isShown {
      popover.performClose(nil)
    } else if let popover {
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      // 让弹层获得键盘焦点（输入框/粘贴密钥可用）
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  private func updateStatusLabel() {
    guard let button = statusItem?.button else { return }
    button.title = showBalanceText ? model.balanceText : ""
  }

  // MARK: 快捷菜单动作

  @objc private func refresh() {
    model.refresh()
  }

  @objc private func checkForUpdate() {
    model.checkForUpdate()
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  @objc private func openGitHub() {
    if let url = URL(string: "https://github.com/VincentPhoton/SeekBalance") {
      NSWorkspace.shared.open(url)
    }
  }

  /// 关于：屏幕中央弹窗（图标、名字、版本、用途、作者，全部居中）
  @objc private func showAbout() {
    showCenteredDialog(
      title: "关于 SeekBalance",
      lines: [
        "v\(model.currentVersion)",
        "macOS 菜单栏小工具：查看 DeepSeek API 余额、用量与花费估算。",
        "@VincentPhoton",
      ]
    )
  }
}

struct BalancePanelView: View {
  @ObservedObject var model: BalanceModel
  @Binding var showBalanceText: Bool
  @AppStorage("peakReminderEnabled") private var reminderEnabled = false
  @AppStorage("peakReminderMinutes") private var reminderMinutes = 15
  @AppStorage("refreshIntervalMinutes") private var refreshMinutes = 5
  @State private var minutesText = "15"
  @FocusState private var minutesFocused: Bool

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
        .onChange(of: showBalanceText) { _ in minutesFocused = false }

      // 高峰前提醒设置：开启后按设定分钟数提前发系统通知
      Toggle("高峰前提醒", isOn: $reminderEnabled)
        .controlSize(.small)
        .padding(.vertical, 1)
        .onChange(of: reminderEnabled) { enabled in
          minutesFocused = false
          if enabled { requestNotificationPermission() }
        }
      if reminderEnabled {
        HStack(spacing: 6) {
          Text(reminderMinutes == 0 ? "高峰开始时" : "提前")
            .font(.system(size: 10))
            .fixedSize()
          // 滑块与数字框双向联动：拖滑块改数字，改数字滑块跟着动
          Slider(
            value: Binding(
              get: { Double(reminderMinutes) },
              set: { newValue in
                reminderMinutes = Int(newValue.rounded())
                minutesText = "\(reminderMinutes)"
                minutesFocused = false
              }
            ),
            in: 0...60,
            step: 1
          )
          .controlSize(.small)
          TextField("0", text: $minutesText)
            .frame(width: 34)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .multilineTextAlignment(.center)
            .focused($minutesFocused)
            .onChange(of: minutesText) { newValue in
              let digits = newValue.filter { $0.isNumber }
              if let v = Int(digits) {
                let clamped = min(max(v, 0), 60)
                reminderMinutes = clamped
                if clamped != v { minutesText = "\(clamped)" }
              }
            }
          if reminderMinutes > 0 {
            Text("分钟").font(.system(size: 10)).fixedSize()
          }
        }
        .padding(.vertical, 1)
        .onAppear { minutesText = "\(reminderMinutes)" }
      }

      // 刷新频率设置（3/5/10 分钟，修改即时生效）
      HStack(spacing: 6) {
        Text("刷新频率").font(.system(size: 10))
        Picker("", selection: $refreshMinutes) {
          Text("3 分钟").tag(3)
          Text("5 分钟").tag(5)
          Text("10 分钟").tag(10)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .onChange(of: refreshMinutes) { newValue in
          model.setRefreshInterval(minutes: newValue)
        }
      }
      .padding(.vertical, 1)

      HStack(spacing: 8) {
        Button("🔄 刷新") { minutesFocused = false; model.refresh() }
        Button("退出") { NSApp.terminate(nil) }
        Spacer(minLength: 4)
        Button("检查更新") { model.checkForUpdate() }
          .controlSize(.small)
          .font(.system(size: 9))
        Link("v\(model.currentVersion)", destination: URL(string: "https://github.com/VincentPhoton/SeekBalance")!)
          .font(.system(size: 9))
          // 蓝色 + 下划线：提示可点击（容器 foregroundColor 会覆盖默认链接色，需显式指定）
          .foregroundColor(Color(nsColor: .linkColor))
          .underline()
      }
      .controlSize(.small)
      .padding(.top, 1)
      if model.updateStatus != .idle {
        Text(updateStatusText(model.updateStatus))
          .font(.system(size: 9))
          .foregroundColor(updateStatusColor(model.updateStatus))
          .padding(.top, 1)
      }

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
    // 点击面板空白处时取消数字框选中
    .onTapGesture { minutesFocused = false }
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
  @AppStorage("refreshIntervalMinutes") private var refreshMinutes = 5
  @State private var minutesText = "15"
  @FocusState private var minutesFocused: Bool

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

      // 高峰前提醒设置：开启后按设定分钟数提前发系统通知
      Toggle("高峰前提醒", isOn: $reminderEnabled)
        .controlSize(.small)
        .padding(.vertical, 1)
        .onChange(of: reminderEnabled) { enabled in
          minutesFocused = false
          if enabled { requestNotificationPermission() }
        }
      if reminderEnabled {
        HStack(spacing: 6) {
          Text(reminderMinutes == 0 ? "高峰开始时" : "提前")
            .font(.system(size: 10))
            .fixedSize()
          // 滑块与数字框双向联动：拖滑块改数字，改数字滑块跟着动
          Slider(
            value: Binding(
              get: { Double(reminderMinutes) },
              set: { newValue in
                reminderMinutes = Int(newValue.rounded())
                minutesText = "\(reminderMinutes)"
                minutesFocused = false
              }
            ),
            in: 0...60,
            step: 1
          )
          .controlSize(.small)
          TextField("0", text: $minutesText)
            .frame(width: 34)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .multilineTextAlignment(.center)
            .focused($minutesFocused)
            .onChange(of: minutesText) { newValue in
              let digits = newValue.filter { $0.isNumber }
              if let v = Int(digits) {
                let clamped = min(max(v, 0), 60)
                reminderMinutes = clamped
                if clamped != v { minutesText = "\(clamped)" }
              }
            }
          if reminderMinutes > 0 {
            Text("分钟").font(.system(size: 10)).fixedSize()
          }
        }
        .padding(.vertical, 1)
        .onAppear { minutesText = "\(reminderMinutes)" }
      }

      // 刷新频率设置（3/5/10 分钟，修改即时生效）
      HStack(spacing: 6) {
        Text("刷新频率").font(.system(size: 10))
        Picker("", selection: $refreshMinutes) {
          Text("3 分钟").tag(3)
          Text("5 分钟").tag(5)
          Text("10 分钟").tag(10)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .labelsHidden()
        .onChange(of: refreshMinutes) { newValue in
          model.setRefreshInterval(minutes: newValue)
        }
      }
      .padding(.vertical, 1)

      HStack(spacing: 8) {
        Button("🔄 刷新") { minutesFocused = false; model.refresh() }
        Button("退出") { NSApp.terminate(nil) }
        Spacer(minLength: 4)
        Button("检查更新") { model.checkForUpdate() }
          .controlSize(.small)
          .font(.system(size: 9))
        Link("v\(model.currentVersion)", destination: URL(string: "https://github.com/VincentPhoton/SeekBalance")!)
          .font(.system(size: 9))
          // 蓝色 + 下划线：提示可点击（容器 foregroundColor 会覆盖默认链接色，需显式指定）
          .foregroundColor(Color(nsColor: .linkColor))
          .underline()
      }
      .controlSize(.small)
      .padding(.top, 2)
      if model.updateStatus != .idle {
        Text(updateStatusText(model.updateStatus))
          .font(.system(size: 9))
          .foregroundColor(updateStatusColor(model.updateStatus))
          .padding(.top, 1)
      }

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
    // 点击面板空白处时取消数字框选中
    .onTapGesture { minutesFocused = false }
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
