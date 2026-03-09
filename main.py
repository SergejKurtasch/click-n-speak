import os
import time
import sys
from src.app import SVoiceRecApp
from src.utils import send_notification

def main():
    # Ensure we are in the right directory
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    
    try:
        app = SVoiceRecApp("config.json")
        print("SVoiceRec is running...")
        send_notification("SVoiceRec", "Started", "Press the hotkey to start recording.")
        
        # Start hotkey listener
        app.hotkey_handler.start()
        
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            print("Shutting down...")
            app.stop()
            
    except Exception as e:
        print(f"Failed to start application: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
