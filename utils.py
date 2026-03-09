import subprocess

def send_notification(title, subtitle, info_text):
    """Sends a native macOS notification using AppleScript."""
    # Combine subtitle and info_text for AppleScript display
    content = f"{subtitle} - {info_text}" if subtitle else info_text
    escaped_title = title.replace('"', '\\"')
    escaped_content = content.replace('"', '\\"')
    
    script = f'display notification "{escaped_content}" with title "{escaped_title}"'
    subprocess.run(["osascript", "-e", script])

def copy_to_clipboard(text):
    """Copies text to the macOS clipboard."""
    process = subprocess.Popen(['pbcopy'], stdin=subprocess.PIPE, close_fds=True)
    process.communicate(input=text.encode('utf-8'))

def play_sound(sound_name="/System/Library/Sounds/Tink.aiff"):
    """Plays a system sound."""
    subprocess.run(["afplay", sound_name])
