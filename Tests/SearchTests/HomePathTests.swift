import Foundation
import Testing

@testable import Search

private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

@Test func placesATildeInTheHomeFolder() {
    #expect(HomePath.folder("~/Applications", home: home).path == "/Users/someone/Applications")
    #expect(HomePath.folder("~", home: home).path == "/Users/someone")
    #expect(HomePath.folder("~/", home: home).path == "/Users/someone")
    #expect(HomePath.folder("/Applications", home: home).path == "/Applications")
}

@Test func acceptsOnlyPathsItCanPlace() {
    for path in ["/Applications", "~", "~/Apps"] {
        #expect(HomePath.isValid(path), "\(path)")
    }
    for path in ["", "Applications", "~someone/Apps", "./Apps"] {
        #expect(!HomePath.isValid(path), "\(path)")
    }
}
