import threading
import time

import numpy as np
import sounddevice as sd

from .utils import (
    SOUND_RECORDING_START,
    SOUND_RECORDING_STOP,
    log_error,
    log_info,
    open_microphone_settings,
    play_sound,
    send_notification,
)

try:
    import webrtcvad
    HAVE_VAD = True
except ImportError:
    HAVE_VAD = False



class AudioRecorder:
    def __init__(
        self,
        sample_rate=16000,
        device_id=None,
        silence_threshold=0.01,
        silence_duration=0.5,
        target_speech_duration=4.0,
        max_speech_duration=8.0,
        min_speech_duration=0.5,
    ):
        self.sample_rate = sample_rate
        self.recording = False
        self.audio_data = []  # Current chunk data
        self.stream = None
        self._stop_event = threading.Event()

        # Silence detection parameters
        self.silence_threshold = silence_threshold
        self.silence_duration = silence_duration  # Normal pause
        self.target_speech_duration = target_speech_duration  # Start looking for micro-pauses
        self.max_speech_duration = max_speech_duration  # Force split
        self.min_speech_duration = min_speech_duration  # Min active speech to send chunk

        self.silence_counter = 0
        self.chunk_callback = None
        self.has_speech_in_chunk = False
        self.current_chunk_duration = 0  # Track time since last split
        self.vad_buffer = bytearray()
        self._close_thread = None  # Track ongoing stream-close operation

        if HAVE_VAD:
            self.vad = webrtcvad.Vad(2) # 0-3 aggressiveness (2 is moderate)
            log_info("WebRTC VAD initialized for silence detection.")
        else:
            log_info("webrtcvad not found, falling back to RMS energy. Run 'pip install webrtcvad' for better accuracy.")

        # If device_id is provided in config, use it. Otherwise, try to find built-in.
        if device_id is not None:
            self.device_id = device_id
        else:
            self.device_id = self._find_builtin_device()

    def _find_builtin_device(self):
        """Searches for the built-in MacBook microphone."""
        try:
            devices = sd.query_devices()
            for i, dev in enumerate(devices):
                name = dev.get("name", "")
                # On macOS, internal mics usually have "MacBook" and "Microphone" in the name
                if "MacBook" in name and "Microphone" in name and dev.get("max_input_channels", 0) > 0:
                    log_info(f"Found built-in microphone: {name} (ID: {i})")
                    return i
        except Exception as e:
            log_error(f"Error querying audio devices: {e}")

        # If not found or error, return None to use system default
        return None

    def _callback(self, indata, frames, time_info, status):
        if status:
            log_error(f"Error in audio stream: {status}")

        if not self.recording:
            return

        # Append data to current chunk
        self.audio_data.append(indata.copy())

        # Update current chunk duration
        chunk_increment = frames / self.sample_rate
        self.current_chunk_duration += chunk_increment

        if HAVE_VAD:
            # indata is natively float32, webrtcvad requires 16-bit PCM
            pcm_data = (indata[:, 0] * 32767).astype(np.int16).tobytes()
            self.vad_buffer.extend(pcm_data)
            
            frame_length = int(self.sample_rate * 0.03) * 2 # 30ms 16-bit
            while len(self.vad_buffer) >= frame_length:
                frame = bytes(self.vad_buffer[:frame_length])
                del self.vad_buffer[:frame_length]  # O(1) in-place vs O(n) slice assignment
                if self.vad.is_speech(frame, self.sample_rate):
                    self.silence_counter = 0
                    self.has_speech_in_chunk = True
                else:
                    self.silence_counter += 0.03
        else:
            # Check for silence using RMS energy fallback
            energy = np.sqrt(np.mean(indata**2))
            if energy < self.silence_threshold:
                self.silence_counter += chunk_increment
            else:
                self.silence_counter = 0
                self.has_speech_in_chunk = True

        # Adaptive silence threshold:
        # 1. Normal: 1.0s (default)
        # 2. After target_speech_duration: 0.4s (micro-pause)
        # 3. After max_speech_duration: 0s (force split)

        effective_silence_duration = self.silence_duration
        trigger_type = "Normal"

        if self.current_chunk_duration >= self.max_speech_duration:
            effective_silence_duration = 0  # Force split immediately
            trigger_type = "FORCE (Max duration)"
        elif self.current_chunk_duration >= self.target_speech_duration:
            effective_silence_duration = 0.4  # Micro-pause threshold
            trigger_type = "MICRO (Target duration)"

        # If silence duration exceeded and we have some audio, trigger chunk callback
        if self.silence_counter >= effective_silence_duration:
            if len(self.audio_data) > 0 and self.has_speech_in_chunk:
                duration = sum(len(x) for x in self.audio_data) / self.sample_rate
                speech_duration = duration - self.silence_counter
                if speech_duration > self.min_speech_duration:
                    log_info(
                        f"Triggering {trigger_type} chunk: {self.current_chunk_duration:.2f}s total, {self.silence_counter:.2f}s silence, {speech_duration:.2f}s active speech"
                    )
                    self._trigger_chunk()
                else:
                    log_info(
                        f"Discarding empty/noise chunk (speech duration {speech_duration:.2f}s <= {self.min_speech_duration:.2f}s)"
                    )

            # Reset chunk state even if it was just noise
            self.audio_data = []
            self.silence_counter = 0
            self.has_speech_in_chunk = False
            self.current_chunk_duration = 0

    def _trigger_chunk(self):
        if not self.audio_data:
            return

        chunk = np.concatenate(self.audio_data, axis=0).flatten()

        if self.chunk_callback:
            # on_chunk_received just does queue.put_nowait — safe to call directly
            # from the sounddevice callback thread without spawning a new thread.
            self.chunk_callback(chunk)

    def start(self, chunk_callback=None):
        if self.recording:
            return

        # If the previous stream's abort/close is still running in a daemon thread,
        # wait for it before creating a new stream.  The close thread holds a PortAudio
        # lock; creating a new stream while it is still active can deadlock.
        close_thread = self._close_thread
        if close_thread is not None and close_thread.is_alive():
            log_info("Previous stream close still in progress. Waiting up to 5s…")
            close_thread.join(timeout=5.0)
            if close_thread.is_alive():
                # Thread is a daemon — it will be cleaned up by the OS eventually.
                # Force-reset our state so the user isn't permanently locked out.
                log_error(
                    "Previous audio stream close did not complete after 5s. "
                    "Force-resetting recorder state to allow new recording."
                )
                self.stream = None
                self._close_thread = None
            else:
                log_info("Previous stream close completed. Proceeding with new recording.")
                self._close_thread = None

        log_info(f"Starting recording on device {self.device_id if self.device_id is not None else 'default'}...")
        self.audio_data = []
        self.recording = True
        self.chunk_callback = chunk_callback
        self.silence_counter = 0
        self.has_speech_in_chunk = False
        self.current_chunk_duration = 0
        self.vad_buffer = bytearray()
        self._stop_event.clear()

        try:
            # Play sound BEFORE starting the stream to avoid recording it
            play_sound(SOUND_RECORDING_START)
            time.sleep(0.2)  # Small buffer to let the beep finish mostly

            # FORCE CLOSE any dangling stream before creating a new one
            if self.stream is not None:
                log_info("Found dangling audio stream, forcing cleanup before start...")
                try:
                    self.stream.abort()
                    self.stream.close()
                except Exception:
                    pass
                self.stream = None

            self.stream = sd.InputStream(
                device=self.device_id,
                samplerate=self.sample_rate,
                channels=1,
                callback=self._callback,
            )
            self.stream.start()
        except Exception as e:
            log_error(f"Could not start audio stream: {e}")
            self.recording = False
            send_notification(
                "Click-n-speak",
                "Microphone access required",
                "Please allow microphone access for Click-n-speak in System Settings → Privacy & Security → Microphone.",
            )
            open_microphone_settings()

    def stop(self):
        if not self.recording:
            return None

        log_info("Stopping recording...")
        self.recording = False
        if self.stream:
            self._stop_stream_with_timeout()
            log_info("Stream abort/close dispatched.")

        play_sound(SOUND_RECORDING_STOP)

        if not self.audio_data:
            log_info("No audio_data accumulated; returning None.")
            return None

        # Concatenate all blocks and return as a single numpy array
        result = np.concatenate(self.audio_data, axis=0).flatten()
        log_info(f"Final audio assembled: {len(result)} samples ({len(result)/self.sample_rate:.2f}s).")

        # Filter out very short final chunks (< 0.3s) that are almost always
        # post-speech silence causing Whisper to hallucinate for 10-43 seconds.
        min_samples = int(self.sample_rate * 0.3)
        if len(result) < min_samples:
            log_info(
                f"Final chunk too short ({len(result)} samples, "
                f"{len(result) / self.sample_rate:.2f}s), discarding to avoid hallucination."
            )
            return None

        return result

    def _stop_stream_with_timeout(self) -> None:
        """Stop and close the audio stream without blocking the caller.

        Both abort() and close() run in a daemon thread so neither can block
        the stop_recording_and_process thread.  self.recording is already False
        when this is called, so the callback returns early and audio_data is
        not mutated after we return.

        self._close_thread tracks the thread so that start() can wait for it
        (up to 5 s) before opening a new stream and avoid a PortAudio deadlock.
        """
        old_stream = self.stream
        self.stream = None  # Release reference immediately; start() won't see it

        def _do_close():
            try:
                old_stream.abort()
            except Exception:
                pass
            try:
                old_stream.close()
                log_info("Recorder.stop() stream closed successfully.")
            except Exception as e:
                log_error(f"Error closing audio stream: {e}")

        t = threading.Thread(target=_do_close, daemon=True)
        self._close_thread = t
        t.start()
