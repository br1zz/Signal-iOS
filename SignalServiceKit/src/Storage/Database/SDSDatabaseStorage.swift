//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import GRDBCipher

@objc
public class SDSDatabaseStorage: NSObject {

    // TODO hoist to environment
    @objc
    public static let shared: SDSDatabaseStorage = try! SDSDatabaseStorage(raisingErrors: ())

    @available(*, unavailable, message:"use other constructor instead.")
    override init() {
        fatalError("unavailable")
    }

    // MARK: - Initialization / Setup

    let adapter: SDSDatabaseStorageAdapter

    @objc
    required init(raisingErrors: ()) throws {
        if FeatureFlags.useGRDB {
            let dbDir: URL = URL(fileURLWithPath: OWSFileSystem.appSharedDataDirectoryPath(), isDirectory: true).appendingPathComponent("grdb_database", isDirectory: true)
            // crash if we can't read the DB.
            adapter = try! GRDBDatabaseStorageAdapter(dbDir: dbDir)
        } else {
            adapter = YAPDBStorageAdapter()
        }
    }

    // MARK: -

    public func uiRead(block: @escaping (SDSAnyReadTransaction) -> Void) throws {
        try adapter.uiRead(block: block)
    }

    public func read(block: @escaping (SDSAnyReadTransaction) -> Void) throws {
        try adapter.read(block: block)
    }

    public func write(block: @escaping (SDSAnyWriteTransaction) -> Void) throws {
        try adapter.write(block: block)
    }

    // MARK: - Error Swallowing

    // The original yap db access methods don't throw, but the grdb ones can.
    // To minimize disruption at the callsite while migrating, we have these
    // non-throw versions which simply swallow errors.
    //
    // Eventually we probably want to migrate away from these *SwallowingErrors flavors,
    // in favor of explicitly handling errors where possible.

    @objc
    public func uiReadSwallowingErrors(block: @escaping (SDSAnyReadTransaction) -> Void) {
        do {
            try uiRead(block: block)
        } catch {
            owsFailDebug("error: \(error)")
        }
    }

    @objc
    public func readSwallowingErrors(block: @escaping (SDSAnyReadTransaction) -> Void) {
        do {
            try read(block: block)
        } catch {
            owsFailDebug("error: \(error)")
        }
    }

    @objc
    public func writeSwallowingErrors(block: @escaping (SDSAnyWriteTransaction) -> Void) {
        do {
            try write(block: block)
        } catch {
            owsFailDebug("error: \(error)")
        }
    }
}

protocol SDSDatabaseStorageAdapter {
    func uiRead(block: @escaping (SDSAnyReadTransaction) -> Void) throws
    func read(block: @escaping (SDSAnyReadTransaction) -> Void) throws
    func write(block: @escaping (SDSAnyWriteTransaction) -> Void) throws
}

private struct YAPDBStorageAdapter {
    var storage: OWSPrimaryStorage {
        return OWSPrimaryStorage.shared()
    }
}

extension YAPDBStorageAdapter: SDSDatabaseStorageAdapter {
    func uiRead(block: @escaping (SDSAnyReadTransaction) -> Void) {
        storage.uiDatabaseConnection.read { yapTransaction in
            block(SDSAnyReadTransaction(.yapRead(yapTransaction)))
        }
    }

    func read(block: @escaping (SDSAnyReadTransaction) -> Void) {
        storage.dbReadConnection.read { yapTransaction in
            block(SDSAnyReadTransaction(.yapRead(yapTransaction)))
        }
    }

    func write(block: @escaping (SDSAnyWriteTransaction) -> Void) {
        storage.dbReadWriteConnection.readWrite { yapTransaction in
            block(SDSAnyWriteTransaction(.yapWrite(yapTransaction)))
        }
    }
}

public struct GRDBDatabaseStorageAdapter {

    private let keyServiceName: String = "TSKeyChainService"
    private let keyName: String = "OWSDatabaseCipherKeySpec"

    private let storage: Storage

    public var pool: DatabasePool {
        return storage.pool
    }

    init(dbDir: URL) throws {
        OWSFileSystem.ensureDirectoryExists(dbDir.path)

        let dbURL = dbDir.appendingPathComponent("signal.sqlite", isDirectory: false)
        storage = try Storage(dbURL: dbURL, keyServiceName: keyServiceName, keyName: keyName)

        let mutatingSelf = self
        AppReadiness.runNowOrWhenAppDidBecomeReady {
            do {
                try mutatingSelf.verify()
            } catch {
                owsFailDebug("error: \(error)")
            }
        }
    }

    func verify() throws {
        try storage.pool.read { db in
            guard let someCount = try UInt.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master") else {
                owsFailDebug("failed to verify storage")
                return
            }
            Logger.debug("verified storage: \(someCount)")
        }
    }
}

extension GRDBDatabaseStorageAdapter: SDSDatabaseStorageAdapter {
    func uiRead(block: @escaping (SDSAnyReadTransaction) -> Void) throws {
        // TODO this should be based on a snapshot
        try pool.read { database in
            block(SDSAnyReadTransaction(.grdbRead(database)))
        }
    }

    func read(block: @escaping (SDSAnyReadTransaction) -> Void) throws {
        try pool.read { database in
            block(SDSAnyReadTransaction(.grdbRead(database)))
        }
    }

    func write(block: @escaping (SDSAnyWriteTransaction) -> Void) throws {
        try pool.write { database in
            block(SDSAnyWriteTransaction(.grdbWrite(database)))
        }
    }
}

private struct Storage {

    // MARK: -

    let pool: DatabasePool

    init(dbURL: URL, keyServiceName: String, keyName: String) throws {
        let keyspec = KeySpecSource(keyServiceName: keyServiceName, keyName: keyName)

        var configuration = Configuration()
        configuration.readonly = false
        configuration.foreignKeysEnabled = true // Default is already true
        // configuration.trace = { print($0) }     // Prints all SQL statements
        configuration.label = "Modern (GRDB) Storage"      // Useful when your app opens multiple databases
        configuration.maximumReaderCount = 10   // The default is 5

        configuration.passphraseBlock = { try keyspec.fetchString() }
        configuration.prepareDatabase = { (db: Database) in
            try db.execute(sql: "PRAGMA cipher_plaintext_header_size = 32")
        }

        pool = try DatabasePool(path: dbURL.path, configuration: configuration)
        Logger.debug("dbURL: \(dbURL)")

        OWSFileSystem.protectFileOrFolder(atPath: dbURL.path)
    }
}

private struct KeySpecSource {
    let keyServiceName: String
    let keyName: String

    func fetchString() throws -> String {
        // Use a raw key spec, where the 96 hexadecimal digits are provided
        // (i.e. 64 hex for the 256 bit key, followed by 32 hex for the 128 bit salt)
        // using explicit BLOB syntax, e.g.:
        //
        // x'98483C6EB40B6C31A448C22A66DED3B5E5E8D5119CAC8327B655C8B5C483648101010101010101010101010101010101'
        let data = try fetchData()

        // 256 bit key + 128 bit salt
        guard data.count == 48 else {
            // crash
            owsFail("unexpected keyspec length")
        }

        let passphrase = "x'\(data.hexadecimalString)'"
        return passphrase
    }

    func fetchData() throws -> Data {
        return try CurrentAppContext().keychainStorage().data(forService: keyServiceName, key: keyName)
    }
}
