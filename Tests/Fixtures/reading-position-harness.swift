// Standalone behavior harness for the shipping causal-position repository and HTTP lane.
// The small storage/transport contracts below replace UIKit/app wiring; position logic is
// compiled unchanged from Features/ReadingPosition. No simulator or server is required.
import Foundation
struct Bookmark: Codable, Equatable, Sendable { let chapterIndex: Int; let progress: Double; let characterCount: Int; var lastModified: Date? }
struct ReadingDevice { var id: String; var name: String; @MainActor static var current: Self { .init(id: "ios-device", name: "iPhone") } }
struct BookMetadata { var folder: String?; var id: String }
func syncId(for book: BookMetadata) -> String? { book.id }
enum FileNames { static let bookmark = "bookmark.json" }
@MainActor enum BookStorage {
 static func getAppDirectory() throws -> URL { FileManager.default.temporaryDirectory }
 static func getBooksDirectory() throws -> URL { FileManager.default.temporaryDirectory }
 static func loadAllBooks() throws -> [BookMetadata] { [] }
 static func loadBookmark(root: URL) -> Bookmark? { (try? Data(contentsOf: root.appendingPathComponent(FileNames.bookmark))).flatMap { try? JSONDecoder().decode(Bookmark.self, from: $0) } }
 static func save<T: Encodable>(_ item: T, inside root: URL, as name: String) throws { try JSONEncoder().encode(item).write(to: root.appendingPathComponent(name), options: .atomic) }
}
struct HttpSyncKvKeyMeta: Codable, Sendable { var key: String; var etag: String?; var lastModified: String = ""; var size: Int? = nil }
struct HttpSyncKvFetched: Sendable { var body: Data; var etag: String }
struct HttpSyncKvWriteResponse: Sendable { var etag: String? }
struct HttpSyncError: Error { var message: String }
protocol HttpSyncKvTransport: Sendable {
 func getBounded(key: String, maxBytes: Int) async throws -> HttpSyncKvFetched?
 func put(key: String, contentType: String, body: Data) async throws -> HttpSyncKvWriteResponse
}
enum HttpSyncActiveBooks { static func contains(_ id: String) -> Bool { false } }
struct HttpSyncLocalLibrary {
 struct Book { let metadata: BookMetadata; let root: URL?; let bookmarkModified: Date? }
 let books: [Book]
 static func scan(booksDirectory: URL) async -> HttpSyncLocalLibrary { .init(books: []) }
}
extension Sequence where Element == UInt8 { var lowercaseHex: String { map { String(format: "%02x", $0) }.joined() } }
extension Notification.Name { static let httpSyncBookmarkApplied = Notification.Name("bookmark-applied") }

import Foundation
actor MemoryTransport: HttpSyncKvTransport {
 var data: [String:Data] = [:]
 var gets = 0
 var puts = 0
 var fail: Set<String> = []
 func getBounded(key:String,maxBytes:Int) async throws -> HttpSyncKvFetched? {
  gets += 1
  if fail.contains(key) { throw HttpSyncError(message:"offline") }
  guard let body=data[key] else{return nil}
  if body.count>maxBytes { throw HttpSyncError(message:"Sync response exceeds the size limit.") }
  return HttpSyncKvFetched(body:body,etag:"sha256:"+ReadingPositionRepository.digest(body))
 }
 func put(key:String,contentType:String,body:Data) async throws -> HttpSyncKvWriteResponse {
  puts += 1; data[key]=body
  return HttpSyncKvWriteResponse(etag:"sha256:"+ReadingPositionRepository.digest(body))
 }
 func seed(_ key:String,_ body:Data) {data[key]=body}
 func markFailed(_ key:String) {fail.insert(key)}
 func listing() -> [String:HttpSyncKvKeyMeta] {Dictionary(uniqueKeysWithValues:data.map {($0.key,HttpSyncKvKeyMeta(key:$0.key,etag:"sha256:"+ReadingPositionRepository.digest($0.value)))})}
 func counts()->(Int,Int){(gets,puts)}
}
@main struct Check {
 @MainActor static func main() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("position-check-\(UUID())")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let book = root.appendingPathComponent("book")
  try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
  let store = ReadingPositionRepository(directory: root.appendingPathComponent("positions"), device: ReadingDevice(id:"ios-device", name:"iPhone"))
  let session = store.open(bookId:"test-book", root:book)
  precondition(session.initialBookmark == nil)
  let first = session.navigate(bookmark:Bookmark(chapterIndex:0, progress:0.4, characterCount:40, lastModified:Date(timeIntervalSinceReferenceDate:1000)))!
  precondition(store.record(root:book,event:first)?.progress == 0.4)
  precondition(session.navigate(bookmark:Bookmark(chapterIndex:0, progress:0.4, characterCount:40, lastModified:.now)) == nil)
  let backwards = session.navigate(bookmark:Bookmark(chapterIndex:0, progress:0.2, characterCount:20, lastModified:Date(timeIntervalSinceReferenceDate:1)))!
  precondition(backwards.observes(first) && backwards.compatibilityAt > first.compatibilityAt)
  precondition(store.record(root:book,event:backwards)?.progress == 0.2)
  for index in 1...150 {
   let event = session.navigate(bookmark:Bookmark(chapterIndex:0, progress:Double(index)/200, characterCount:index, lastModified:Date(timeIntervalSinceReferenceDate:Double(index))))!
   _ = store.record(root:book,event:event)
  }
  let state = store.snapshot(bookId:"test-book")
  precondition(state.events.filter{$0.deviceId == "ios-device"}.count == 50)
  precondition(state.pending.count <= 51)
  let reopened = ReadingPositionRepository(directory:root.appendingPathComponent("positions"),device:ReadingDevice(id:"ios-device",name:"iPhone"))
  let resumed = reopened.open(bookId:"test-book",root:book)
  precondition(resumed.initialBookmark?.progress == 0.75)
  let unchanged = try Data(contentsOf:book.appendingPathComponent(FileNames.bookmark))
  _ = reopened.open(bookId:"test-book",root:book)
  let again = try Data(contentsOf:book.appendingPathComponent(FileNames.bookmark)); precondition(unchanged == again)
  let journal = reopened.export(bookId:"test-book")!
  let body = try JSONEncoder().encode(journal)
  let roundtrip = try JSONDecoder().decode(ReadingPositionJournal.self,from:body)
  precondition(roundtrip.events.count == 50 && roundtrip.heads.count == 1)
  let last = roundtrip.heads[0]
  var peer = last; peer.id = "android-event";peer.originId="android-origin";peer.deviceId="android-device";peer.deviceName="Android";peer.sequence=1;peer.sessionId="android-session";peer.position.progress=0.1;peer.position.characterCount=10;peer.occurredAt=0;peer.compatibilityAt=last.compatibilityAt+1;peer.seen=[last.originId:last.sequence]
  let moved = try reopened.merge(ReadingPositionJournal(bookId:"test-book",deviceId:"android-device",events:[peer],heads:[peer]),root:book); precondition(moved)
  precondition(BookStorage.loadBookmark(root:book)?.progress == 0.1)
  let peerSession = reopened.open(bookId:"test-book",root:book)
  let local = peerSession.navigate(bookmark:Bookmark(chapterIndex:0,progress:0.05,characterCount:5,lastModified:Date(timeIntervalSinceReferenceDate:0)))!
  precondition(local.observes(peer) && local.compatibilityAt > peer.compatibilityAt)
  precondition(reopened.record(root:book,event:local)?.progress == 0.05)
  try FileManager.default.removeItem(at:book)
  _ = reopened.record(root:book,event:local)
  precondition(!FileManager.default.fileExists(atPath:book.path))
  let laneRoot = root.appendingPathComponent("lane-book")
  try FileManager.default.createDirectory(at:laneRoot,withIntermediateDirectories:true)
  let laneStore = ReadingPositionRepository(directory:root.appendingPathComponent("lane-positions"),device:ReadingDevice(id:"ios-device",name:"iPhone"))
  let laneSession = laneStore.open(bookId:"test-book",root:laneRoot)
  let laneEvent = laneSession.navigate(bookmark:Bookmark(chapterIndex:0,progress:0.5,characterCount:50,lastModified:Date(timeIntervalSinceReferenceDate:10)))!
  _ = laneStore.record(root:laneRoot,event:laneEvent)
  let lane = HttpReadingPositionLane(store:laneStore), transport=MemoryTransport()
  let firstExchange = await lane.exchange(transport:transport,listing:[:],roots:["test-book":laneRoot],scope:"test")
  precondition(firstExchange.published == ["test-book"])
  let listing = await transport.listing()
  _ = await lane.exchange(transport:transport,listing:listing,roots:["test-book":laneRoot],scope:"test")
  let stableCounts = await transport.counts(); precondition(stableCounts.0 == 0 && stableCounts.1 == 1)
  let invalidKey = ReadingPositionProtocol.prefix+"test-book/invalid-device.json"
  await transport.seed(invalidKey,Data("{\"version\":99}".utf8))
  let invalidListing = await transport.listing()
  _ = await lane.exchange(transport:transport,listing:invalidListing,roots:["test-book":laneRoot],scope:"test")
  _ = await lane.exchange(transport:transport,listing:invalidListing,roots:["test-book":laneRoot],scope:"test")
  let invalidCounts = await transport.counts();precondition(invalidCounts.0 == 1)
  let failedKey=ReadingPositionProtocol.prefix+"test-book/offline-device.json"
  await transport.seed(failedKey,Data("{}".utf8));await transport.markFailed(failedKey)
  let failedListing=await transport.listing()
  let failed=await lane.exchange(transport:transport,listing:failedListing,roots:["test-book":laneRoot],scope:"test")
  let backedOff=await lane.exchange(transport:transport,listing:failedListing,roots:["test-book":laneRoot],scope:"test")
  let failedCounts=await transport.counts();precondition(failed.errors.count == 1 && backedOff.errors.isEmpty && failedCounts.0 == 2)
  var samePlace=laneEvent
  samePlace.id="same-place-peer";samePlace.deviceId="peer-device";samePlace.originId="peer-origin";samePlace.sequence=1
  samePlace.compatibilityAt=11;samePlace.occurredAt=9;samePlace.seen=[laneEvent.originId:laneEvent.sequence]
  let samePlaceMoved = try laneStore.merge(ReadingPositionJournal(bookId:"test-book",deviceId:"peer-device",events:[samePlace],heads:[samePlace]),root:laneRoot)
  precondition(!samePlaceMoved)
  let afterSamePlace=laneSession.navigate(bookmark:Bookmark(chapterIndex:0,progress:0.25,characterCount:25,lastModified:Date(timeIntervalSinceReferenceDate:1)))!
  precondition(afterSamePlace.observes(samePlace) && afterSamePlace.compatibilityAt > samePlace.compatibilityAt)
  _ = laneStore.record(root:laneRoot,event:afterSamePlace)
  let imported = laneStore.importExplicit(bookId:"test-book",root:laneRoot,bookmark:Bookmark(chapterIndex:0,progress:0.1,characterCount:10,lastModified:Date(timeIntervalSinceReferenceDate:1)))
  precondition(imported?.progress == 0.1 && laneStore.snapshot(bookId:"test-book").winner?.action == "ttuImport")
  // The lane remembers each bookmark's modification time across launches, yet a bookmark
  // written while no lane was running is still observed by a new lane on its first exchange.
  try BookStorage.save(Bookmark(chapterIndex:0,progress:0.75,characterCount:75,lastModified:Date.now.addingTimeInterval(60)),inside:laneRoot,as:FileNames.bookmark)
  let restarted=HttpReadingPositionLane(store:laneStore)
  let restartListing=await transport.listing()
  _ = await restarted.exchange(transport:transport,listing:restartListing,roots:["test-book":laneRoot],scope:"test")
  precondition(laneStore.snapshot(bookId:"test-book").winner?.position.progress == 0.75)
  let budgetRoot=root.appendingPathComponent("budget-book")
  try FileManager.default.createDirectory(at:budgetRoot,withIntermediateDirectories:true)
  let budgetStore=ReadingPositionRepository(directory:root.appendingPathComponent("budget-positions"),device:ReadingDevice(id:"receiver",name:"iPad"))
  let budgetLane=HttpReadingPositionLane(store:budgetStore), budgetTransport=MemoryTransport()
  for index in 1...35 {
   let writer="writer-\(index)"
   var event=laneEvent;event.id=writer;event.deviceId=writer;event.originId=writer;event.sequence=1
   event.occurredAt=Double(index);event.compatibilityAt=Double(index);event.seen=[:];event.position.progress=Double(index)/40
   let body=try JSONEncoder().encode(ReadingPositionJournal(bookId:"test-book",deviceId:writer,events:[event],heads:[event]))
   await budgetTransport.seed(ReadingPositionProtocol.prefix+"test-book/"+writer+".json",body)
  }
  let budgetListing=await budgetTransport.listing()
  _ = await budgetLane.exchange(transport:budgetTransport,listing:budgetListing,roots:["test-book":budgetRoot],scope:"budget")
  let firstBudgetCounts=await budgetTransport.counts();precondition(firstBudgetCounts.0 == 32)
  _ = await budgetLane.exchange(transport:budgetTransport,listing:budgetListing,roots:["test-book":budgetRoot],scope:"budget")
  _ = await budgetLane.exchange(transport:budgetTransport,listing:budgetListing,roots:["test-book":budgetRoot],scope:"budget")
  let finalBudgetCounts=await budgetTransport.counts();precondition(finalBudgetCounts.0 == 35 && finalBudgetCounts.1 == 0)
  // A journal commit whose bookmark projection was never written (the app was killed between
  // the two writes, or the bookmark write failed) is still projected after the next launch.
  do {
   let book = root.appendingPathComponent("projection-book"), positions = root.appendingPathComponent("projection-positions")
   try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
   let device = ReadingDevice(id: "ios-device", name: "iPhone")
   let store = ReadingPositionRepository(directory: positions, device: device)
   let session = store.open(bookId: "b", root: book)
   let first = session.navigate(bookmark: Bookmark(chapterIndex: 0, progress: 0.2, characterCount: 20, lastModified: Date(timeIntervalSinceReferenceDate: 1000)))!
   precondition(store.record(root: book, event: first)?.progress == 0.2)
   let projectionTransport = MemoryTransport()
   _ = await HttpReadingPositionLane(store: store).exchange(transport: projectionTransport, listing: [:], roots: ["b": book], scope: "s")
   try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: book.path)
   let second = session.navigate(bookmark: Bookmark(chapterIndex: 0, progress: 0.6, characterCount: 60, lastModified: Date(timeIntervalSinceReferenceDate: 2000)))!
   _ = store.record(root: book, event: second)
   try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: book.path)
   precondition(BookStorage.loadBookmark(root: book)?.progress == 0.2, "fixture: the bookmark write failed")
   let relaunched = ReadingPositionRepository(directory: positions, device: device)
   precondition(relaunched.snapshot(bookId: "b").winner?.position.progress == 0.6, "fixture: the journal holds 0.6")
   let projectionListing = await projectionTransport.listing()
   _ = await HttpReadingPositionLane(store: relaunched).exchange(transport: projectionTransport, listing: projectionListing, roots: ["b": book], scope: "s")
   precondition(BookStorage.loadBookmark(root: book)?.progress == 0.6, "the journal winner is projected after relaunch")
  }
  print("PASS: intent, backwards clock, causal merge, 50-event retention, restart, wire round trip, deletion, lane dedupe, invalid body memory, failed-key backoff, explicit TTU import, projection after relaunch")
 }
}
