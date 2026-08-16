import Foundation
import Security

// MARK: - 钥匙串（Keychain）存取 API 密钥
// 普通用户可直接在面板粘贴密钥，存入本机钥匙串（系统级加密，其他应用读不到）。

enum Keychain {
  static let service = "local.seekbalance"
  static let account = "DeepSeek API Key"

  /// 保存密钥（先删旧再写新）
  static func saveAPIKey(_ key: String) -> Bool {
    let deleteQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(deleteQuery as CFDictionary)

    let addQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: Data(key.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
  }

  /// 读取密钥
  static func loadAPIKey() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
