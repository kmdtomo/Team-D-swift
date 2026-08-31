import CompositionKit
import Testing

struct ImageComparisonStateTests {
    @Test func initialStateIsUnselectedAndUnapproved() {
        let state = makeState()
        #expect(state.selection == nil)
        #expect(state.approvedOutputID == nil)
        #expect(state.selectableChoices == [.original, .composite])
    }

    @Test func selectionAndExplicitConfirmationAreSeparate() {
        var state = makeState()
        state.select(.original)
        #expect(state.selection == .original)
        #expect(state.approvedOutputID == nil)

        state.confirmSelection()
        #expect(state.approvedOutputID == "front-original")
    }

    @Test func originalAndCompositeCanEachBeExplicitlyApproved() {
        var state = makeState()
        state.select(.original)
        state.confirmSelection()
        #expect(state.approvedOutputID == "front-original")

        state.select(.composite)
        #expect(state.approvedOutputID == nil)
        state.confirmSelection()
        #expect(state.approvedOutputID == "composite-v1")
    }

    @Test func approvalChoiceLabelIsDerivedWithoutExposingInternalID() {
        var state = makeState()
        state.select(.composite)
        state.confirmSelection()

        #expect(state.approvedOutputID == "composite-v1")
        #expect(state.approvedChoice == .composite)
        #expect(state.approvedChoiceLabel == "背景を変更した画像")
        #expect(state.approvedChoiceLabel?.contains("composite-v1") == false)
    }

    @Test func missingOrInvalidCompositeCannotBeExposedOrSelected() {
        let missing = CompositeComparisonAvailability(candidateID: nil, isComplete: true, isValid: true)
        let incomplete = CompositeComparisonAvailability(candidateID: "partial", isComplete: false, isValid: true)
        let invalid = CompositeComparisonAvailability(candidateID: "invalid", isComplete: true, isValid: false)

        for availability in [missing, incomplete, invalid] {
            var state = ImageComparisonState(originalID: "front-original", compositeAvailability: availability)
            #expect(state.composite == nil)
            #expect(state.selectableChoices == [.original])
            state.select(.composite)
            state.confirmSelection()
            #expect(state.selection == nil)
            #expect(state.approvedOutputID == nil)
        }
    }

    @Test func oneViewportModelsBothImagesAndSanitizesInvalidValues() {
        var state = makeState()
        let viewport = ComparisonViewport(zoom: 2.5, centerX: 0.2, centerY: 0.8)
        state.setViewport(viewport)
        #expect(state.viewport == viewport)

        let sanitized = ComparisonViewport(zoom: .infinity, centerX: -.infinity, centerY: .nan)
        #expect(sanitized == .init(zoom: 1, centerX: 0.5, centerY: 0.5))
    }

    @Test func regenerationInvalidatesCompositeSelectionAndApproval() {
        var state = makeState()
        state.select(.composite)
        state.confirmSelection()
        state.replaceComposite(with: .init(candidateID: "composite-v2", isComplete: true, isValid: true))

        #expect(state.composite?.id == "composite-v2")
        #expect(state.selection == nil)
        #expect(state.approvedOutputID == nil)
    }

    @Test func beginningRegenerationSynchronouslyInvalidatesCompositeSelectionAndApproval() {
        var state = makeState()
        state.select(.composite)
        state.confirmSelection()

        state.beginCompositeRegeneration()

        #expect(state.composite == nil)
        #expect(state.selection == nil)
        #expect(state.approvedOutputID == nil)
    }

    @Test func beginningRegenerationPreservesAnApprovedOriginal() {
        var state = makeState()
        state.select(.original)
        state.confirmSelection()

        state.beginCompositeRegeneration()

        #expect(state.composite == nil)
        #expect(state.selection == .original)
        #expect(state.approvedOutputID == "front-original")
        #expect(state.approvedChoiceLabel == "元の画像")
    }

    @Test func changingSelectionAfterApprovalResetsApproval() {
        var state = makeState()
        state.select(.original)
        state.confirmSelection()
        state.select(.composite)

        #expect(state.selection == .composite)
        #expect(state.approvedOutputID == nil)
    }

    private func makeState() -> ImageComparisonState {
        .init(
            originalID: "front-original",
            compositeAvailability: .init(candidateID: "composite-v1", isComplete: true, isValid: true)
        )
    }
}
