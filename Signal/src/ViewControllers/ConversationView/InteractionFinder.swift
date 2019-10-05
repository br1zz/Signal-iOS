//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import GRDBCipher

protocol InteractionFinderAdapter {
    associatedtype ReadTransaction

    static func fetch(uniqueId: String, transaction: ReadTransaction) throws -> TSInteraction?

    func mostRecentInteraction(transaction: ReadTransaction) throws -> TSInteraction?
    func sortIndex(interactionUniqueId: String, transaction: ReadTransaction) throws -> UInt?
    func count(transaction: ReadTransaction) throws -> UInt
    func enumerateInteractionIds(transaction: ReadTransaction, block: @escaping (String, UnsafeMutablePointer<ObjCBool>) throws -> Void) throws
}

@objc
public class InteractionFinder: NSObject, InteractionFinderAdapter {

    let yapAdapter: YAPDBInteractionFinderAdapter
    let grdbAdapter: GRDBInteractionFinderAdapter

    @objc
    public init(threadUniqueId: String) {
        self.yapAdapter = YAPDBInteractionFinderAdapter(threadUniqueId: threadUniqueId)
        self.grdbAdapter = GRDBInteractionFinderAdapter(threadUniqueId: threadUniqueId)
    }

    // MARK: - static methods

    @objc
    public class func fetchSwallowingErrors(uniqueId: String, transaction: SDSAnyReadTransaction) -> TSInteraction? {
        do {
            return try fetch(uniqueId: uniqueId, transaction: transaction)
        } catch {
            owsFailDebug("error: \(error)")
            return nil
        }
    }

    public class func fetch(uniqueId: String, transaction: SDSAnyReadTransaction) throws -> TSInteraction? {
        switch transaction.transaction {
        case .yapRead(let yapRead):
            return YAPDBInteractionFinderAdapter.fetch(uniqueId: uniqueId, transaction: yapRead)
        case .grdbRead(let grdbRead):
            return try GRDBInteractionFinderAdapter.fetch(uniqueId: uniqueId, transaction: grdbRead)
        }
    }

    // MARK: - instance methods

    public func mostRecentInteraction(transaction: SDSAnyReadTransaction) throws -> TSInteraction? {
        switch transaction.transaction {
        case .yapRead(let yapRead):
            return yapAdapter.mostRecentInteraction(transaction: yapRead)
        case .grdbRead(let grdbRead):
            return try grdbAdapter.mostRecentInteraction(transaction: grdbRead)
        }
    }

    public func sortIndex(interactionUniqueId: String, transaction: SDSAnyReadTransaction) throws -> UInt? {
        return try Bench(title: "sortIndex") {
            switch transaction.transaction {
            case .yapRead(let yapRead):
                return yapAdapter.sortIndex(interactionUniqueId: interactionUniqueId, transaction: yapRead)
            case .grdbRead(let grdbRead):
                return try grdbAdapter.sortIndex(interactionUniqueId: interactionUniqueId, transaction: grdbRead)
            }
        }
    }

    public func count(transaction: SDSAnyReadTransaction) throws -> UInt {
        switch transaction.transaction {
        case .yapRead(let yapRead):
            return yapAdapter.count(transaction: yapRead)
        case .grdbRead(let grdbRead):
            return try grdbAdapter.count(transaction: grdbRead)
        }
    }

    public func enumerateInteractionIds(transaction: SDSAnyReadTransaction, block: @escaping (String, UnsafeMutablePointer<ObjCBool>) throws -> Void) throws {
        switch transaction.transaction {
        case .yapRead(let yapRead):
            return try yapAdapter.enumerateInteractionIds(transaction: yapRead, block: block)
        case .grdbRead(let grdbRead):
            return try grdbAdapter.enumerateInteractionIds(transaction: grdbRead, block: block)
        }
    }
}

struct YAPDBInteractionFinderAdapter: InteractionFinderAdapter {

    static let extensionName: String = TSMessageDatabaseViewExtensionName

    private let threadUniqueId: String

    init(threadUniqueId: String) {
        self.threadUniqueId = threadUniqueId
    }

    // MARK: - static methods

    static func fetch(uniqueId: String, transaction: YapDatabaseReadTransaction) -> TSInteraction? {
        return transaction.object(forKey: uniqueId, inCollection: TSInteraction.collection()) as? TSInteraction
    }

    // MARK: - instance methods

    func mostRecentInteraction(transaction: YapDatabaseReadTransaction) -> TSInteraction? {
        return ext(transaction).lastObject(inGroup: threadUniqueId) as? TSInteraction
    }

    func count(transaction: YapDatabaseReadTransaction) -> UInt {
        return ext(transaction).numberOfItems(inGroup: threadUniqueId)
    }

    func sortIndex(interactionUniqueId: String, transaction: YapDatabaseReadTransaction) -> UInt? {
        var index: UInt = 0
        let wasFound = ext(transaction).getGroup(nil, index: &index, forKey: interactionUniqueId, inCollection: collection)

        guard wasFound else {
            return nil
        }

        return index
    }

    func enumerateInteractionIds(transaction: YapDatabaseReadTransaction, block: @escaping (String, UnsafeMutablePointer<ObjCBool>) throws -> Void) throws {
        var errorToRaise: Error?
        ext(transaction).enumerateKeys(inGroup: threadUniqueId, with: NSEnumerationOptions.reverse) { (_, key, _, stopPtr) in
            do {
                try block(key, stopPtr)
            } catch {
                // the block parameter is a `throws` block because the GRDB implementation can throw
                // we don't expect this with YapDB, though we still try to handle it.
                owsFailDebug("unexpected error: \(error)")
                stopPtr.pointee = true
                errorToRaise = error
            }
        }
        if let errorToRaise = errorToRaise {
            throw errorToRaise
        }
    }

    // MARK: - private

    private var collection: String {
        return TSInteraction.collection()
    }

    private func ext(_ transaction: YapDatabaseReadTransaction) -> YapDatabaseViewTransaction {
        return transaction.ext(type(of: self).extensionName) as! YapDatabaseViewTransaction
    }
}

struct GRDBInteractionFinderAdapter: InteractionFinderAdapter {
    typealias ReadTransaction = Database

    let threadUniqueId: String

    init(threadUniqueId: String) {
        self.threadUniqueId = threadUniqueId
    }

    // MARK: - static methods

    static let cn = InteractionRecord.columnName
    let cn = InteractionRecord.columnName

    static func fetch(uniqueId: String, transaction: Database) throws -> TSInteraction? {
        guard let interactionRecord = try InteractionRecord.fetchOne(transaction,
                                                                     sql: "SELECT * FROM \(InteractionRecord.databaseTableName) WHERE \(cn(.uniqueId)) = ?",
            arguments: [uniqueId]) else {
                return nil
        }

        // GRDB CLEANUP: eventually we won't need this thread record, but currently it's the only way to assign a uniqueThreadId to an interaction.
        guard let threadRecord = try ThreadRecord.fetchOne(transaction,
                                                           sql: "SELECT * FROM  \(ThreadRecord.databaseTableName) WHERE  \(ThreadRecord.columnName(.uniqueId)) = ?",
            arguments: [interactionRecord.threadUniqueId]) else {
                throw assertionError("thread record was unexpectedly nil")
        }

        let thread = TSThread.fromRecord(threadRecord)

        return TSInteraction.fromRecord(interactionRecord, thread: thread)
    }

    // MARK: - instance methods

    func mostRecentInteraction(transaction: Database) throws -> TSInteraction? {
        guard let interactionRecord = try InteractionRecord.fetchOne(transaction,
                                                                     sql: """
            SELECT *
            FROM \(InteractionRecord.databaseTableName)
            WHERE \(cn(.threadUniqueId)) = ?
            ORDER BY \(cn(.id)) DESC
            """,
            arguments: [threadUniqueId]) else {
                return nil
        }

        guard let threadRecord = try ThreadRecord.fetchOne(transaction,
                                                           sql: "SELECT * FROM  \(ThreadRecord.databaseTableName) WHERE  \(ThreadRecord.columnName(.uniqueId)) = ?",
            arguments: [interactionRecord.threadUniqueId]) else {
                throw assertionError("thread record was unexpectedly nil")
        }

        let thread = TSThread.fromRecord(threadRecord)

        return TSInteraction.fromRecord(interactionRecord, thread: thread)
    }

    func sortIndex(interactionUniqueId: String, transaction: Database) throws -> UInt? {
        return try UInt.fetchOne(transaction,
                                 sql: """
            SELECT rowNumber
            FROM (
                SELECT
                    ROW_NUMBER() OVER (ORDER BY \(cn(.id))) as rowNumber,
                    \(cn(.id)),
                    \(cn(.uniqueId))
                FROM \(InteractionRecord.databaseTableName)
                WHERE \(cn(.threadUniqueId)) = ?
            )
            WHERE \(cn(.uniqueId)) = ?
            """,
            arguments: [threadUniqueId, interactionUniqueId])
    }

    func count(transaction: Database) throws -> UInt {
        guard let count = try UInt.fetchOne(transaction,
                                            sql: """
            SELECT COUNT(*)
            FROM \(InteractionRecord.databaseTableName)
            WHERE \(cn(.threadUniqueId)) = ?
            """,
            arguments: [threadUniqueId]) else {
                throw assertionError("count was unexpectedly nil")
        }
        return count
    }

    func enumerateInteractionIds(transaction: Database, block: @escaping (String, UnsafeMutablePointer<ObjCBool>) throws -> Void) throws {
        var stop: ObjCBool = false

        try String.fetchCursor(transaction,
                           sql: """
            SELECT \(cn(.uniqueId))
            FROM \(InteractionRecord.databaseTableName)
            WHERE \(cn(.threadUniqueId)) = ?
            ORDER BY \(cn(.id)) DESC
""",
            arguments: [threadUniqueId]).forEach { (uniqueId: String) -> Void in

            if stop.boolValue {
                return
            }

            try block(uniqueId, &stop)
        }
    }
}

private func assertionError(_ description: String) -> Error {
    return OWSErrorMakeAssertionError(description)
}
