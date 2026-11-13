import Foundation

@main
enum Entry {
    static func main() {
        if CLI.run(CommandLine.arguments) { return }
        RulebookApp.main()
    }
}
