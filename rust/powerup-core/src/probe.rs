//! Bridge probes (stage 2.1): three functions that exist only to prove the
//! plumbing between the core and an OS app — a value round trip, an error,
//! and a panic the bridge must contain. They carry no product logic.

use crate::CoreError;

/// Returns `text` unchanged.
pub fn echo(text: String) -> Result<String, CoreError> {
    Ok(text)
}

/// Always fails with `message`.
pub fn fail_with(message: String) -> Result<String, CoreError> {
    Err(CoreError::Failed { message })
}

/// Always panics with `message`. The one deliberate panic in the core: the
/// bridge's panic boundary is tested against it.
pub fn panic_with(message: String) -> Result<String, CoreError> {
    panic!("{message}")
}
