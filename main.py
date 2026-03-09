import os
import sys
from src.app import SVoiceRecApp
from src.menu_bar import ClickNSpeakApp
from src.utils import send_notification

def main():
    # Ensure we are in the right directory
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    
    try:
        # Initialize the core application logic
        logic_app = SVoiceRecApp("config.json")
        
        # Initialize the Menu Bar interface
        menu_app = ClickNSpeakApp(logic_app)
        
        # Link them
        logic_app.set_menu_bar(menu_app)
        
        print("Click-n-speak is running in the menu bar...")
        send_notification("Click-n-speak", "Started", "Press the hotkey to start recording or use the menu bar icon.")
        
        # Start hotkey listener
        logic_app.hotkey_handler.start()
        
        # Run the Menu Bar app (this is the main loop)
        menu_app.run()
            
    except Exception as e:
        print(f"Failed to start application: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
