import Foundation

/// The optional 6-character join PIN. Its alphabet has no look-alikes (0/O, 1/I/L), matching the server.
public enum PinCode {
    public static let length = 6
    static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// What the guest typed, uppercased with spaces and dashes removed, or nil if it can't be a PIN.
    public static func normalized(_ typed: String) -> String? {
        let pin = typed.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard pin.count == length, pin.allSatisfy(alphabet.contains) else { return nil }
        return pin
    }
}
