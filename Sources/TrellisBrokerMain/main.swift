#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif
import TrellisBroker

// Started detached by Trellis when "Keep sessions running after quit" is on (FR-R03), or by `bridge` on a remote host
// (FR-RW06). No Foundation import: on Linux it would link ICU into the static helper.
exit(BrokerServer.main(arguments: CommandLine.arguments))
