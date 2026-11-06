import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SwiftCut

struct ExportProgressTests {
    @MainActor static func job(progress: Double) -> ExportJob {
        let job = ExportJob(name: "Timeline", preset: .builtIn("ProRes 422"), outputURL: URL(filePath: "/tmp/Timeline - ProRes.mov"))
        job.progress = progress
        return job
    }

    @Test @MainActor func timeLeftFollowsThePaceSoFar() {
        let job = Self.job(progress: 0.25)
        // A quarter done in 30 seconds: 90 more to go.
        #expect(abs(job.secondsRemaining(now: job.started.addingTimeInterval(30))! - 90) < 0.001)
        // Too early to tell.
        #expect(job.secondsRemaining(now: job.started.addingTimeInterval(1)) == nil)
        job.progress = 0.01
        #expect(job.secondsRemaining(now: job.started.addingTimeInterval(30)) == nil)
        // Nothing left once it stops.
        job.progress = 0.5
        job.state = .cancelled
        #expect(job.secondsRemaining(now: job.started.addingTimeInterval(30)) == nil)
    }

    @Test func timeLeftText() {
        #expect(ExportProgressRow.remainingText(nil) == "Estimating…")
        #expect(ExportProgressRow.remainingText(0.2) == "1 sec left")
        #expect(ExportProgressRow.remainingText(42) == "42 sec left")
        #expect(ExportProgressRow.remainingText(125) == "2:05 left")
        #expect(ExportProgressRow.remainingText(3725) == "1:02:05 left")
    }

    @Test @MainActor func rowDraws() throws {
        let row = ExportProgressRow(job: Self.job(progress: 0.42)).padding(12).frame(width: 300).background(.white)
        let renderer = ImageRenderer(content: row)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appending(path: "export-progress-row.png"))
    }
}
