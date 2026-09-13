import XCTest
import Foundation
@testable import CNSUI
@testable import CNSCore

@MainActor
final class AppUpdateViewModelTests: XCTestCase {
    // Tests: одновременные model/app progress; cancel app не вызывает model.cancel; 
    // cancel model не вызывает updater.cancel; repeated check -> 1 request; 
    // late success/error старого UUID; cancel до/после stage; старый cleanup после нового staged; 
    // ошибка checksum не становится ready; прогресс достигает ready только после verification.
}
