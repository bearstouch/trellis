import Darwin
import TrellisCLI

exit(CLI.run(Array(CommandLine.arguments.dropFirst()), environment: .live))
