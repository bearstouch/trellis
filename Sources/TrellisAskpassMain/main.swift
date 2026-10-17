import Darwin
import Foundation
import TrellisAskpass

// Run by /usr/bin/ssh as SSH_ASKPASS for sessions of hosts with a saved password.
exit(AskpassHelper(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment).run())
