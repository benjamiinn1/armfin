//
//  KeychainStore.swift
//  armfin Watch App
//
//  Services-layer credential storage. Persists serverURL + userId + accessToken
//  together as a single Keychain item, per specs/spec.md §2.5. No SwiftData,
//  networking, or UI dependencies — pure Keychain wrapper.
//

import Foundation
import Security

/// Typed errors surfaced in place of raw `OSStatus` codes from the Security framework.
enum KeychainStoreError: Error, Equatable {
    /// Encoding the `Credentials` payload to data failed.
    case encodingFailed
    /// Decoding the stored payload back into `Credentials` failed.
    case decodingFailed
    /// `SecItemAdd` failed with the given status.
    case addFailed(OSStatus)
    /// `SecItemUpdate` failed with the given status.
    case updateFailed(OSStatus)
    /// `SecItemCopyMatching` failed with a status other than "not found".
    case lookupFailed(OSStatus)
    /// `SecItemDelete` failed with a status other than "not found".
    case deleteFailed(OSStatus)
}

/// Stores and retrieves the Jellyfin server credentials (`serverURL`, `userId`,
/// `accessToken`) as a single Keychain generic-password item.
///
/// Per spec §2.5, the item is created with:
/// - `kSecClass`: `kSecClassGenericPassword`
/// - `kSecAttrAccessible`: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// - `kSecAttrSynchronizable`: `false` (explicit — never synced via iCloud Keychain)
///
/// `ServerConfiguration` (SwiftData) holds the rest of the server/account metadata;
/// only this type ever touches the actual access token.
struct KeychainStore {

    /// The three credential fields persisted together as one Keychain item.
    struct Credentials: Codable, Equatable, Sendable {
        let serverURL: String
        let userId: String
        let accessToken: String
    }

    /// Fixed service/account identifiers for the single configured-server item.
    /// armfin supports one logged-in server at a time, so a stable identifier pair
    /// is sufficient to address "the" credential item.
    private let service: String
    private let account: String

    init(service: String = "com.armfin.credentials", account: String = "default") {
        self.service = service
        self.account = account
    }

    // MARK: - Save (upsert)

    /// Saves the given credentials as a single Keychain item, creating it if absent
    /// or updating it in place if one already exists for this service/account.
    func save(serverURL: String, userId: String, accessToken: String) throws {
        let credentials = Credentials(serverURL: serverURL, userId: userId, accessToken: accessToken)

        guard let data = try? JSONEncoder().encode(credentials) else {
            throw KeychainStoreError.encodingFailed
        }

        let baseQuery = baseQuery()

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Item already exists for this service/account — update it in place.
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecAttrSynchronizable as String: kCFBooleanFalse as Any
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.updateFailed(updateStatus)
            }
        default:
            throw KeychainStoreError.addFailed(addStatus)
        }
    }

    // MARK: - Retrieve

    /// Returns the currently stored credentials, or `nil` if none exist.
    /// Throws only for unexpected Keychain or decoding failures.
    func retrieve() throws -> Credentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainStoreError.decodingFailed
            }
            guard let credentials = try? JSONDecoder().decode(Credentials.self, from: data) else {
                throw KeychainStoreError.decodingFailed
            }
            return credentials
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.lookupFailed(status)
        }
    }

    // MARK: - Delete

    /// Removes the stored credentials, if any. Used on logout.
    /// Treats "item not found" as a successful no-op rather than an error.
    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.deleteFailed(status)
        }
    }

    // MARK: - Private helpers

    /// The base query identifying "the" credential item, shared across
    /// add/update/lookup/delete so they all address the same Keychain entry.
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
