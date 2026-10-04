import WidgetKit
import SwiftUI

/// 제어 센터 컨트롤 + 잠금화면 위젯 (TASKS T-6.2). 둘 다 `qrguard://scan` 딥링크로 스캐너를 연다.
@main
struct QRGuardWidgetsBundle: WidgetBundle {
    var body: some Widget {
        QRGuardScanControl()
        QRGuardLockScreenWidget()
    }
}
