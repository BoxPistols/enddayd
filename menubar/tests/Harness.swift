import Foundation

/// 最小のテストハーネス。XCTest はフル Xcode を要求するので使わない
/// （このリポジトリは Command Line Tools だけでビルドできることを保っている）。
///
/// 出力は TAP に寄せてある。落ちた表明はその場で理由を出し、
/// 最後に件数を突き合わせて、宣言した数だけ実行されたかを確かめる。
struct Harness {
    private var passed = 0
    private var failed = 0
    private var index = 0

    mutating func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        index += 1
        if condition {
            passed += 1
            print("ok \(index) - \(name)")
        } else {
            failed += 1
            print("not ok \(index) - \(name)")
            let text = detail()
            if !text.isEmpty { print("# \(text)") }
        }
    }

    mutating func equal<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
        expect(actual == expected, name, "期待 \(expected) / 実際 \(actual)")
    }

    /// 宣言した件数と実際に実行された件数を突き合わせて終了する。
    /// 数が合わないのは呼び忘れなので、通ったことにしない。
    func finish(planned: Int) -> Never {
        print("1..\(index)")
        if index != planned {
            FileHandle.standardError.write(
                Data("宣言 \(planned) 件に対して \(index) 件しか実行されていません\n".utf8))
            exit(1)
        }
        if failed > 0 {
            FileHandle.standardError.write(Data("\(failed) 件が失敗しました\n".utf8))
            exit(1)
        }
        print("planned=\(planned) executed=\(index) passed=\(passed)")
        exit(0)
    }
}
