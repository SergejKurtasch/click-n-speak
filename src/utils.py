import subprocess

def send_notification(title, subtitle, info_text):
    """Sends a native macOS notification using AppleScript."""
    content = f"{subtitle} - {info_text}" if subtitle else info_text
    escaped_title = title.replace('"', '\\"')
    escaped_content = content.replace('"', '\\"')
    
    script = f'display notification "{escaped_content}" with title "{escaped_title}"'
    try:
        subprocess.run(["osascript", "-e", script], check=True)
    except subprocess.CalledProcessError as e:
        print(f"Failed to send notification: {e}")

def copy_to_clipboard(text):
    """Copies text to the macOS clipboard."""
    try:
        process = subprocess.Popen(['pbcopy'], stdin=subprocess.PIPE, close_fds=True)
        process.communicate(input=text.encode('utf-8'))
    except Exception as e:
        print(f"Failed to copy to clipboard: {e}")

def play_sound(sound_name="/System/Library/Sounds/Tink.aiff"):
    """Plays a system sound."""
    try:
        subprocess.run(["afplay", sound_name], check=False)
    except Exception as e:
        print(f"Failed to play sound {sound_name}: {e}")
