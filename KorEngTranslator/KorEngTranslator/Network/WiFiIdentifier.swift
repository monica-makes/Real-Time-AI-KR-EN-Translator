import Foundation
import SystemConfiguration.CaptiveNetwork
import CryptoKit

/// Utility for getting WiFi network identifier for auto-pairing
/// Note: Requires "Access WiFi Information" capability in Xcode
/// and location permission for iOS 13+
class WiFiIdentifier {
    /// Get a unique identifier for the current WiFi network
    /// Returns a hashed version of the BSSID (router MAC address) for privacy
    /// - Returns: Base64-encoded hash of BSSID, or nil if not on WiFi
    static func getCurrentWiFiIdentifier() -> String? {
        #if os(iOS)
        // Get supported interfaces
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else {
            print("[WiFiIdentifier] Failed to get network interfaces")
            return nil
        }

        for interface in interfaces {
            guard let networkInfo = CNCopyCurrentNetworkInfo(interface as CFString) as NSDictionary? else {
                continue
            }

            // Prefer BSSID (router MAC) as identifier - more reliable than SSID
            // Two users on different "Home WiFi" networks won't accidentally match
            if let bssid = networkInfo[kCNNetworkInfoKeyBSSID as String] as? String {
                // Hash the BSSID for privacy
                return hashIdentifier(bssid)
            }

            // Fallback to SSID if BSSID not available
            if let ssid = networkInfo[kCNNetworkInfoKeySSID as String] as? String {
                return hashIdentifier(ssid)
            }
        }

        print("[WiFiIdentifier] No WiFi network information available")
        return nil
        #else
        // macOS - not supported for now
        return nil
        #endif
    }

    /// Get the SSID (network name) of the current WiFi network
    /// - Returns: SSID string, or nil if not on WiFi
    static func getCurrentSSID() -> String? {
        #if os(iOS)
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else {
            return nil
        }

        for interface in interfaces {
            guard let networkInfo = CNCopyCurrentNetworkInfo(interface as CFString) as NSDictionary? else {
                continue
            }

            if let ssid = networkInfo[kCNNetworkInfoKeySSID as String] as? String {
                return ssid
            }
        }

        return nil
        #else
        return nil
        #endif
    }

    /// Hash an identifier using SHA256 and return as base64
    /// - Parameter identifier: The identifier to hash (e.g., BSSID)
    /// - Returns: Base64-encoded SHA256 hash
    private static func hashIdentifier(_ identifier: String) -> String {
        guard let data = identifier.data(using: .utf8) else {
            return identifier
        }

        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
    }
}
