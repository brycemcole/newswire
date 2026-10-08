import Testing
@testable import Newswire

struct PushRegistrationDecisionTests {
    @Test func permissionAndOptInControlRegistration() {
        #expect(PushRegistrationDecision.resolve(authorized: false, undetermined: false, enabled: false) == .disabled)
        #expect(PushRegistrationDecision.resolve(authorized: false, undetermined: true, enabled: true) == .requestPermission)
        #expect(PushRegistrationDecision.resolve(authorized: true, undetermined: false, enabled: true) == .register)
        #expect(PushRegistrationDecision.resolve(authorized: false, undetermined: false, enabled: true) == .denied)
    }

}
