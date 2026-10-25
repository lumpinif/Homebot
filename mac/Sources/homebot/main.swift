import Foundation
import HomebotCLI

exit(await HomebotCLI.run(Array(CommandLine.arguments.dropFirst())))
