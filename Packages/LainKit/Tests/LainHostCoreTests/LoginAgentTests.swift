#if os(macOS)
import Testing
@testable import LainHostCore

@Suite struct LoginAgentDecision {
    typealias D = LoginAgent.Decision

    @Test func theAgentAlwaysRunsAndReplacesManualCopies() {
        #expect(LoginAgent.decide(isAgent: true, othersRunning: false, state: .enabled, installed: true) == D.run)
        #expect(LoginAgent.decide(isAgent: true, othersRunning: true, state: .enabled, installed: true) == D.terminateOthersAndRun)
    }

    @Test func aManualCopyNeverRunsBesideAnotherHost() {
        for state in [LoginAgent.State.enabled, .requiresApproval, .notRegistered, .notFound] {
            #expect(LoginAgent.decide(isAgent: false, othersRunning: true, state: state, installed: true) == D.exitAlreadyRunning)
        }
    }

    @Test func aManualCopyHandsOverToTheAgent() {
        #expect(LoginAgent.decide(isAgent: false, othersRunning: false, state: .enabled, installed: true) == D.startAgentAndExit)
        #expect(LoginAgent.decide(isAgent: false, othersRunning: false, state: .enabled, installed: false) == D.startAgentAndExit)
    }

    @Test func onlyAnInstalledCopyRegistersItself() {
        #expect(LoginAgent.decide(isAgent: false, othersRunning: false, state: .notRegistered, installed: true) == D.registerAgentAndExit)
        #expect(LoginAgent.decide(isAgent: false, othersRunning: false, state: .notRegistered, installed: false) == D.run)
    }

    @Test func pendingApprovalOrMissingPlistRunsHere() {
        #expect(LoginAgent.decide(isAgent: false, othersRunning: false, state: .requiresApproval, installed: true) == D.run)
        #expect(LoginAgent.decide(isAgent: false, othersRunning: false, state: .notFound, installed: true) == D.run)
    }
}
#endif
