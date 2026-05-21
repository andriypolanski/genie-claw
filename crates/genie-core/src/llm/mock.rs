//! In-memory `LlmBackendClient` for tests. Issue #21, IS-2.
//!
//! Implements the same `LlmBackendClient` trait the real backends do
//! (llama.cpp, genie-ai-runtime) so anywhere `LlmClient` is consumed the
//! mock can be dropped in. Lets `tests/voice_loop_integration.rs` exercise
//! the LLM-driven part of the voice cycle without a live model server.
//!
//! The mock is deliberately tiny — it does NOT try to be a smart fixture:
//! it returns the next scripted reply on each call, streams it token by
//! token if `chat_stream` is invoked, and reports healthy.

use anyhow::{Result, bail};
use async_trait::async_trait;
use std::sync::Mutex;

use super::{LlmBackendClient, Message, ResponseFormat};

/// Scripted-reply LLM backend.
///
/// Construct with a queue of replies; each call to `chat_with_format` or
/// `chat_stream` consumes the next reply in order. When the queue is empty
/// the backend returns the configured fallback (`Result::Err` by default,
/// or a fixed string if set via [`MockLlmBackend::with_fallback`]).
pub struct MockLlmBackend {
    replies: Mutex<Vec<String>>,
    fallback: Option<String>,
    backend_name: String,
}

impl MockLlmBackend {
    /// New mock that will replay `replies` in order. After the last reply
    /// is consumed, further calls return `Err`.
    pub fn new<I, S>(replies: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut q: Vec<String> = replies.into_iter().map(Into::into).collect();
        q.reverse(); // pop from the back so we yield in insertion order
        Self {
            replies: Mutex::new(q),
            fallback: None,
            backend_name: "mock".into(),
        }
    }

    /// Configure a fallback reply used once the scripted queue is exhausted.
    /// Useful when a test wants the mock to "keep talking" rather than fail.
    pub fn with_fallback(mut self, fallback: impl Into<String>) -> Self {
        self.fallback = Some(fallback.into());
        self
    }

    fn next_reply(&self) -> Result<String> {
        let mut q = self.replies.lock().expect("mock LLM reply queue poisoned");
        if let Some(reply) = q.pop() {
            Ok(reply)
        } else if let Some(fallback) = &self.fallback {
            Ok(fallback.clone())
        } else {
            bail!("MockLlmBackend reply queue exhausted");
        }
    }
}

#[async_trait]
impl LlmBackendClient for MockLlmBackend {
    fn backend_name(&self) -> &str {
        &self.backend_name
    }

    async fn health(&self) -> bool {
        true
    }

    async fn chat_with_format(
        &self,
        _messages: &[Message],
        _max_tokens: Option<u32>,
        _response_format: Option<ResponseFormat>,
    ) -> Result<String> {
        self.next_reply()
    }

    async fn chat_stream(
        &self,
        _messages: &[Message],
        _max_tokens: Option<u32>,
        on_token: &mut (dyn for<'a> FnMut(&'a str) + Send),
    ) -> Result<String> {
        let reply = self.next_reply()?;
        // Stream word-by-word so callers see the streaming code path.
        for token in reply.split_inclusive(' ') {
            on_token(token);
        }
        Ok(reply)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn returns_scripted_replies_in_order() {
        let mock = MockLlmBackend::new(["first", "second"]);
        assert_eq!(
            mock.chat_with_format(&[], None, None).await.unwrap(),
            "first"
        );
        assert_eq!(
            mock.chat_with_format(&[], None, None).await.unwrap(),
            "second"
        );
        assert!(mock.chat_with_format(&[], None, None).await.is_err());
    }

    #[tokio::test]
    async fn fallback_kicks_in_after_exhaustion() {
        let mock = MockLlmBackend::new(["only"]).with_fallback("filler");
        assert_eq!(
            mock.chat_with_format(&[], None, None).await.unwrap(),
            "only"
        );
        assert_eq!(
            mock.chat_with_format(&[], None, None).await.unwrap(),
            "filler"
        );
        assert_eq!(
            mock.chat_with_format(&[], None, None).await.unwrap(),
            "filler"
        );
    }

    #[tokio::test]
    async fn stream_emits_tokens_and_returns_full_reply() {
        let mock = MockLlmBackend::new(["hello there friend"]);
        let mut seen = String::new();
        let full = mock
            .chat_stream(&[], None, &mut |tok| seen.push_str(tok))
            .await
            .unwrap();
        assert_eq!(full, "hello there friend");
        assert_eq!(seen, "hello there friend");
    }

    #[tokio::test]
    async fn backend_name_is_mock_and_health_is_true() {
        let mock = MockLlmBackend::new(Vec::<String>::new());
        assert_eq!(mock.backend_name(), "mock");
        assert!(mock.health().await);
    }
}
