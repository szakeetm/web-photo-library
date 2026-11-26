import Foundation
import Testing
@testable import PhotoAPI

@Suite struct BoundedPipeTests {
    @Test func theMakerWaitsForASlowReader() async throws {
        let pipe = BoundedPipe(capacity: 4)
        let producer = Task {
            for i in 0..<100 { try await pipe.send(Data([UInt8(i)])) }
            await pipe.finish()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await pipe.buffered == 4)   // not 100: the maker is waiting
        var got: [UInt8] = []
        while let d = try await pipe.next() { got += d }
        #expect(got == (0..<100).map { UInt8($0) })
        try await producer.value
    }

    @Test func aReaderThatLeavesStopsTheMaker() async throws {
        let pipe = BoundedPipe(capacity: 2)
        let producer = Task { for _ in 0..<10 { try await pipe.send(Data([1])) } }
        try await Task.sleep(for: .milliseconds(50))
        await pipe.close()
        await #expect(throws: CancellationError.self) { try await producer.value }
    }

    @Test func aFailureReachesTheReader() async throws {
        struct Boom: Error {}
        let pipe = BoundedPipe(capacity: 2)
        try await pipe.send(Data([1]))
        await pipe.finish(throwing: Boom())
        #expect(try await pipe.next() == Data([1]))
        await #expect(throws: Boom.self) { try await pipe.next() }
    }
}
