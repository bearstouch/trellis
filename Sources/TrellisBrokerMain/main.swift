import Foundation
import TrellisBroker

// Started detached by Trellis when "Keep sessions running after quit" is on (FR-R03).
exit(BrokerServer.main(arguments: CommandLine.arguments))
