import LainHostCore
import Testing
@testable import LainHost

@Suite struct PermissionsStatusTests {
    @Test func allGrantedHasNoMissingPermissions() {
        let perms = HostPermissionStatus(accessibility: true,
                                         screenRecording: true,
                                         localNetwork: .allowed,
                                         loginAgent: .enabled)
        #expect(!perms.hasMissing)
        #expect(perms.missingNames.isEmpty)
    }

    @Test func checkingLocalNetworkIsNotTreatedAsDenied() {
        let perms = HostPermissionStatus(accessibility: true,
                                         screenRecording: true,
                                         localNetwork: .checking,
                                         loginAgent: .notRegistered)
        #expect(!perms.hasMissing)
        #expect(perms.missingNames.isEmpty)
    }

    @Test func reportsAllMissingPermissionsInOrder() {
        let perms = HostPermissionStatus(accessibility: false,
                                         screenRecording: false,
                                         localNetwork: .denied,
                                         loginAgent: .requiresApproval)
        #expect(perms.hasMissing)
        #expect(perms.missingNames == ["Accessibility", "Screen Recording", "Local Network", "Start at Login"])
        #expect(perms.summaryBadge == "4 missing")
    }

    @Test func singularBadgeWhenOneMissing() {
        let perms = HostPermissionStatus(accessibility: false,
                                         screenRecording: true,
                                         localNetwork: .allowed,
                                         loginAgent: .enabled)
        #expect(perms.missingNames == ["Accessibility"])
        #expect(perms.summaryBadge == "1 missing")
    }
}
