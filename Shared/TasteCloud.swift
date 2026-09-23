import Foundation

/// What Flow has learned about the listener, carried from the phone to the
/// television through iCloud's key-value store.
///
/// The television has no settings and no thumbs, so the only thing worth
/// syncing is the Taste book — months of "more of this, less of that" — plus
/// the key the phone opened in last, so the two never start on the same one.
///
/// **One writer.** The phone publishes; the television subscribes. The
/// `revision` counter exists so a reader can tell "newer" from "different" and
/// never has to merge, which is safe exactly as long as nothing else ever
/// writes. This is the same model as Chronological's hidden-photograph list,
/// for the same reason: a merge of two opinion books is a research project,
/// and a second writer would need one. If the television ever grows a thumb,
/// this class is where the design changes first.
///
/// Local-first. The book lives in a file on both devices regardless; on the
/// phone the store is consulted only when there is an iCloud account
/// (`ubiquityIdentityToken`), on the television always (see `init` for why),
/// and everything here is a no-op without an account — the app has to be
/// exactly as good with iCloud off, it just does not sync.
public final class TasteCloud: @unchecked Sendable {
    public enum Role { case publisher, subscriber }

    static let bookKey = "taste.book"
    static let revisionKey = "taste.revision"
    static let lastKeyKey = "flow.lastKey"

    public let role: Role
    private let store: NSUbiquitousKeyValueStore?
    private var observer: NSObjectProtocol?
    /// The revision the subscriber has already handed to `onBook`.
    private var adoptedRevision: Int64 = -1

    /// Subscriber only: a newer book has arrived. Called on the main queue.
    public var onBook: ((Data) -> Void)?

    public init(role: Role) {
        self.role = role
#if os(tvOS)
        // No identity-token test here. `ubiquityIdentityToken` is iCloud *Drive*'s
        // identity and tvOS has no iCloud Drive, so it is nil on an Apple TV that
        // is signed in — the first television build logged "iCloud no" against
        // an account that was absolutely there. The key-value store is its own
        // service and works regardless; `synchronize()` says whether it did.
        store = .default
#else
        // The cheapest honest test for "is there an iCloud account here". Touching
        // `NSUbiquitousKeyValueStore.default` without one is harmless but pointless.
        store = FileManager.default.ubiquityIdentityToken != nil ? .default : nil
#endif
        if role == .subscriber, let store {
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: store, queue: .main
            ) { [weak self] _ in self?.pull() }
        }
        synchronized = store?.synchronize() ?? false
    }

    /// Whether the last `synchronize()` was accepted — the only signal tvOS gives
    /// that the store is backed by an account.
    public private(set) var synchronized = false

    /// One line for a host's log.
    public var report: String {
        guard let store else { return "no store" }
        let rev = store.longLong(forKey: Self.revisionKey)
        let bytes = store.data(forKey: Self.bookKey)?.count ?? 0
        return "store \(synchronized ? "synchronized" : "not synchronized"), book \(bytes) bytes, revision \(rev), lastKey \(lastKey().map(String.init) ?? "none")"
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public var isAvailable: Bool { store != nil }

    // MARK: Publisher

    /// The whole book, as bytes. Bumps the revision. Safe to call from any
    /// queue — Taste calls it from its IO queue.
    public func publish(book: Data) {
        guard role == .publisher, let store else { return }
        let revision = store.longLong(forKey: Self.revisionKey) + 1
        store.set(book, forKey: Self.bookKey)
        store.set(revision, forKey: Self.revisionKey)
        store.synchronize()
    }

    /// The key the phone opened in, so the television can avoid it.
    public func publish(lastKey: Int?) {
        guard role == .publisher, let store, let lastKey else { return }
        store.set(Int64(lastKey), forKey: Self.lastKeyKey)
        store.synchronize()
    }

    /// Whether the store already holds a book — a phone that has been learning
    /// for weeks before this shipped publishes its existing book once, on launch,
    /// if this is false.
    public var hasBook: Bool {
        guard let store else { return false }
        return store.data(forKey: Self.bookKey) != nil
    }

    // MARK: Subscriber

    /// Read the store and hand any book newer than the last one to `onBook`.
    /// Called on launch and on every external change.
    public func pull() {
        guard role == .subscriber, let store else { return }
        synchronized = store.synchronize()
        let revision = store.longLong(forKey: Self.revisionKey)
        guard revision > adoptedRevision, let data = store.data(forKey: Self.bookKey) else { return }
        adoptedRevision = revision
        onBook?(data)
    }

    /// The phone's last key, or nil if it has never said.
    public func lastKey() -> Int? {
        guard let store, store.object(forKey: Self.lastKeyKey) != nil else { return nil }
        return Int(store.longLong(forKey: Self.lastKeyKey))
    }
}
