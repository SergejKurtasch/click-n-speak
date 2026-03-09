import json
import os
import time
import threading
from recorder import AudioRecorder
from transcriber import WhisperTranscriber
from hotkey_handler import HotkeyHandler
from injector import inject_text
from utils import send_notification, play_sound

class SVoiceRecApp:
    def __init__(self, config_path="config.json"):
        self.load_config(config_path)
        self.recorder = AudioRecorder(sample_rate=self.config['sample_rate'])
        self.transcriber = WhisperTranscriber(model_name=self.config['model_name'])
        self.hotkey_handler = HotkeyHandler(
            hotkey_str=self.config['hotkey'],
            on_trigger=self.toggle_recording
        )
        self.is_recording = False
        self.is_processing = False

    def load_config(self, path):
        with open(path, 'r') as f:
            self.config = json.load(f)

    def toggle_recording(self):
        if self.is_processing:
            print("Still processing previous recording. Please wait.")
            return

        if not self.is_recording:
            self.start_recording()
        else:
            self.stop_recording_and_process()

    def start_recording(self):
        self.is_recording = True
        send_notification("SVoiceRec", "Recording...", "Speak now. Press Option+Space to finish.")
        self.recorder.start()

    def stop_recording_and_process(self):
        self.is_recording = False
        self.is_processing = True
        
        audio_data = self.recorder.stop()
        if audio_data is None or len(audio_data) == 0:
            print("No audio recorded.")
            send_notification("SVoiceRec", "Finish", "No audio recorded.")
            self.is_processing = False
            return

        # Run transcription in a separate thread to not block the hotkey handler
        threading.Thread(target=self.process_audio, args=(audio_data,)).start()

    def process_audio(self, audio_data):
        try:
            send_notification("SVoiceRec", "Processing...", "Transcribing your speech.")
            
            # Use the initial prompt and conditioning flag from config
            text = self.transcriber.transcribe(
                audio_data, 
                initial_prompt=self.config.get('initial_prompt'),
                condition_on_previous_text=self.config.get('condition_on_previous_text', True)
            )
            
            if text:
                print(f"Transcribed Text: {text}")
                inject_text(text)
                send_notification("SVoiceRec", "Success", "Text injected successfully.")
            else:
                send_notification("SVoiceRec", "Finish", "Could not transcribe audio.")
                
        except Exception as e:
            print(f"Error during processing: {e}")
            send_notification("SVoiceRec", "Error", f"Failed to process audio: {str(e)}")
        finally:
            self.is_processing = False

    def run(self):
        print("SVoiceRec is running...")
        send_notification("SVoiceRec", "Started", "Press Option+Space to start recording.")
        self.hotkey_handler.start()
        
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            print("Shutting down...")
            self.hotkey_handler.stop()

if __name__ == "__main__":
    # Ensure we are in the right directory
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    
    app = SVoiceRecApp()
    app.run()
