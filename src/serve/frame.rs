//! Length-prefixed JSON frames: a 4-byte big-endian payload length,
//! then that many bytes of UTF-8 JSON. One message per frame.

use serde::Serialize;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// Largest payload either side accepts. Bosun's messages are a few
/// KB; this only stops a confused peer from making us allocate
/// gigabytes off a garbage length.
pub const MAX_FRAME: usize = 16 * 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum FrameError {
    TooLarge(usize),
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FrameError::TooLarge(n) => write!(f, "frame of {n} bytes exceeds {MAX_FRAME}"),
        }
    }
}

/// Serialize `msg` into one complete frame.
pub fn encode<T: Serialize>(msg: &T) -> Vec<u8> {
    let body = serde_json::to_vec(msg).expect("protocol types always serialize");
    let mut out = Vec::with_capacity(body.len() + 4);
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    out.extend_from_slice(&body);
    out
}

/// Incremental decoder: push whatever bytes arrive, pop whole frames.
#[derive(Debug, Default)]
pub struct FrameDecoder {
    buf: Vec<u8>,
}

impl FrameDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    /// The next complete payload, if one has fully arrived.
    pub fn next_frame(&mut self) -> Result<Option<Vec<u8>>, FrameError> {
        if self.buf.len() < 4 {
            return Ok(None);
        }
        let len = u32::from_be_bytes(self.buf[..4].try_into().expect("4 bytes")) as usize;
        if len > MAX_FRAME {
            return Err(FrameError::TooLarge(len));
        }
        if self.buf.len() < 4 + len {
            return Ok(None);
        }
        let payload = self.buf[4..4 + len].to_vec();
        self.buf.drain(..4 + len);
        Ok(Some(payload))
    }

    /// Bytes buffered toward a frame that hasn't completed.
    pub fn pending(&self) -> usize {
        self.buf.len()
    }
}

/// Read one frame. `Ok(None)` on a clean EOF between frames.
pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> std::io::Result<Option<Vec<u8>>> {
    let mut len = [0u8; 4];
    match r.read_exact(&mut len).await {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_be_bytes(len) as usize;
    if len > MAX_FRAME {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            FrameError::TooLarge(len).to_string(),
        ));
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body).await?;
    Ok(Some(body))
}

/// Write one already-encoded frame.
pub async fn write_frame<W: AsyncWrite + Unpin>(w: &mut W, frame: &[u8]) -> std::io::Result<()> {
    w.write_all(frame).await?;
    w.flush().await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::serve::protocol::ClientMsg;

    #[test]
    fn encode_prefixes_big_endian_length() {
        let f = encode(&ClientMsg::Resync);
        let body = br#"{"t":"resync"}"#;
        assert_eq!(&f[..4], &(body.len() as u32).to_be_bytes());
        assert_eq!(&f[4..], body);
    }

    #[test]
    fn decoder_handles_split_and_coalesced_frames() {
        let a = encode(&ClientMsg::Resync);
        let b = encode(&ClientMsg::Hello {
            protocol: 1,
            client: Some("tést".into()),
        });
        let mut stream = a.clone();
        stream.extend_from_slice(&b);
        for split in 0..=stream.len() {
            let mut d = FrameDecoder::new();
            let mut got = Vec::new();
            for chunk in [&stream[..split], &stream[split..]] {
                d.push(chunk);
                while let Some(f) = d.next_frame().unwrap() {
                    got.push(f);
                }
            }
            assert_eq!(got, vec![a[4..].to_vec(), b[4..].to_vec()], "split {split}");
            assert_eq!(d.pending(), 0);
        }
    }

    #[test]
    fn decoder_rejects_oversized_length() {
        let mut d = FrameDecoder::new();
        d.push(&((MAX_FRAME as u32) + 1).to_be_bytes());
        assert_eq!(d.next_frame(), Err(FrameError::TooLarge(MAX_FRAME + 1)));
    }

    #[test]
    fn empty_payload_is_a_frame() {
        let mut d = FrameDecoder::new();
        d.push(&[0, 0, 0, 0]);
        assert_eq!(d.next_frame().unwrap(), Some(vec![]));
    }

    #[tokio::test]
    async fn async_read_write_round_trip() {
        let (mut a, mut b) = tokio::io::duplex(64);
        let frame = encode(&ClientMsg::Hello {
            protocol: 1,
            client: None,
        });
        let f2 = frame.clone();
        let writer = tokio::spawn(async move {
            write_frame(&mut a, &f2).await.unwrap();
            write_frame(&mut a, &f2).await.unwrap();
        });
        assert_eq!(
            read_frame(&mut b).await.unwrap().unwrap(),
            frame[4..].to_vec()
        );
        assert_eq!(
            read_frame(&mut b).await.unwrap().unwrap(),
            frame[4..].to_vec()
        );
        writer.await.unwrap();
        assert_eq!(read_frame(&mut b).await.unwrap(), None);
    }
}
