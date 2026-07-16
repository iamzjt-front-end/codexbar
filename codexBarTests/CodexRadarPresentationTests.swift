import AppKit
import SwiftUI
import XCTest
@testable import codexAppBar

final class CodexRadarPresentationTests: XCTestCase {
    func testMatrixUsesFiveStandardEffortsAndStableFamilyOrder() {
        let modelIQ = CodexRadarModelIQ(
            latest: entry(score: 120, model: "gpt-5.6-sol", effort: "medium"),
            comparisons: [
                "luna_max": comparison(model: "gpt-5.6-luna", effort: "max", score: 120),
                "terra_high": comparison(model: "gpt-5.6-terra", effort: "high", score: 105),
                "gpt_55_high": comparison(model: "gpt-5.5", effort: "high", score: 100)
            ]
        )

        let matrix = CodexRadarPresentation.matrix(from: modelIQ)

        XCTAssertEqual(matrix.columns.map(\.id), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(matrix.columns.map(\.label), ["low", "med", "high", "xh", "max"])
        XCTAssertEqual(matrix.rows.map(\.displayName), ["Sol", "Terra", "Luna", "GPT-5.5"])
        XCTAssertNil(matrix.rows[1].cell(for: "max"))
        XCTAssertEqual(matrix.rows[1].cell(for: "high")?.score, 105)
    }

    func testLatestWinsWhenTheSameCellAlsoExistsInComparisons() {
        let modelIQ = CodexRadarModelIQ(
            latest: entry(score: 120, model: "gpt-5.6-sol", effort: "max", passed: 8, tasks: 10),
            comparisons: [
                "sol_max": comparison(model: "gpt-5.6-sol", effort: "max", score: 90)
            ]
        )

        let matrix = CodexRadarPresentation.matrix(from: modelIQ)
        let cell = matrix.rows.first?.cell(for: "max")

        XCTAssertEqual(cell?.sourceID, "latest")
        XCTAssertEqual(cell?.score, 120)
        XCTAssertEqual(cell?.passCountText, "8/10")
    }

    func testRankingUsesScoreThenCodexRadarDisplayOrder() {
        let effortWinner = CodexRadarModelIQ(
            latest: nil,
            comparisons: [
                "sol_medium": comparison(model: "gpt-5.6-sol", effort: "medium", score: 120),
                "luna_max": comparison(model: "gpt-5.6-luna", effort: "max", score: 120)
            ]
        )
        let familyWinner = CodexRadarModelIQ(
            latest: nil,
            comparisons: [
                "sol_max": comparison(model: "gpt-5.6-sol", effort: "max", score: 120),
                "terra_max": comparison(model: "gpt-5.6-terra", effort: "max", score: 120)
            ]
        )

        let effortMatrix = CodexRadarPresentation.matrix(from: effortWinner)
        let familyMatrix = CodexRadarPresentation.matrix(from: familyWinner)

        XCTAssertEqual(effortMatrix.cell(id: effortMatrix.bestCellID)?.displayName, "Sol medium")
        XCTAssertEqual(familyMatrix.cell(id: familyMatrix.bestCellID)?.displayName, "Sol max")
    }

    func testTopThreeRanksRemainDistinctWhenScoresTie() {
        let modelIQ = CodexRadarModelIQ(
            latest: entry(score: 105, model: "gpt-5.6-sol", effort: "max"),
            comparisons: [
                "luna_max": comparison(model: "gpt-5.6-luna", effort: "max", score: 120),
                "sol_medium": comparison(model: "gpt-5.6-sol", effort: "medium", score: 120),
                "terra_high": comparison(model: "gpt-5.6-terra", effort: "high", score: 105)
            ]
        )

        let matrix = CodexRadarPresentation.matrix(from: modelIQ)
        let rankedNames = matrix.rankedCellIDs.prefix(3).compactMap { matrix.cell(id: $0)?.displayName }

        XCTAssertEqual(rankedNames, ["Sol medium", "Luna max", "Sol max"])
        XCTAssertEqual(matrix.rank(of: try! XCTUnwrap(matrix.cell(id: matrix.rankedCellIDs[0]))), 1)
        XCTAssertEqual(matrix.rank(of: try! XCTUnwrap(matrix.cell(id: matrix.rankedCellIDs[1]))), 2)
        XCTAssertEqual(matrix.rank(of: try! XCTUnwrap(matrix.cell(id: matrix.rankedCellIDs[2]))), 3)
    }

    func testUnknownModelsAndEffortsAreAppendedWithoutDroppingData() {
        let modelIQ = CodexRadarModelIQ(
            latest: nil,
            comparisons: [
                "gpt_57_ultra": comparison(model: "gpt-5.7", effort: "ultra", score: 130),
                "gpt_55_high": comparison(model: "gpt-5.5", effort: "high", score: 100)
            ]
        )

        let matrix = CodexRadarPresentation.matrix(from: modelIQ)

        XCTAssertEqual(matrix.columns.map(\.id), ["low", "medium", "high", "xhigh", "max", "ultra"])
        XCTAssertEqual(matrix.rows.map(\.displayName), ["GPT-5.5", "GPT-5.7"])
        XCTAssertEqual(matrix.rows[1].cell(for: "ultra")?.score, 130)
    }

    func testMissingScoresAreTreatedAsUnavailableCells() {
        let modelIQ = CodexRadarModelIQ(
            latest: CodexRadarModelIQEntry(model: "gpt-5.6-sol", reasoningEffort: "max"),
            comparisons: [
                "terra_high": CodexRadarModelIQComparison(
                    label: "Terra high",
                    model: "gpt-5.6-terra",
                    reasoningEffort: "high",
                    latest: CodexRadarModelIQEntry(model: "gpt-5.6-terra", reasoningEffort: "high")
                )
            ]
        )

        let matrix = CodexRadarPresentation.matrix(from: modelIQ)

        XCTAssertTrue(matrix.rows.isEmpty)
        XCTAssertNil(matrix.bestCellID)
    }

    func testScoreFormattingDropsMeaninglessDecimalOnly() {
        XCTAssertEqual(CodexRadarPresentation.scoreText(105), "105")
        XCTAssertEqual(CodexRadarPresentation.scoreText(112.5), "112.5")
    }

    func testFamilyResolutionUsesNativeSymbolMetadata() {
        XCTAssertEqual(CodexRadarModelFamily.resolve(model: "Sol", label: nil, id: nil), .sol)
        XCTAssertEqual(CodexRadarModelFamily.resolve(model: "Luna", label: nil, id: nil), .luna)
        XCTAssertEqual(CodexRadarModelFamily.resolve(model: nil, label: "GPT-5.6-Terra-high", id: nil), .terra)
        XCTAssertEqual(CodexRadarModelFamily.terra.symbolName, "globe.americas")
        XCTAssertEqual(CodexRadarModelFamily.luna.symbolName, "moon")
        XCTAssertEqual(CodexRadarModelFamily.sol.symbolName, "sun.max")
    }

    @MainActor
    func testMatrixViewRendersAtPopoverWidthWithoutFocusState() throws {
        let modelIQ = CodexRadarModelIQ(
            latest: entry(score: 105, model: "gpt-5.6-sol", effort: "max", passed: 7, tasks: 10),
            comparisons: [
                "terra_max": comparison(model: "gpt-5.6-terra", effort: "max", score: 90),
                "terra_high": comparison(model: "gpt-5.6-terra", effort: "high", score: 105),
                "luna_max": comparison(model: "gpt-5.6-luna", effort: "max", score: 120),
                "luna_high": comparison(model: "gpt-5.6-luna", effort: "high", score: 105),
                "sol_xhigh": comparison(model: "gpt-5.6-sol", effort: "xhigh", score: 105),
                "sol_high": comparison(model: "gpt-5.6-sol", effort: "high", score: 105),
                "sol_medium": comparison(model: "gpt-5.6-sol", effort: "medium", score: 120),
                "sol_low": comparison(model: "gpt-5.6-sol", effort: "low", score: 90)
            ]
        )
        let matrix = CodexRadarPresentation.matrix(from: modelIQ)
        let content = VStack(alignment: .leading, spacing: 8) {
            CodexRadarMatrixView(
                matrix: matrix,
                hoveredCellID: .constant(nil)
            )

            if let best = matrix.cell(id: matrix.bestCellID) {
                Text("第 1 名：\(best.displayName) · IQ \(CodexRadarPresentation.scoreText(best.score)) · 通过 8/10 题")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 276, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try pngData.write(to: URL(fileURLWithPath: "/tmp/codexbar-matrix-rendered.png"))

        XCTAssertEqual(image.size.width, 300, accuracy: 0.5)
    }

    private func comparison(
        model: String,
        effort: String,
        score: Double
    ) -> CodexRadarModelIQComparison {
        CodexRadarModelIQComparison(
            label: "\(model) \(effort)",
            model: model,
            reasoningEffort: effort,
            latest: entry(score: score, model: model, effort: effort)
        )
    }

    private func entry(
        score: Double? = nil,
        model: String? = nil,
        effort: String? = nil,
        passed: Int? = nil,
        tasks: Int? = nil
    ) -> CodexRadarModelIQEntry {
        CodexRadarModelIQEntry(
            score: score,
            status: score.map { $0 >= 100 ? "green" : ($0 >= 90 ? "yellow" : "red") },
            passed: passed,
            tasks: tasks,
            model: model,
            reasoningEffort: effort
        )
    }
}
