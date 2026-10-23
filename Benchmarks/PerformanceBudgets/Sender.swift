import Foundation

// A long-lived sender avoids charging compiler/process startup to each operation.
while let line = readLine(), let data = line.data(using: .utf8),
    let request = try? JSONSerialization.jsonObject(with: data) as? [String: String],
    let channel = request["channel"], let command = request["command"]
{
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("app.porpoise.Porpoise.debug." + channel), object: command, userInfo: nil, deliverImmediately: true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    print("sent")
    fflush(stdout)
}
