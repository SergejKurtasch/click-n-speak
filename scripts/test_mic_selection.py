from recorder import AudioRecorder
import sounddevice as sd

def verify_mic_selection():
    print("--- Microphone Selection Test ---")
    recorder = AudioRecorder()
    
    if recorder.device_id is not None:
        device_info = sd.query_devices(recorder.device_id)
        print(f"Logic selected Device ID: {recorder.device_id}")
        print(f"Device Name: {device_info.get('name')}")
    else:
        print("Logic selected Default Device (None).")
        
    print("\nAvailable input devices for reference:")
    for i, dev in enumerate(sd.query_devices()):
        if dev.get('max_input_channels', 0) > 0:
            print(f"ID {i}: {dev.get('name')}")

if __name__ == "__main__":
    verify_mic_selection()
