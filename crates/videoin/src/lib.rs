//! Minimal ffmpeg-piped frame decode (DESIGN.md S8 `videoin`, S1 "decode and time base").
//!
//! No native ffmpeg linking: this shells out to the `ffmpeg`/`ffprobe` binaries already required
//! to *produce* a scrim recording (OBS uses the same libraries), and reads raw RGB24 frames off
//! ffmpeg's stdout pipe. `t` is presentation time in seconds (currently `index / fps`; mapping
//! that to wall-clock game time via the in-frame EVE clock, per DESIGN.md S1, is a later pass —
//! nothing here depends on this being exact).

use anyhow::{bail, ensure, Context, Result};
use image::RgbImage;
use std::io::Read;
use std::process::{Child, ChildStdout, Command, Stdio};

/// One decoded video frame.
pub struct Frame {
    /// 0-based frame index in decode order.
    pub index: u64,
    /// Presentation time in seconds, `index / fps`.
    pub t: f64,
    pub image: RgbImage,
}

/// Streams frames out of a video file by shelling out to `ffmpeg`.
pub struct Decoder {
    pub width: u32,
    pub height: u32,
    pub fps: f64,
    child: Child,
    stdout: ChildStdout,
    index: u64,
    buf: Vec<u8>,
    done: bool,
}

/// The subset of `ffprobe -show_streams -of json`'s output this crate reads.
#[derive(serde::Deserialize)]
struct ProbeOutput {
    streams: Vec<ProbeStream>,
}

#[derive(serde::Deserialize)]
struct ProbeStream {
    width: Option<u32>,
    height: Option<u32>,
    r_frame_rate: Option<String>,
}

fn parse_frame_rate(s: &str) -> Result<f64> {
    match s.split_once('/') {
        Some((num, den)) => {
            let num: f64 = num.parse().context("parsing r_frame_rate numerator")?;
            let den: f64 = den.parse().context("parsing r_frame_rate denominator")?;
            ensure!(den != 0.0, "r_frame_rate denominator is zero");
            Ok(num / den)
        }
        None => s.parse().context("parsing r_frame_rate"),
    }
}

/// Probe a video's first video stream for width/height/fps via `ffprobe`.
pub fn probe(path: &std::path::Path) -> Result<(u32, u32, f64)> {
    let output = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height,r_frame_rate",
            "-of",
            "json",
        ])
        .arg(path)
        .output()
        .context("running ffprobe (is it installed and on PATH?)")?;
    ensure!(
        output.status.success(),
        "ffprobe failed on {}: {}",
        path.display(),
        String::from_utf8_lossy(&output.stderr)
    );
    let parsed: ProbeOutput =
        serde_json::from_slice(&output.stdout).context("parsing ffprobe JSON output")?;
    let stream = parsed
        .streams
        .first()
        .context("ffprobe reported no video stream")?;
    let width = stream.width.context("ffprobe stream has no width")?;
    let height = stream.height.context("ffprobe stream has no height")?;
    let fps = parse_frame_rate(
        stream
            .r_frame_rate
            .as_deref()
            .context("ffprobe stream has no r_frame_rate")?,
    )?;
    Ok((width, height, fps))
}

/// Whether the video has an audio stream, via `ffprobe`.
pub fn has_audio(path: &std::path::Path) -> Result<bool> {
    let output = Command::new("ffprobe")
        .args(["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0"])
        .arg(path)
        .output()
        .context("running ffprobe (is it installed and on PATH?)")?;
    ensure!(
        output.status.success(),
        "ffprobe failed on {}: {}",
        path.display(),
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(!output.stdout.trim_ascii().is_empty())
}

/// Write the first audio stream from `start_s` to `end_s` (`None`: the end) as a 192 kbps MP3 to
/// `out`, the same encoding as ScrimTrimmer's `--extract-audio`. The seek matches
/// [`Decoder::open_range`]'s, so the audio starts at the same moment as the first decoded frame.
/// Returns `false` (and writes nothing) when the video has no audio stream.
pub fn extract_audio(
    path: impl AsRef<std::path::Path>,
    start_s: f64,
    end_s: Option<f64>,
    out: impl AsRef<std::path::Path>,
) -> Result<bool> {
    let (path, out) = (path.as_ref(), out.as_ref());
    ensure!(start_s >= 0.0, "start must not be negative, got {start_s}");
    if let Some(end) = end_s {
        ensure!(end > start_s, "end ({end}) must be after start ({start_s})");
    }
    if !has_audio(path)? {
        return Ok(false);
    }

    let mut cmd = Command::new("ffmpeg");
    cmd.args(["-v", "error", "-y", "-nostdin"]);
    if start_s > 0.0 {
        cmd.args(["-ss", &format!("{start_s}")]);
    }
    cmd.arg("-i").arg(path).args(["-map", "0:a:0", "-vn"]);
    if let Some(end) = end_s {
        cmd.args(["-t", &format!("{}", end - start_s)]);
    }
    let output = cmd
        .args(["-c:a", "libmp3lame", "-b:a", "192k", "-f", "mp3"])
        .arg(out)
        .stdin(Stdio::null())
        .output()
        .context("running ffmpeg (is it installed and on PATH?)")?;
    if !output.status.success() {
        let _ = std::fs::remove_file(out);
        bail!(
            "ffmpeg failed extracting audio from {}: {}",
            path.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(true)
}

impl Decoder {
    /// Open a video file, probing its dimensions/framerate and starting an `ffmpeg` process that
    /// streams raw RGB24 frames on stdout.
    pub fn open(path: impl AsRef<std::path::Path>) -> Result<Decoder> {
        Decoder::open_with_fps(path, None)
    }

    /// Like [`Decoder::open`], but resampled by ffmpeg to `fps` frames per second (`None`: the
    /// source rate). Sampling a long recording at a few Hz this way avoids piping every
    /// full-resolution frame only to discard most of them; `Frame::t` is then `index / fps`.
    pub fn open_with_fps(path: impl AsRef<std::path::Path>, fps: Option<f64>) -> Result<Decoder> {
        Decoder::open_range(path, fps, 0.0, None)
    }

    /// Like [`Decoder::open_with_fps`], but only the video from `start_s` to `end_s` (`None`: the
    /// end). `Frame::t` counts from `start_s`. The seek is frame-accurate: ffmpeg decodes from the
    /// keyframe before `start_s` and drops frames up to it, unlike a stream-copy cut.
    pub fn open_range(
        path: impl AsRef<std::path::Path>,
        fps: Option<f64>,
        start_s: f64,
        end_s: Option<f64>,
    ) -> Result<Decoder> {
        Decoder::open_range_hw(path, fps, start_s, end_s, None)
    }

    /// Like [`Decoder::open_range`], decoding with ffmpeg's `-hwaccel <hwaccel>` (e.g. `cuda` for
    /// NVDEC, `vaapi`). The decoded pixels are the same; what changes is that decode no longer
    /// competes with OCR for CPU cores. ffmpeg falls back to software decode by itself when the
    /// accelerator can't be initialised.
    pub fn open_range_hw(
        path: impl AsRef<std::path::Path>,
        fps: Option<f64>,
        start_s: f64,
        end_s: Option<f64>,
        hwaccel: Option<&str>,
    ) -> Result<Decoder> {
        let path = path.as_ref();
        let (width, height, src_fps) = probe(path)?;
        if let Some(f) = fps {
            ensure!(f > 0.0, "fps must be positive, got {f}");
        }
        ensure!(start_s >= 0.0, "start must not be negative, got {start_s}");
        if let Some(end) = end_s {
            ensure!(end > start_s, "end ({end}) must be after start ({start_s})");
        }

        let mut cmd = Command::new("ffmpeg");
        cmd.args(["-v", "error"]);
        if let Some(hw) = hwaccel {
            cmd.args(["-hwaccel", hw]);
        }
        if start_s > 0.0 {
            cmd.args(["-ss", &format!("{start_s}")]);
        }
        cmd.arg("-i").arg(path).args(["-map", "0:v:0"]);
        if let Some(end) = end_s {
            cmd.args(["-t", &format!("{}", end - start_s)]);
        }
        if let Some(f) = fps {
            cmd.args(["-vf", &format!("fps={f}")]);
        }
        let mut child = cmd
            .args(["-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("spawning ffmpeg (is it installed and on PATH?)")?;
        let stdout = child.stdout.take().expect("stdout was piped");

        Ok(Decoder {
            width,
            height,
            fps: fps.unwrap_or(src_fps),
            child,
            stdout,
            index: 0,
            buf: vec![0u8; width as usize * height as usize * 3],
            done: false,
        })
    }

    /// Read the next frame, or `None` at end of stream.
    pub fn next_frame(&mut self) -> Result<Option<Frame>> {
        if self.done {
            return Ok(None);
        }
        match self.stdout.read_exact(&mut self.buf) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                self.done = true;
                self.check_exit_status()?;
                return Ok(None);
            }
            Err(e) => return Err(e).context("reading frame from ffmpeg stdout"),
        }
        let image = RgbImage::from_raw(self.width, self.height, self.buf.clone())
            .context("frame buffer size did not match width*height*3")?;
        let frame = Frame {
            index: self.index,
            t: self.index as f64 / self.fps,
            image,
        };
        self.index += 1;
        Ok(Some(frame))
    }

    fn check_exit_status(&mut self) -> Result<()> {
        let status = self.child.wait().context("waiting for ffmpeg to exit")?;
        if !status.success() {
            let mut stderr = String::new();
            if let Some(mut s) = self.child.stderr.take() {
                let _ = s.read_to_string(&mut stderr);
            }
            bail!("ffmpeg exited with {status}: {stderr}");
        }
        Ok(())
    }
}

impl Decoder {
    /// Move decoding onto its own thread, keeping up to `depth` decoded frames queued ahead of the
    /// consumer — so ffmpeg keeps decoding while the caller is busy with the previous frames
    /// instead of stalling on a full stdout pipe.
    pub fn prefetch(mut self, depth: usize) -> Prefetch {
        let (width, height, fps) = (self.width, self.height, self.fps);
        let (tx, rx) = std::sync::mpsc::sync_channel(depth);
        std::thread::spawn(move || loop {
            let next = self.next_frame();
            let stop = !matches!(next, Ok(Some(_)));
            // A send error means the consumer is gone; dropping `self` then stops ffmpeg.
            if tx.send(next).is_err() || stop {
                break;
            }
        });
        Prefetch { width, height, fps, rx, done: false }
    }
}

/// A [`Decoder`] running on a background thread (see [`Decoder::prefetch`]).
pub struct Prefetch {
    pub width: u32,
    pub height: u32,
    pub fps: f64,
    rx: std::sync::mpsc::Receiver<Result<Option<Frame>>>,
    done: bool,
}

impl Prefetch {
    /// Read the next frame, or `None` at end of stream.
    pub fn next_frame(&mut self) -> Result<Option<Frame>> {
        if self.done {
            return Ok(None);
        }
        let next = self.rx.recv().unwrap_or(Ok(None));
        if !matches!(next, Ok(Some(_))) {
            self.done = true;
        }
        next
    }
}

impl Iterator for Decoder {
    type Item = Result<Frame>;

    fn next(&mut self) -> Option<Result<Frame>> {
        self.next_frame().transpose()
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        // Best-effort: don't leave a decode process running if the caller stops early.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_rate_parsing() {
        assert_eq!(parse_frame_rate("60/1").unwrap(), 60.0);
        assert_eq!(parse_frame_rate("30000/1001").unwrap(), 30000.0 / 1001.0);
        assert_eq!(parse_frame_rate("25").unwrap(), 25.0);
    }

    /// The overview crate's sample recording, decoded whole and as a sub-range.
    const SAMPLE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../overview/tests/fixtures/overview-sample.mkv");

    #[test]
    fn prefetch_yields_the_same_frames() {
        let direct: Vec<Frame> =
            Decoder::open_with_fps(SAMPLE, Some(2.0)).unwrap().map(Result::unwrap).collect();
        let mut pre = Decoder::open_with_fps(SAMPLE, Some(2.0)).unwrap().prefetch(2);
        let mut n = 0;
        while let Some(f) = pre.next_frame().unwrap() {
            assert_eq!(f.index, direct[n].index);
            assert!(f.image == direct[n].image);
            n += 1;
        }
        assert_eq!(n, direct.len());
        assert!(pre.next_frame().unwrap().is_none());
    }

    #[test]
    fn range_decodes_only_the_window() {
        let whole = Decoder::open_with_fps(SAMPLE, Some(1.0)).unwrap().count();
        assert!(whole > 4, "fixture too short: {whole} frames");
        let frames: Vec<Frame> =
            Decoder::open_range(SAMPLE, Some(1.0), 1.0, Some(3.0)).unwrap().map(Result::unwrap).collect();
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].t, 0.0);
        let tail = Decoder::open_range(SAMPLE, Some(1.0), 2.0, None).unwrap().count();
        assert_eq!(tail, whole - 2);
    }

    fn duration_s(path: &std::path::Path) -> f64 {
        let out = Command::new("ffprobe")
            .args(["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0"])
            .arg(path)
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).trim().parse().unwrap()
    }

    #[test]
    fn audio_extracts_only_the_window() {
        let dir = std::env::temp_dir().join(format!("videoin-audio-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let video = dir.join("tone.mkv");
        let status = Command::new("ffmpeg")
            .args(["-v", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=64x64:r=10:d=5"])
            .args(["-f", "lavfi", "-i", "sine=frequency=440:duration=5", "-shortest"])
            .arg(&video)
            .status()
            .unwrap();
        assert!(status.success());

        let mp3 = dir.join("tone.mp3");
        assert!(extract_audio(&video, 1.0, Some(3.0), &mp3).unwrap());
        let d = duration_s(&mp3);
        assert!((d - 2.0).abs() < 0.1, "window audio is {d}s, want 2s");

        let silent = dir.join("silent.mp3");
        assert!(!extract_audio(SAMPLE, 0.0, None, &silent).unwrap());
        assert!(!silent.exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
