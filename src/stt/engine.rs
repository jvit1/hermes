use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use anyhow::{anyhow, bail, Context, Result};
use hound::{SampleFormat, WavSpec, WavWriter};
use tracing::warn;

use crate::config::{AppConfig, BackendPreference};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendUsed {
    Gpu,
    Cpu,
}

#[derive(Debug, Clone)]
pub struct DecodeOptions {
    pub language: String,
}

#[derive(Debug, Clone)]
pub struct Transcript {
    pub text: String,
    pub latency_ms: u128,
    pub backend_used: BackendUsed,
}

pub trait Transcriber {
    fn transcribe(&self, pcm_mono_16khz: &[f32], options: &DecodeOptions) -> Result<Transcript>;
}

pub struct WhisperCliTranscriber {
    whisper_cli_path: PathBuf,
    model_path: PathBuf,
    backend_preference: BackendPreference,
    scratch_dir: PathBuf,
}

impl WhisperCliTranscriber {
    pub fn new(config: &AppConfig) -> Result<Self> {
        let scratch_dir = config.data_dir().join("scratch");
        fs::create_dir_all(&scratch_dir)?;

        let whisper_cli_path = config.resolved_whisper_cli_path();
        ensure_runtime_files(&whisper_cli_path)?;

        Ok(Self {
            whisper_cli_path,
            model_path: config.model_path.clone(),
            backend_preference: config.backend,
            scratch_dir,
        })
    }

    pub fn probe_backend(&self) -> Result<BackendUsed> {
        let output = Command::new(&self.whisper_cli_path)
            .arg("--help")
            .output()
            .with_context(|| {
                format!(
                    "failed to run whisper CLI for backend probe: {}",
                    self.whisper_cli_path.display()
                )
            })?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);
            let hint = whisper_cli_status_hint(output.status.code())
                .map(|h| format!("\n{h}"))
                .unwrap_or_default();
            bail!(
                "whisper CLI backend probe failed (status: {}):\nstdout: {}\nstderr: {}{}",
                output.status,
                stdout,
                stderr,
                hint
            );
        }
        Ok(BackendUsed::Gpu)
    }
}

impl Transcriber for WhisperCliTranscriber {
    fn transcribe(&self, pcm_mono_16khz: &[f32], options: &DecodeOptions) -> Result<Transcript> {
        if pcm_mono_16khz.is_empty() {
            return Ok(Transcript {
                text: String::new(),
                latency_ms: 0,
                backend_used: BackendUsed::Cpu,
            });
        }

        if !self.model_path.exists() {
            bail!("Whisper model not found at {}", self.model_path.display());
        }

        let started = Instant::now();
        let nonce = rand_seed();
        let wav_path = self.scratch_dir.join(format!("ptt-{nonce}.wav"));
        let out_prefix = self.scratch_dir.join(format!("ptt-{nonce}-transcript"));
        write_wav_f32_16khz(&wav_path, pcm_mono_16khz)?;

        let mut last_error: Option<anyhow::Error> = None;
        let run_order: Vec<bool> = match self.backend_preference {
            BackendPreference::GpuThenCpu => vec![false, true],
            BackendPreference::CpuOnly => vec![true],
        };

        for force_cpu in run_order {
            match self.run_whisper(&wav_path, &out_prefix, options, force_cpu) {
                Ok((text, backend_used)) => {
                    cleanup_temp_files(&wav_path, &out_prefix);
                    return Ok(Transcript {
                        text: normalize_transcript(&text),
                        latency_ms: started.elapsed().as_millis(),
                        backend_used,
                    });
                }
                Err(error) => {
                    last_error = Some(error);
                    if !force_cpu {
                        warn!("GPU transcription failed; attempting CPU fallback");
                    }
                }
            }
        }

        cleanup_temp_files(&wav_path, &out_prefix);
        Err(last_error.unwrap_or_else(|| anyhow!("unknown transcription error")))
    }
}

impl WhisperCliTranscriber {
    fn run_whisper(
        &self,
        wav_path: &Path,
        out_prefix: &Path,
        options: &DecodeOptions,
        force_cpu: bool,
    ) -> Result<(String, BackendUsed)> {
        let mut cmd = Command::new(&self.whisper_cli_path);
        cmd.arg("-m")
            .arg(&self.model_path)
            .arg("-f")
            .arg(wav_path)
            .arg("-l")
            .arg(&options.language)
            .arg("-otxt")
            .arg("-nt")
            .arg("-of")
            .arg(out_prefix);

        if force_cpu {
            // Newer whisper-cli builds use -ng/--no-gpu for CPU mode.
            cmd.arg("-ng");
        }

        let output = cmd.output().with_context(|| {
            format!(
                "failed to execute whisper CLI at {}",
                self.whisper_cli_path.display()
            )
        })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);
            let hint = whisper_cli_status_hint(output.status.code())
                .map(|h| format!("\n{h}"))
                .unwrap_or_default();
            bail!(
                "whisper CLI failed (status: {}):\nstdout: {}\nstderr: {}{}",
                output.status,
                stdout,
                stderr,
                hint
            );
        }

        let txt_path = resolve_transcript_path(wav_path, out_prefix).ok_or_else(|| {
            let candidates = candidate_output_paths(wav_path, out_prefix)
                .into_iter()
                .map(|p| p.display().to_string())
                .collect::<Vec<_>>()
                .join(", ");
            anyhow!(
                "failed to locate transcription output file. tried: [{candidates}]\nstdout: {}\nstderr: {}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            )
        })?;
        let text = fs::read_to_string(&txt_path).with_context(|| {
            format!(
                "failed to read transcription output file at {}",
                txt_path.display()
            )
        })?;
        let backend = detect_backend_used(&output.stdout, &output.stderr, force_cpu);
        Ok((text, backend))
    }
}

fn write_wav_f32_16khz(path: &Path, pcm: &[f32]) -> Result<()> {
    let spec = WavSpec {
        channels: 1,
        sample_rate: 16_000,
        bits_per_sample: 16,
        sample_format: SampleFormat::Int,
    };
    let mut writer =
        WavWriter::create(path, spec).with_context(|| format!("failed to create {}", path.display()))?;
    for sample in pcm {
        let clamped = sample.clamp(-1.0, 1.0);
        writer.write_sample((clamped * i16::MAX as f32) as i16)?;
    }
    writer.finalize()?;
    Ok(())
}

fn detect_backend_used(stdout: &[u8], stderr: &[u8], force_cpu: bool) -> BackendUsed {
    if force_cpu {
        return BackendUsed::Cpu;
    }

    let _ = (stdout, stderr);
    BackendUsed::Gpu
}

fn cleanup_temp_files(wav_path: &Path, out_prefix: &Path) {
    let _ = fs::remove_file(wav_path);
    let _ = fs::remove_file(wav_path.with_extension("txt"));
    let _ = fs::remove_file(wav_path.with_extension("json"));
    let _ = fs::remove_file(wav_path.with_extension("vtt"));
    let _ = fs::remove_file(wav_path.with_extension("srt"));
    let _ = fs::remove_file(PathBuf::from(format!("{}.txt", wav_path.display())));
    let _ = fs::remove_file(PathBuf::from(format!("{}.json", wav_path.display())));
    let _ = fs::remove_file(PathBuf::from(format!("{}.vtt", wav_path.display())));
    let _ = fs::remove_file(PathBuf::from(format!("{}.srt", wav_path.display())));
    let _ = fs::remove_file(out_prefix.with_extension("txt"));
    let _ = fs::remove_file(out_prefix.with_extension("json"));
    let _ = fs::remove_file(out_prefix.with_extension("vtt"));
    let _ = fs::remove_file(out_prefix.with_extension("srt"));
}

fn resolve_transcript_path(wav_path: &Path, out_prefix: &Path) -> Option<PathBuf> {
    candidate_output_paths(wav_path, out_prefix)
        .into_iter()
        .find(|p| p.exists())
}

fn candidate_output_paths(wav_path: &Path, out_prefix: &Path) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    let mut candidates = Vec::new();

    let raw = vec![
        out_prefix.with_extension("txt"),
        PathBuf::from(format!("{}.txt", wav_path.display())),
        wav_path.with_extension("txt"),
    ];

    for path in raw {
        let key = path.to_string_lossy().to_string();
        if seen.insert(key) {
            candidates.push(path);
        }
    }

    candidates
}

fn normalize_transcript(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn rand_seed() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    (now as u64) ^ ((now >> 32) as u64)
}

fn whisper_cli_status_hint(code: Option<i32>) -> Option<&'static str> {
    // 0xC0000135 (STATUS_DLL_NOT_FOUND) is surfaced by Windows as -1073741515.
    if code == Some(-1073741515) {
        return Some(
            "hint: whisper-cli failed to start because required DLLs are missing. Place the whisper.cpp runtime DLLs next to whisper-cli.exe (for example: whisper.dll, ggml.dll, ggml-base.dll, ggml-cpu.dll).",
        );
    }
    None
}

fn ensure_runtime_files(whisper_cli_path: &Path) -> Result<()> {
    if !whisper_cli_path.exists() {
        bail!(
            "whisper-cli executable not found at {}",
            whisper_cli_path.display()
        );
    }

    let Some(runtime_dir) = whisper_cli_path.parent() else {
        bail!("whisper-cli path has no parent directory");
    };

    let required = ["whisper.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll"];
    let missing = required
        .iter()
        .filter(|name| !runtime_dir.join(name).exists())
        .copied()
        .collect::<Vec<_>>();

    if !missing.is_empty() {
        bail!(
            "whisper runtime files are missing in {}: {}",
            runtime_dir.display(),
            missing.join(", ")
        );
    }

    Ok(())
}
