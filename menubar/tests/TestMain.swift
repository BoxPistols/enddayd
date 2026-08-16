import Foundation

/// テストの入口。
///
/// 件数（PLANNED）は手で宣言する。呼び忘れて 0 件でも「成功」と出る状態を
/// 避けるため、Harness が実行数と突き合わせて合わなければ落とす。
/// テストを足したらここも直すこと。
@main
struct TestMain {

    /// ConfParserTests 37 件 + LogReaderTests 17 件
    static let planned = 54

    static func main() {
        var harness = Harness()
        ConfParserTests.run(&harness)
        LogReaderTests.run(&harness)
        harness.finish(planned: planned)
    }
}
