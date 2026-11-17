import Testing
@testable import RecorderCore

@Suite struct ShotCaptionTests {
    @Test func trimsDedupesAndDropsJunk() {
        let lines = ["  Export complete ", "export complete", "•••", "--", "a", "Your video is ready to share with anyone today"]
        #expect(ShotCaption.shape(lines) == "Export complete Your video is ready to share with anyone")
    }
    @Test func dropsOCRNoiseTokens() {
        #expect(ShotCaption.shape([#"(Dr (kEyldDN ') (keyl "I Ikeyl"#, "Source Ledger: totals"]) == "Ikeyl Source Ledger: totals")
        #expect(ShotCaption.shape([#"(keyl ') ""#]) == nil)
    }

    @Test func nilWhenNothingUsable() {
        #expect(ShotCaption.shape([]) == nil)
        #expect(ShotCaption.shape(["~~~", " "]) == nil)
    }
    @Test func classifierLabelUnderscores() { #expect(ShotCaption.shape(["computer_monitor"]) == "computer monitor") }
}
