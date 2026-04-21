import Foundation

let targets = [
    "https://ifconfig.me",
    "https://ifconfig.io",
    "https://ipinfo.io/ip",
]

let sem = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

let config = URLSessionConfiguration.ephemeral
config.timeoutIntervalForRequest = 10
let session = URLSession(configuration: config)

let group = DispatchGroup()
for target in targets {
    guard let url = URL(string: target) else { continue }
    group.enter()
    session.dataTask(with: url) { data, response, error in
        defer { group.leave() }
        if let error {
            print("\(target) ERROR: \(error.localizedDescription)")
            exitCode = 2
            return
        }
        let body = String(data: data ?? Data(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        print("\(target) → \(body)")
    }.resume()
}
group.notify(queue: .main) { sem.signal() }
sem.wait()
exit(exitCode)
