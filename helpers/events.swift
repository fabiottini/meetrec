// meetrec-events: events from the macOS Calendar app (every account in it: iCloud, Google,
// Exchange, CalDAV, subscriptions), as JSON for meet.py.
//
//   meetrec-events --request-access            ask for Calendar access (exit 0 if granted)
//   meetrec-events --status                    print the authorization status
//   meetrec-events --from ISO --to ISO         events in the range, JSON array on stdout

import EventKit
import Foundation

let store = EKEventStore()
let args = CommandLine.arguments

func fail(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func hasAccess() -> Bool {
    EKEventStore.authorizationStatus(for: .event) == .fullAccess
}

func requestAccess() -> Bool {
    if hasAccess() { return true }
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    store.requestFullAccessToEvents { ok, _ in granted = ok; sem.signal() }
    sem.wait()
    return granted
}

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func parseDate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s)
}

func person(_ p: EKParticipant?) -> [String: String] {
    guard let p else { return ["name": "", "email": ""] }
    var email = ""
    if p.url.scheme == "mailto" { email = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "").lowercased() }
    return ["name": p.name ?? "", "email": email]
}

if args.contains("--status") {
    let s = EKEventStore.authorizationStatus(for: .event)
    print(s == .fullAccess ? "granted" : s == .notDetermined ? "not-determined" : "denied")
    exit(0)
}

if args.contains("--request-access") {
    exit(requestAccess() ? 0 : 1)
}

guard let fromS = value("--from"), let toS = value("--to"),
      let from = parseDate(fromS), let to = parseDate(toS) else {
    fail("usage: meetrec-events --from ISO --to ISO | --request-access | --status", 64)
}
guard hasAccess() else { fail("no access to Calendar: allow MeetRec in System Settings > Privacy & Security > Calendars", 2) }

let iso = ISO8601DateFormatter()
let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
var out: [[String: Any]] = []
for e in store.events(matching: pred) {
    if e.status == .canceled { continue }
    out.append([
        "id": e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? UUID().uuidString,
        "subject": e.title ?? "",
        "start": iso.string(from: e.startDate),
        "end": iso.string(from: e.endDate),
        "all_day": e.isAllDay,
        "calendar": e.calendar?.title ?? "",
        "source": e.calendar?.source?.title ?? "",
        "organizer": person(e.organizer),
        "attendees": (e.attendees ?? []).filter { $0.participantType == .person || $0.participantType == .unknown }.map(person),
        "agenda": e.notes ?? "",
        "link": e.url?.absoluteString ?? "",
    ])
}
let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
