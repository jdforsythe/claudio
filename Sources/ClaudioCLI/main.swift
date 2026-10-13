import Foundation

// `claudio hook` is dispatched before ArgumentParser is touched (document 04 §4.2).
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "hook" {
    exit(HookReceiver.run())
}
Claudio.main()
