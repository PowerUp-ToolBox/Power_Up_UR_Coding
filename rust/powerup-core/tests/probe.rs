use powerup_core::probe::{echo, fail_with, panic_with};
use powerup_core::CoreError;

#[test]
fn echo_returns_the_text_unchanged() {
    assert_eq!(echo("hello 世界".to_string()), Ok("hello 世界".to_string()));
}

#[test]
fn fail_with_returns_the_message_as_an_error() {
    let error = fail_with("no microphone".to_string()).unwrap_err();
    assert_eq!(
        error,
        CoreError::Failed {
            message: "no microphone".to_string()
        }
    );
    assert_eq!(error.to_string(), "no microphone");
}

#[test]
#[should_panic(expected = "boom")]
fn panic_with_panics_with_the_message() {
    let _ = panic_with("boom".to_string());
}
