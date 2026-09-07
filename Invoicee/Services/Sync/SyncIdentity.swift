import Foundation

/// Who a synced document belongs to.
///
/// Two identifiers, because they answer different questions. `uid` is the Firebase
/// principal, and the only one Firestore rules can trust — it is asserted by Firebase
/// after verifying Google's ID token, not by this app. `googleAccountID` is the Google
/// `sub`, which is what documents written before Firebase Auth existed carry, and what
/// the per-day revenue document IDs are still derived from.
///
/// New writes stamp both, so a document stays findable either way while accounts
/// migrate. Once no unclaimed documents remain, `googleAccountID` can go.
struct SyncIdentity: Equatable {
    let uid: String
    let googleAccountID: String
}
