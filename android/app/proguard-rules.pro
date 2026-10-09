# JNI resolves these symbols by name in release APKs, including anonymous sinks.
-keep class com.example.audiobook_player.WhisperNative { *; }
-keep interface com.example.audiobook_player.NativeCueSink { *; }
-keepclassmembers class * implements com.example.audiobook_player.NativeCueSink {
    public void onSegment(long, long, byte[]);
}
