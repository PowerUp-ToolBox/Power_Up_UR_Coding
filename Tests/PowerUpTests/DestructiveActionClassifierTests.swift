import XCTest
@testable import PowerUp

/// A false positive costs one extra button press; a false negative costs
/// somebody's branch — so the destructive list is pinned case by case.
final class DestructiveActionClassifierTests: XCTestCase {

    func testDeleteKindIsAlwaysDestructive() {
        XCTAssertTrue(DestructiveActionClassifier.isDestructive(kind: "delete", title: "Remove file", detail: ""))
        XCTAssertTrue(DestructiveActionClassifier.isDestructive(kind: "DELETE", title: "", detail: ""))
    }

    func testClassicDestructiveCommands() {
        let destructive: [(String, String)] = [
            ("Run command", "rm -rf node_modules"),
            ("Run command", "sudo rm /etc/hosts"),
            ("Run command", "git reset --hard HEAD~3"),
            ("Run command", "git push --force origin main"),
            ("Run command", "git clean -fd"),
            ("Run command", "DROP TABLE users;"),
            ("Run command", "terraform destroy -auto-approve"),
            ("Run command", "kubectl delete deployment api"),
            ("Run command", "dd if=/dev/zero of=/dev/disk2"),
        ]
        for (title, detail) in destructive {
            XCTAssertTrue(DestructiveActionClassifier.isDestructive(kind: "execute", title: title, detail: detail),
                          "should be destructive: \(detail)")
        }
    }

    func testEverydayActionsAreNotDestructive() {
        let safe: [(String, String, String)] = [
            ("read", "Read File", "main.swift"),
            ("edit", "Edit File", "AppState.swift"),
            ("execute", "Run command", "swift test"),
            ("execute", "Run command", "git status"),
            ("execute", "Run command", "git commit -m \"fix\""),
            ("execute", "Run command", "npm install"),
            ("execute", "Run command", "ls -la ./rmdir-notes"),   // substring inside a path is fine? see below
        ]
        for (kind, title, detail) in safe.dropLast() {
            XCTAssertFalse(DestructiveActionClassifier.isDestructive(kind: kind, title: title, detail: detail),
                           "should be safe: \(detail)")
        }
    }

    func testBareForcePushAtEndOfCommandIsCaught() {
        // Regression (review finding): "push -f " needed a trailing space, so
        // a command ENDING in the flag slipped through.
        XCTAssertTrue(DestructiveActionClassifier.isDestructive(
            kind: "execute", title: "Run command", detail: "git push -f"))
        XCTAssertTrue(DestructiveActionClassifier.isDestructive(
            kind: "execute", title: "Run command", detail: "git push --force"))
    }

    func testDevNullRedirectionIsNotDestructive() {
        // Regression (review finding): "> /dev/" also matched the harmless
        // "> /dev/null" idiom; raw-device writes are caught via of=/dev/.
        XCTAssertFalse(DestructiveActionClassifier.isDestructive(
            kind: "execute", title: "Run command", detail: "npm test > /dev/null 2>&1"))
        XCTAssertTrue(DestructiveActionClassifier.isDestructive(
            kind: "execute", title: "Run command", detail: "dd if=image.iso of=/dev/disk2"))
    }

    func testInformedTradeoff_PathContainingPatternTriggersConfirm() {
        // Documented tradeoff: substring matching means a path that CONTAINS a
        // destructive token still asks for the extra press. That is the safe
        // direction — one extra press, never a lost branch.
        XCTAssertTrue(DestructiveActionClassifier.isDestructive(
            kind: "execute", title: "Run command", detail: "ls ./rmdir-notes"))
    }
}
