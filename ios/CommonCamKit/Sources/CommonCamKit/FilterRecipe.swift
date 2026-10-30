import Foundation

/// How a photo should look, stored with the item instead of baking the look into the pixels: the original
/// upload is never altered, so anyone can view or save either version. Wire format `{"id","version","params"}`.
/// `version` is the filter definition's version at capture time, so a later tweak to a look cannot silently
/// change photos already taken.
public struct FilterRecipe: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let version: Int
    public let params: [String: Double]

    public init(id: String, version: Int, params: [String: Double] = [:]) {
        self.id = id
        self.version = version
        self.params = params
    }
}
